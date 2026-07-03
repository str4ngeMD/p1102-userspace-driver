# Architecture: 100% Native USB Printing on macOS ARM64 (P1102)

This directory documents and contains the implementation for a 100% native, sandbox-friendly, zero-server USB printing solution for the **HP LaserJet Pro P1102** running on Apple Silicon Macs.

---

## 1. The Design Principle

Historically, running ZjStream (`zjs`) printers on macOS was blocked by two issues:
1. **Ghostscript Sandboxing:** The open-source `foo2zjs` driver relies on Ghostscript to convert PDF print streams into intermediate Portable Bitmaps (PBM), which is then converted to ZjStream. Because the macOS CUPS print sandbox blocks executing Homebrew-installed utilities like `gs`, developers were forced to bundle massive, patched Ghostscript runtimes or redirect printing over a local TCP loopback server.
2. **Volatile Firmware Uploader:** The P1102 lacks persistent storage for its engine firmware. It loses its firmware on power-off, requiring the host computer to upload `sihpP1102.dl` over USB upon every connection.

### The Solution:
Instead of running a TCP socket server daemon or bundling a massive Ghostscript binary, this implementation:
* **Patches `foo2zjs.c`** to read the standard `application/vnd.cups-raster` format directly. Since macOS's built-in CUPS rasterizer converts PDF/PostScript to raster natively, our filter doesn't need Ghostscript! It compiles as a single, lightweight C binary (`rastertozjs`) linking to macOS's core `libcups.dylib`.
* **Deploys a passive background daemon (`p1102_fw_uploader.py`)** that only triggers when a USB connection event occurs. It uploads the firmware once, then sleeps.

---

## 2. File Manifest

* [ARCHITECTURE.md](ARCHITECTURE.md) - This document.
* [foo2zjs_cups.patch](foo2zjs_cups.patch) - Unified git diff of the changes applied to the official `foo2zjs.c` to add native CUPS raster support.
* [p1102_fw_uploader.py](p1102_fw_uploader.py) - Simple Python USB hotplug agent to upload firmware.
* [com.nativehp.p1102-fw-uploader.plist](com.nativehp.p1102-fw-uploader.plist) - launchd system agent.
* [HP_LaserJet_Professional_P1102.ppd](HP_LaserJet_Professional_P1102.ppd) - Print queue definition pointing to `rastertozjs` filter.

> See RESEARCH_HISTORY.md for details of how we acquired the firmware.

---

## 3. Step-by-Step Installation

### Step A: Compile and Install the Native Filter
1. Navigate to the `foo2zjs-src` directory and compile the patched filter natively:
   ```bash
   clang -O2 -Wall -DcupsFilter -I. -lcups \
     foo2zjs.c jbig.c jbig_ar.c \
     -o rastertozjs
   ```
2. Copy the filter to the CUPS filter directory:
   ```bash
   sudo mkdir -p /Library/Printers/foo2zjs/filter/
   sudo cp rastertozjs /Library/Printers/foo2zjs/filter/
   sudo chown root:wheel /Library/Printers/foo2zjs/filter/rastertozjs
   sudo chmod 0555 /Library/Printers/foo2zjs/filter/rastertozjs
   ```

### Step B: Install the PPD
1. Copy the custom PPD file to the macOS system PPD folder:
   ```bash
   sudo cp HP_LaserJet_Professional_P1102.ppd /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
   sudo chown root:wheel /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
   sudo chmod 0644 /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
   ```

### Step C: Configure the Firmware Uploader
1. Install Python dependency:
   ```bash
   pip3 install pyusb
   ```
2. Copy the uploader script and plist:
   ```bash
   sudo mkdir -p /Library/Printers/foo2zjs/bin/
   sudo cp p1102_fw_uploader.py /Library/Printers/foo2zjs/bin/
   sudo cp com.nativehp.p1102-fw-uploader.plist /Library/LaunchDaemons/
   ```
3. Load the launchd daemon:
   ```bash
   sudo launchctl load -w /Library/LaunchDaemons/com.nativehp.p1102-fw-uploader.plist
   ```

---

## 4. History of Problem Solving & Debugging Decisions

During the development and testing phases, we ran into several subtle hardware and firmware integration challenges. This section archives the root causes and technical fixes for posterity.

### A. Missing `<fcntl.h>` Header (Compilation Phase)
* **Problem:** Compilation of `foo2zjs.c` failed natively due to implicit declaration of `open` and undeclared `O_RDONLY`.
* **Root Cause:** Standard UNIX file control headers were missing from `foo2zjs.c`.
* **Resolution:** Patched the header block of `foo2zjs.c` to explicitly include `#include <fcntl.h>`.

### B. 100 DPI Fallback (Resolution Mismatch)
* **Problem:** Printer received a print job but printed nothing, and the generated ZJS file size was extremely small (~640 bytes).
* **Root Cause:** The original PPD specified resolution parameters inside foomatic-specific comments (`*FoomaticRIPOption Resolution`) for the legacy `foomatic-rip` Perl engine. Since macOS's native `cgpdftoraster` doesn't parse foomatic comments, it fell back to a default resolution of 100 DPI. In `foo2zjs.c`, `Bpp` (bits per pixel) is mapped as `ResX / 600`. At 100 DPI, `100 / 600` evaluated to `0`, writing invalid ZJS streams.
* **Resolution:** Modified the PPD to declare a standard Adobe/CUPS `Resolution` UI group:
  ```text
  *OpenUI *Resolution/Resolution: PickOne
  *DefaultResolution: 600x600dpi
  *Resolution 600x600dpi/600x600 DPI: "<</HWResolution[600 600]>>setpagedevice"
  *CloseUI: *Resolution
  ```
  This forces `cgpdftoraster` to output standard 600 DPI raster streams.

### C. Missing PJL & ZJS Document Envelopes
* **Problem:** Print jobs completed in CUPS but the printer remained completely idle.
* **Root Cause:** While the C filter successfully compressed the raster pages, it omitted the PJL wrappers and stream initialization headers.
* **Resolution:** Added `start_doc(stdout)` and `end_doc(stdout)` surrounding the page loop in `do_cups_raster()`. This writes the mandatory PJL job startup sequences (`@PJL JOB`, Economode, density settings), the `"JZJZ"` ZJS stream magic header, and the concluding `@PJL EOJ` commands.

### D. Monochrome Plane Offset Crash
* **Problem:** When sending a print job, the printer flashed its orange Attention and green Ready lights, did not print, and disconnected-reconnected on the USB bus (triggering the uploader daemon to re-upload firmware).
* **Root Cause:** The P1102 is a monochrome printer and expects page raster data on **Plane 0** (monochrome mode). By default, `foo2zjs.c` sets `OutputStartPlane = 1`, which outputs monochrome black data as **Plane 4** (CMYK black). The printer's micro-firmware parser encountered the unsupported plane value, threw a fatal exception, panicked, and rebooted itself back into USB bootloader mode.
* **Resolution:** Hardcoded `OutputStartPlane = 0;` at the beginning of `do_cups_raster()`.

### E. Unified Diagnostic Stream
* **Problem:** Tailing `/var/log/cups/error_log` was a manual, hard-to-remember task when debugging the print filter's status.
* **Resolution:** 
  1. Updated `p1102_fw_uploader.py` to spawn a background thread that tails `/var/log/cups/error_log` in real-time, matching job IDs for our P1102 queue and presenting the output consolidated in the uploader's console stream.
  2. Patched the C filter to print key milestone messages (Start Doc, Processing Page, Finished Page) to `stderr`, which CUPS intercepts and streams directly to our consolidator.

---

## 5. Building From Source

If you want to reconstruct the native `rastertozjs` binary from scratch, follow these instructions.

### Prerequisites
* **macOS Command Line Tools:** Install compiler tools by running:
  ```bash
  xcode-select --install
  ```
  The macOS SDK contains the required CUPS headers (`<cups/cups.h>`, `<cups/raster.h>`) out-of-the-box. No external libraries are needed.

### Compilation Steps
1. **Clone the Original Driver Suite:**
   Clone the official upstream open-source driver package:
   ```bash
   git clone https://github.com/OpenPrinting/foo2zjs.git foo2zjs-src
   ```
2. **Apply our C Raster Patch:**
   Apply our custom CUPS-integration patch [foo2zjs_cups.patch](file:///Users/sorce/code/p1102-userspace-driver/foo2zjs_cups.patch) to the source folder:
   ```bash
   cd foo2zjs-src
   patch -p1 < ../foo2zjs_cups.patch
   ```
3. **Compile Natively:**
   Run `clang` to compile the patched code, linking to the standard macOS CUPS library (`-lcups`):
   ```bash
   clang -O2 -Wall -DcupsFilter -I. -lcups \
     foo2zjs.c jbig.c jbig_ar.c \
     -o rastertozjs
   ```
4. **Clean Up:**
   Move the newly compiled `rastertozjs` binary to your preferred driver directory and safely remove the temporary `foo2zjs-src` build folder:
   ```bash
   cp rastertozjs ../rastertozjs
   cd ..
   rm -rf foo2zjs-src
   ```


