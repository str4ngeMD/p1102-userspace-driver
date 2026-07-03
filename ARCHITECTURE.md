# Architecture: 100% Native USB Printing on macOS ARM64 (P1102)

This document explains the architecture design of the native, sandbox-friendly, zero-server USB printing solution for the **HP LaserJet Pro P1102** running on Apple Silicon Macs.

---

## 1. Design Principles

Historically, running ZjStream (`zjs`) printers on macOS was blocked by two issues:

1. **Ghostscript Sandboxing:** The open-source `foo2zjs` driver relies on Ghostscript to convert PDF print streams into intermediate Portable Bitmaps (PBM), which are then converted to ZjStream. Because the macOS CUPS print sandbox blocks executing Homebrew-installed utilities like `gs`, developers were forced to bundle massive, patched Ghostscript runtimes or redirect printing over a local TCP loopback server.
2. **Volatile Firmware Uploader:** The P1102 lacks persistent storage for its engine firmware. It loses its firmware on power-off, requiring the host computer to upload `sihpP1102.dl` over USB upon every connection.

### The Solution:
Instead of running a TCP socket server daemon or bundling a massive Ghostscript binary, this implementation:
* **Patches `foo2zjs.c`** to read the standard `application/vnd.cups-raster` format directly. Since macOS's built-in CUPS rasterizer converts PDF/PostScript to raster natively, our filter doesn't need Ghostscript! It compiles as a single, lightweight C binary (`rastertozjs`) linking to macOS's core `libcups.dylib`.
* **Deploys a passive background daemon (`p1102_fw_uploader.py`)** that only triggers when a USB connection event occurs. It uploads the firmware once, then sleeps.

---

## 2. Component Layout

The system is composed of four lightweight parts working in sequence:

```
[Mac Applications] ➔ [CUPS Print Spooler]
                            | (Natively renders PDF to Raster)
                            v
           [/Library/Printers/foo2zjs-str4ngemd/filter/rastertozjs] (C raster filter)
                            | (Pipes output)
                            v
           [/usr/libexec/cups/backend/usb] (Standard macOS USB Backend)
                            |
                            v
                       [P1102 Printer]
```

1. **`rastertozjs` C Filter Binary:** A compiled ARM64 C utility. CUPS pipes `application/vnd.cups-raster` data into its standard input, and the filter outputs compressed ZjStream data to standard output. It links only to macOS system libraries (`libcups.2.dylib` and `libSystem.B.dylib`), running safely within the strict CUPS sandbox.
2. **`HP_LaserJet_Professional_P1102.ppd` Printer Description:** Defines printer attributes and capabilities. It maps user choices (resolution, toner density, paper size, tray selection) into CUPS environment variables and options which are fed directly into the C filter.
3. **`p1102_fw_uploader.py` Python Daemon:** Monitors the USB bus for the LaserJet P1102 hardware connection. When detected, it pushes the firmware payload `sihpP1102.dl` directly to the printer's USB endpoint. It also tails `/var/log/cups/error_log` in real-time, consolidating print status updates into a unified dashboard log.
4. **`com.str4ngemd.p1102-fw-uploader.plist` launchd Config:** Manages the lifetime of the Python daemon, ensuring it runs quietly in the user's background session.

> * For compilation, patch application, and firmware extraction details, see [REPRODUCTION_GUIDE.md](REPRODUCTION_GUIDE.md).
> * For PPD modification diffs, see [PPD_TRANSFORMATION.md](PPD_TRANSFORMATION.md).

---

## 3. History of Problem Solving & Debugging Decisions

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
  3. Directed launchd to log both output streams to user space. They can be read in real-time:
     * **Standard Logs (`.log`):** `tail -f ~/Library/Logs/com.str4ngemd.p1102-fw-uploader.log` (monitors USB connections, firmware uploads, and CUPS filters).
     * **Standard Error (`.err`):** `tail -f ~/Library/Logs/com.str4ngemd.p1102-fw-uploader.err` (captures any unhandled Python daemon exceptions/tracebacks for troubleshooting; empty under normal operation).
