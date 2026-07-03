# Research History & Technical Design Notes

This document preserves the context, experimental setups, protocol analysis, and architectural breakthroughs that led to the creation of the userspace loopback print driver for the HP LaserJet Pro P1102 on macOS (Apple Silicon).

---

## 1. The Core Problem

The HP LaserJet Pro P1102 is a popular, low-cost monochrome laser printer. However, it presents three major hurdles for modern macOS:
1. **Architecture Gap**: The original HP drivers are Intel (`x86_64`) only and depend on deprecated macOS frameworks. 
2. **Volatile Firmware**: The printer lacks flash storage for its engine firmware. Every time it powers on, it starts in a bootloader state and expects the host computer to upload the volatile firmware file (`sihpP1102.dl`) over USB before it can accept print jobs.
3. **CUPS Sandboxing**: Apple has sandbox-restricted CUPS filters. When standard open-source drivers (like `foo2zjs`) try to compile, they crash because the CUPS sandbox prevents them from spawning subprocesses (like Ghostscript) or loading Homebrew dynamic libraries (like `libjpeg-turbo`), resulting in library dependency "sandwich" crashes.

---

## 2. The Experimental Setup (Protocol Reverse Engineering)

To understand how the printer communicates and how the official driver loads firmware, we analyzed the USB protocol:

1. **Virtualization & USB Passthrough**: We ran an ARM64 Ubuntu VM in UTM (using QEMU) and passed the physical HP LaserJet P1102 USB device through to the VM.
2. **Firmware & HPLIP Setup**: Inside the VM, we installed HPLIP and its proprietary plugin:
   ```bash
   sudo apt install hplip hplip-gui sane-utils
   hp-plugin -i # Downloads and installs the proprietary plugin containing firmware
   ```
3. **USB Device Mapping**: We used `lsusb` to find the exact Bus and Device number of the connected printer:
   ```bash
   $ lsusb
   Bus 003 Device 002: ID 03f0:002a HP, Inc LaserJet Professional P1102
   ```
   This told us that the printer was on **Bus 3** at **Device Address 2**.

4. **USB Traffic Capture**: We loaded the kernel's `usbmon` monitoring module and ran Wireshark as root to capture the raw USB communication. 
   We selected the interface **`usbmon3`** (matching Bus 003) and filtered the packets by **`usb.device_address == 2`** (matching Device 002):
   ```bash
   sudo modprobe usbmon
   sudo wireshark
   ```

5. **Data Extraction**:
   After capturing the print job stream (stored as a `.pcapng` file), we extracted the raw payload hex bytes using `tshark` filtering for the specific device address:
   ```bash
   tshark -r printpcap.pcapng -Y "usb.device_address == 2 && usb.capdata" -T fields -e usb.capdata > payloads_hex.txt
   ```
6. **Hex Decoding**:
   To read the payloads, we decoded the hex into binary representation using Perl:
   ```bash
   perl -ne 's/([0-9a-fA-F]{2})/print pack("H2", $1)/eg' payloads_hex.txt > ascii_payload.txt
   ```
   (this is because `xxd -r` errors with "File too big")

7. **Analysis & Discoveries**:
   * Inspecting `ascii_payload.txt` revealed standard PJL (Printer Job Language) headers followed by a binary ZjStream (v2) format.
   * We located the compressed firmware gzip files in `/usr/share/hplip/data/firmware/` (`hp_laserjet_professional_p1102.fw.gz`).
   * By comparing sizes and contents, we discovered that the `.fw` file extracted from the Gzip archive was identical to the `.dl` firmware file:
     ```bash
     file sihpP1102.fw    # HP Printer Job Language data
     file sihpP1102.dl    # HP Printer Job Language data
     ```
   > Note that the `/usr/share/hplip/...` refers to the ubuntu vm. \
   > I don't know how to "compile" or "generate" these files from the source. 
   >
   > You can decompress `.gz` with `gunzip -k yourfile.fw.gz` into `yourfile.fw`. \
   > Keep in mind that without the `-k` (keep) flag, the original file will be deleted. \
   > If you accidentally ran without `-k`, you can always "undo" via `gzip yourfile.fw` which will yield `yourfile.fw.gz` back.
   >
   > The size comparison between `.fw` and `.dl` were made with `ls -l  oneofthem.fw theother.dl`
   
---

## 3. The Architecture Evolution

### Phase 1: The Sandboxed PPD Hack (Obsolete)
We originally attempted to compile `foo2zjs` and write a custom CUPS filter that would convert PostScript/PDF to ZJS during the CUPS pipeline. 
* *Failure reason*: This required manual modifications to `/etc/sandbox.d/` or replacing system library symlinks, which broke SIP, was extremely fragile, and was completely undone by minor macOS updates.

### Phase 2: The Loopback Network Bridge (Approved)
Instead of fighting the CUPS sandbox, we bypass it. 
We create a standard user-facing print queue in CUPS configured to point to a local JetDirect socket server:
`socket://127.0.0.1:9100`

When you click "Print":
1. CUPS formats the document as standard PostScript/PDF.
2. CUPS opens a TCP connection to `127.0.0.1:9100` and dumps the PostScript data.
3. The background print daemon (`p1102_daemon.py` in *v1* branch of this repo), running in the user space (fully outside the CUPS sandbox), receives the PostScript data.
4. The daemon runs `gs` and `foo2zjs` (compiled natively for ARM64) to rasterize the PostScript to PBM and encode it to ZjStream.
5. The daemon pipes the output to the physical USB printer.

This approach means zero security modifications or library hackery are needed!

### Phase 3: The Direct USB Backend Breakthrough (Obsolete Network Solution)
Initially, to send the generated ZJS file to the physical USB port without sandbox issues, we ran a loopback network server daemon on port 9100. It converted the spooled job to ZJS, and then called macOS's built-in CUPS USB backend `/usr/libexec/cups/backend/usb` to write the raw stream directly to the printer.
* *Issue*: This still required a running background server, python packages (like `pyusb`), and a custom Netpbm/Ghostscript translation layer.

### Phase 4: The 100% Native, Direct CUPS Raster Filter (Ultimate Solution)
Instead of bypassing the CUPS sandbox with a loopback TCP socket server and running a heavy Ghostscript rasterizer, we integrated directly into the CUPS printing pipeline natively:

1. **Native CUPS Raster Format:** We patched the official `foo2zjs.c` driver to parse the standard `application/vnd.cups-raster` format. Since macOS's built-in CUPS system natively converts PDFs and PostScript to raw raster scanlines, our custom filter (`rastertozjs`) does not need Ghostscript!
2. **Apple Silicon Native Compilation:** We compiled the patched driver natively as an ARM64 binary. By linking *only* to macOS's core `libcups.dylib` and `libSystem.dylib`, the binary is 100% sandbox-compliant and has zero third-party/Homebrew dependencies.
3. **No Active Servers:** The print queue directly calls `/Library/Printers/foo2zjs/filter/rastertozjs`, which converts the stream and pipes the raw ZjStream output to the printer natively.

---

## 4. Translation Logic: Options, Page Sizes, and Resolution

With the Phase 4 native architecture, all printing parameters are parsed dynamically inside the C filter (`rastertozjs`) from the CUPS Raster page header and options string (`argv[4]`), matching the printer's physical hardware:

### A. How Duplex Printing is Handled
The HP LaserJet Pro P1102 does **not** have automatic hardware duplexing. It only supports **manual duplexing**. Manual duplexing is managed entirely at the OS level by the macOS print spooler itself, sending print pages as separate simplex jobs. 
* To prevent the printer engine from throwing an error, our C filter hardcodes the monochrome plane offset to `OutputStartPlane = 0` (monochrome mode) instead of Plane 4 (color-black mode), which was causing the firmware to panic and reboot.

### B. Auto-Detecting Paper Size (Letter vs. A4)
Instead of analyzing Netpbm headers, the C filter reads the exact page dimensions (`cupsWidth` and `cupsHeight`) and paper type parameters (`header.cupsPageSize`) dynamically from the CUPS Raster stream. These are converted to standard ZJS dimensions, maintaining perfect alignment for Letter, A4, A5, and Legal.

### C. Resolution and Gray Richness (600 DPI vs. 1200 DPI)
* The PPD defines two hardware-supported modes: `600x600 DPI` (1 Bit Per Pixel) and `1200x600 DPI` (2 Bits Per Pixel).
* When printing at `1200x600 DPI`, the filter receives `ResX = 1200`. The C code dynamically computes `Bpp = ResX / 600 = 2` (2 Bits Per Pixel) and sets the horizontal resolution to `600`, which activates the printer's hardware-based **HP REt (Resolution Enhancement technology)** pulse-width modulation. The laser fires for fractions of a pixel width (yielding 4 gray states: off, 1/3, 2/3, and full duration) to print smooth diagonals and rich gray gradients.

### D. Parameter Mapping

| Parameter | Source / Type | Details |
| :--- | :--- | :--- |
| **DPI Resolution** | **Dynamic** | Extracted from `HWResolution`. Translates `1200 DPI` to `Bpp=2` and `600 DPI` to `Bpp=1` dynamically. |
| **Toner Saving / Draft** | **Dynamic** | Parsed from print options. Sets PJL `@PJL SET ECONOMODE=ON` and ZJ command `ZJI_ECONOMODE=1`. |
| **Toner Density (1-5)** | **Dynamic** | Parsed from print options. Injects PJL `@PJL SET DENSITY=[1-5]`. |
| **Paper Tray / Source** | **Dynamic** | Maps PPD `InputSlot` values (Auto, Manual, Upper) to standard ZJS tray codes dynamically. |
| **Paper Type / Media** | **Dynamic** | Maps PPD `MediaType` values (Envelope, Labels, Cardstock) to corresponding ZJS fuser codes dynamically. |

---

## 5. Key Lessons for Developers

* **Avoiding Ghostscript Sandboxing**: Instead of running a complex loopback server or bundling a heavy `gs` binary to escape sandbox blocks, we bypass Ghostscript entirely by reading standard `vnd.cups-raster` scanlines generated natively by macOS.
* **PJL Job Wrappers**: ZJS print streams must be wrapped in standard PJL envelopes (`start_doc()` and `end_doc()`). Failing to print these envelopes causes the printer controller to ignore the job.
* **Unified Diagnostic Logs**: CUPS redirects the `stderr` streams of all filters and backends to `/var/log/cups/error_log`. We can passively tail this file in Python without needing root privileges, providing a unified real-time console stream of USB connections and print jobs side-by-side.

---

## 6. PPD Origin and Custom Patching

For developers wondering where [HP_LaserJet_Professional_P1102.ppd](file:///Users/sorce/code/p1102-userspace-driver/HP_LaserJet_Professional_P1102.ppd) came from:

### 1. Upstream PPD Origin
The original PPD templates are stored in the upstream repository at [github.com/OpenPrinting/foo2zjs/tree/main-fixes/PPD](https://github.com/OpenPrinting/foo2zjs/tree/main-fixes/PPD).

> In the official `foo2zjs` package, PPD files were built dynamically by the suite's makefiles. When you run `make`, a tool called `foomatic-db-engine` parses their XML source templates (like `PPD/HP-LaserJet_Professional_P1102.ppd.in`) and compiles them into final `.ppd` files. 

> The resulting pre-compiled PPD is designed for the legacy foomatic stack, calling a Perl wrapper script to render PostScript files via Ghostscript:
> ```text
> *cupsFilter: "application/vnd.cups-postscript 100 foomatic-rip"
> ```

### 2. Our Manual Modifications (The Patches)
For this project, we took that pre-compiled foomatic PPD and **manually edited and cleaned it** to integrate directly with our native C filter:

* **Redirected the filter pipeline:** We changed the filter definition to point directly to our native binary, asking CUPS to render files to raster scanlines first:
  ```diff
  - *cupsFilter: "application/vnd.cups-postscript 100 foomatic-rip"
  + *cupsFilter: "application/vnd.cups-raster 0 rastertozjs"
  ```
* **Bypassed foomatic comments:** Original parameters (Resolution, Paper Source, Paper Type) were declared inside foomatic-specific XML comment tags. We deleted those blocks and replaced them with standard PostScript dictionary entries (e.g. `<</HWResolution[600 600]>>setpagedevice`), allowing macOS's print system to read the options directly.
* **Resolved 100 DPI fallback:** We replaced the foomatic-specific resolution comment options with a standard CUPS UI PickOne group (declaring `600x600dpi` and `1200x600dpi`), preventing macOS from falling back to 100 DPI and causing division-by-zero crashes.



