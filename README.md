# HP LaserJet Pro P1102 Native Driver & Firmware Uploader for macOS (Apple Silicon ARM64)

This repository contains the files and instructions for a **100% native, sandbox-friendly, zero-server** print driver and firmware uploader for the **HP LaserJet Pro P1102** running on macOS Apple Silicon (ARM64). 

It completely bypasses the macOS CUPS sandbox restrictions and kernel-level USB interface locking without needing custom loopback network daemons, external Ghostscript runtimes, or disabling System Integrity Protection (SIP).

---

## How It Works

```
[Mac Applications] ➔ [CUPS Print Spooler]
                            | (Natively renders PDF to Raster)
                            v
           [/Library/Printers/foo2zjs/filter/rastertozjs] (Native Filter)
                            | (Reads CUPS Raster, compresses to ZjStream)
                            v
           [/usr/libexec/cups/backend/usb] (Direct USB Transmission)
                            |
                            v
                      [P1102 Printer] (USB)
```

1. **No External Rasterizer (Bypasses Ghostscript):** Instead of executing Homebrew Ghostscript (`gs`) to perform rasterization (which is blocked by the CUPS sandbox), our native filter binary `rastertozjs` reads the standard `application/vnd.cups-raster` stream generated natively by macOS. It is a single, lightweight C executable (20KB) linking only to the core macOS system libraries (`libcups.2.dylib` and `libSystem.B.dylib`).
2. **Dynamic Parameter Mapping:** Resolves resolution (600 DPI vs. 1200 DPI), toner density (1–5), toner saving (EconoMode/Draft), input paper tray selection, and media paper type (labels, envelopes, cardstock) dynamically from standard print dialog settings.
3. **Passive Hotplug Daemon (`p1102_fw_uploader.py`):** The LaserJet P1102 stores its firmware in volatile memory and expects a firmware upload (`sihpP1102.dl`) every time it boots. The Python daemon runs passively, detects when the printer is connected to a USB port, uploads the firmware once, and then sleeps. 
4. **Unified Log Consolidation:** The daemon tails `/var/log/cups/error_log` in real-time, pulling filter progress and USB print events into a single, unified logging stream for easy diagnostics.

---

## Documentation Index

If you are a developer looking to rebuild, compile, or understand the internals of this project, explore the documentation links below:

* **[REPRODUCTION_GUIDE.md](REPRODUCTION_GUIDE.md)** - Step-by-step instructions to compile the driver from scratch, clone upstream repositories, and extract the firmware files.
* **[ARCHITECTURE.md](ARCHITECTURE.md)** - Deep dive into the driver's layout, component mapping, and the history of troubleshooting/debugging fixes.
* **[PPD_TRANSFORMATION.md](PPD_TRANSFORMATION.md)** - Explains how and why the upstream foomatic PPD was modified to comply with the modern macOS sandbox.
* **[DPI_AND_HALFTONING.md](DPI_AND_HALFTONING.md)** - Explains 600 vs. 1200 DPI resolution, bits per pixel (Bpp), pulse-width modulation, and gray dithering.
* **[COMPARISON.md](COMPARISON.md)** - A feature grid mapping what works dynamically vs. what is hardcoded compared to the official Linux driver.
* **[RESEARCH_HISTORY.md](RESEARCH_HISTORY.md)** - A logs/reference document detailing our UTM/QEMU setup, Wireshark USB traffic captures, and legacy daemons.

---

## File Manifest

* [foo2zjs_cups.patch](foo2zjs_cups.patch) - Unified diff patch file applied to upstream `foo2zjs.c`.
* [rastertozjs](rastertozjs) - Pre-compiled Apple Silicon native CUPS filter binary.
* [HP_LaserJet_Professional_P1102.ppd](HP_LaserJet_Professional_P1102.ppd) - Native CUPS PPD file.
* [original.ppd](original.ppd) - Legacy upstream Foomatic-based PPD file.
* [p1102_fw_uploader.py](p1102_fw_uploader.py) - USB monitor and log consolidator script.
* [com.str4ngemd.p1102-fw-uploader.plist](com.str4ngemd.p1102-fw-uploader.plist) - launchd system agent config file.
* `firmware/sihpP1102.dl` - Volatile engine firmware file.

---

## Installation (Using Pre-compiled Files)

Follow these steps to deploy the pre-compiled files already present in this repository:

### Step 1: Install System Folders & Binaries
Copy the pre-compiled filter binary to the standard CUPS filter path:
```bash
# Create filter and bin directories
sudo mkdir -p /Library/Printers/foo2zjs/filter/
sudo mkdir -p /Library/Printers/foo2zjs/bin/
sudo mkdir -p /Library/Printers/foo2zjs/firmware/

# Copy the native filter binary
sudo cp rastertozjs /Library/Printers/foo2zjs/filter/rastertozjs
sudo chown root:wheel /Library/Printers/foo2zjs/filter/rastertozjs
sudo chmod 0555 /Library/Printers/foo2zjs/filter/rastertozjs
```

### Step 2: Install the custom PPD
Deploy the PPD file so macOS can pair it automatically when the printer is connected:
```bash
sudo cp HP_LaserJet_Professional_P1102.ppd /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
sudo chown root:wheel /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
sudo chmod 0644 /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
```

### Step 3: Install the Firmware & Hotplug Daemon
1. Copy the uploader daemon, firmware, and plist files to their target paths:
   ```bash
   # Copy the script
   sudo cp p1102_fw_uploader.py /Library/Printers/foo2zjs/bin/p1102_fw_uploader.py
   sudo chmod 0755 /Library/Printers/foo2zjs/bin/p1102_fw_uploader.py

   # Copy the firmware
   sudo cp firmware/sihpP1102.dl /Library/Printers/foo2zjs/firmware/sihpP1102.dl

   # Copy the launchd agent
   cp com.str4ngemd.p1102-fw-uploader.plist ~/Library/LaunchAgents/com.str4ngemd.p1102-fw-uploader.plist
   ```
2. Create the Python virtual environment inside the destination directory so that the daemon runs self-contained. (Once complete, you can safely delete this cloned repository folder):
   ```bash
   cd /Library/Printers/foo2zjs/bin
   sudo python3 -m venv venv
   sudo ./venv/bin/pip install pyusb
   ```
3. Load the launchd background agent:
   ```bash
   launchctl load ~/Library/LaunchAgents/com.str4ngemd.p1102-fw-uploader.plist
   ```

---

## Dynamic Verification & Logging

1. **Clean Boot Test:** Power-cycle the printer completely (unplug both power and USB, wait 10 seconds, then plug back in and turn on).
2. **Auto-Recognition:** macOS will automatically detect the USB printer and create the printer queue using our custom `HP LaserJet Pro P1102 Native` driver!
3. **Consolidated Log Viewing:** You can tail the uploader daemon log in real-time to watch USB events and print jobs together:
   ```bash
   tail -f /Library/Printers/foo2zjs/bin/fw_uploader.log
   ```
   When you send a job, the logs will dynamically stream the entire pipeline:
   ```text
   [2026-07-03 18:58:12] Starting HP LaserJet P1102 USB Uploader & Monitor Daemon...
   [2026-07-03 18:58:12] Monitoring CUPS error log at /var/log/cups/error_log for P1102 print jobs...
   [2026-07-03 18:58:12] Uploading firmware '/Library/Printers/foo2zjs/firmware/sihpP1102.dl' to device URI 'usb://Hewlett-Packard/HP%20LaserJet%20Professional%20P1102?serial=...'...
   [2026-07-03 18:58:19] Firmware upload successful. Printer should boot up.
   [CUPS] [Job 52] Started filter /Library/Printers/foo2zjs/filter/rastertozjs (PID 98176)
   [CUPS] [Job 52] rastertozjs: Start Document (Model=2 Density=3 EconoMode=1 InputSlot=7 MediaType=1)
   [CUPS] [Job 52] rastertozjs: Processing Page 1 (4769 x 6828 @ 600 x 600 DPI)
   [CUPS] [Job 52] rastertozjs: Finished Page 1
   [CUPS] [Job 52] rastertozjs: End Document
   [CUPS] [Job 52] Sent 1358 bytes...
   [CUPS] [Job 52] Job completed.
   ```

---

## Uninstall

To completely remove the native print driver:
```bash
# Unload and delete launchd agent
launchctl unload ~/Library/LaunchAgents/com.str4ngemd.p1102-fw-uploader.plist
rm ~/Library/LaunchAgents/com.str4ngemd.p1102-fw-uploader.plist

# Remove driver files
sudo rm -rf /Library/Printers/foo2zjs
sudo rm -f /Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd
```
