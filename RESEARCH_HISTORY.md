# Research History & Technical Design Notes

This document preserves the context, experimental setups, protocol analysis, and architectural breakthroughs that led to the creation of the native CUPS print driver for the HP LaserJet Pro P1102 on macOS (Apple Silicon).

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
    hp-setup -i  # Configures the printer queue and triggers the plugin installation
    # OR:
    hp-plugin -i # Downloads and installs the proprietary plugin containing firmware directly
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
   *(We used Perl because standard `xxd -r` threw "File too big" errors on the large capture data)*.
7. **Analysis & Discoveries**:
   * Inspecting `ascii_payload.txt` revealed standard PJL (Printer Job Language) headers followed by a binary ZjStream (v2) format.
   * We located the compressed firmware files in `/usr/share/hplip/data/firmware/` (`hp_laserjet_professional_p1102.fw.gz`).
   * By comparing sizes and contents, we discovered that the `.fw` file extracted from the Gzip archive was identical to the `.dl` firmware file.
   * For reproduction steps and how to decompress the firmware, see **[REPRODUCTION_GUIDE.md](REPRODUCTION_GUIDE.md)**.

---

## 3. The Architecture Evolution

### Phase 1: The Sandboxed PPD Hack (Obsolete)
We originally attempted to compile `foo2zjs` and write a custom CUPS filter that would convert PostScript/PDF to ZJS during the CUPS pipeline. 
* *Failure reason*: This required manual modifications to `/etc/sandbox.d/` or replacing system library symlinks, which broke SIP, was extremely fragile, and was completely undone by minor macOS updates.

### Phase 2: The Loopback Network Bridge (Approved in v1 Branch)
Instead of fighting the CUPS sandbox, we bypass it. We create a standard user-facing print queue in CUPS configured to point to a local JetDirect socket server: `socket://127.0.0.1:9100`.
When you click "Print":
1. CUPS formats the document as standard PostScript/PDF.
2. CUPS opens a TCP connection to `127.0.0.1:9100` and dumps the PostScript data.
3. The background print daemon (`p1102_daemon.py`), running in the user space (fully outside the CUPS sandbox), receives the PostScript data.
4. The daemon runs `gs` and `foo2zjs` (compiled natively for ARM64) to rasterize the PostScript to PBM and encode it to ZjStream.
5. The daemon pipes the output to the physical USB printer.

*This approach is archived in the `v1` branch of this repository for reference.*

### Phase 3: The Direct USB Backend Breakthrough (Obsolete Network Solution)
Initially, to send the generated ZJS file to the physical USB port without sandbox issues, we ran a loopback network server daemon on port 9100. It converted the spooled job to ZJS, and then called macOS's built-in CUPS USB backend `/usr/libexec/cups/backend/usb` to write the raw stream directly to the printer.
* *Issue*: This still required a running background server, python packages (like `pyusb`), and a custom Netpbm/Ghostscript translation layer.

### Phase 4: The 100% Native, Direct CUPS Raster Filter (Ultimate Solution)
Instead of bypassing the CUPS sandbox with a loopback TCP socket server and running a heavy Ghostscript rasterizer, we integrated directly into the CUPS printing pipeline natively:
1. **Native CUPS Raster Format:** We patched the official `foo2zjs.c` driver to parse the standard `application/vnd.cups-raster` format. Since macOS's built-in CUPS system natively converts PDFs and PostScript to raw raster scanlines, our custom filter (`rastertozjs`) does not need Ghostscript!
2. **Apple Silicon Native Compilation:** We compiled the patched driver natively as an ARM64 binary. By linking *only* to macOS's core `libcups.dylib` and `libSystem.dylib`, the binary is 100% sandbox-compliant and has zero third-party/Homebrew dependencies.
3. **No Active Servers:** The print queue directly calls `/Library/Printers/foo2zjs-str4ngemd/filter/rastertozjs`, which converts the stream and pipes the raw ZjStream output to the printer natively.

---

## 4. Translation Logic: Options, Page Sizes, and Resolution

With the Phase 4 native architecture, all printing parameters are parsed dynamically inside the C filter (`rastertozjs`) from the CUPS Raster page header and options string (`argv[4]`), matching the printer's physical hardware:

* **Duplex Printing:** The HP LaserJet Pro P1102 does **not** have automatic hardware duplexing. It only supports **manual duplexing**. Manual duplexing is managed entirely at the OS level by the macOS print spooler itself, sending print pages as separate simplex jobs. To prevent the printer engine from throwing an error, our C filter hardcodes the monochrome plane offset to `OutputStartPlane = 0` (monochrome mode) instead of Plane 4 (color-black mode), which was causing the firmware to panic and reboot.
* **Auto-Detecting Paper Size (Letter vs. A4):** The C filter reads the exact page dimensions (`cupsWidth` and `cupsHeight`) and paper type parameters (`header.cupsPageSize`) dynamically from the CUPS Raster stream. These are converted to standard ZJS dimensions, maintaining perfect alignment.
* **Resolution and Gray Richness (600 DPI vs. 1200 DPI):** The PPD defines two hardware-supported modes: `600x600 DPI` (1 Bit Per Pixel) and `1200x600 DPI` (2 Bits Per Pixel). When printing at `1200x600 DPI`, the filter receives `ResX = 1200`. The C code dynamically computes `Bpp = ResX / 600 = 2` and sets the horizontal resolution to `600`, which activates the printer's hardware-based **HP REt (Resolution Enhancement technology)** pulse-width modulation. The laser fires for fractions of a pixel width (yielding 4 gray states: off, 1/3, 2/3, and full duration) to print smooth diagonals and rich gray gradients.
* **Parameter Mapping:** For a complete mapping of option values (Density, EconoMode, InputSlot, MediaType), see **[COMPARISON.md](COMPARISON.md)**.

---

## 5. Key Lessons for Developers

* **Avoiding Ghostscript Sandboxing**: Instead of running a complex loopback server or bundling a heavy `gs` binary to escape sandbox blocks, we bypass Ghostscript entirely by reading standard `vnd.cups-raster` scanlines generated natively by macOS.
* **PJL Job Wrappers**: ZJS print streams must be wrapped in standard PJL envelopes (`start_doc()` and `end_doc()`). Failing to print these envelopes causes the printer controller to ignore the job.
* **Unified Diagnostic Logs**: CUPS redirects the `stderr` streams of all filters and backends to `/var/log/cups/error_log`. We can passively tail this file in Python without needing root privileges, providing a unified real-time console stream of USB connections and print jobs side-by-side.
