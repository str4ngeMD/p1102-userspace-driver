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
3. The background print daemon (`p1102_daemon.py`), running in the user space (fully outside the CUPS sandbox), receives the PostScript data.
4. The daemon runs `gs` and `foo2zjs` (compiled natively for ARM64) to rasterize the PostScript to PBM and encode it to ZjStream.
5. The daemon pipes the output to the physical USB printer.

This approach means zero security modifications or library hackery are needed!

### Phase 3: The Direct USB Backend Breakthrough (Final Solution)
Initially, to send the generated ZJS file to the physical USB port, we registered a second "Raw Queue" in CUPS (`HP_LaserJet_P1102_Raw`) and spooled jobs to it using `lp -d HP_LaserJet_P1102_Raw -o raw`. 
* *Issue*: This raw queue appeared in the macOS Print Dialogs, cluttering the UI and confusing users who tried to print to it.

We resolved this by directly calling macOS's built-in CUPS USB backend:
`/usr/libexec/cups/backend/usb`

When executed directly as a user subprocess with the target `DEVICE_URI` environment variable, the backend opens the USB channel, claims the printer interface, and writes raw data directly to the printer.

This eliminates:
1. **The Raw Queue**: No secondary printer queues are registered in CUPS.
2. **The custom `raw.ppd`**: Only our local `generic.ppd` is required.
3. **Hardcoded Device URIs**: The daemon runs the USB backend at startup to dynamically detect the connected printer's URI, supporting any USB port or serial number out-of-the-box.

---

## 4. Translation Logic: Duplex, Page Sizes, and Relayed Data

Understanding what is dynamically relayed from the client application versus what is statically configured in the daemon is essential for maintenance:

### A. How Duplex Printing is Handled
The HP LaserJet Pro P1102 does **not** have automatic hardware duplexing capabilities (automatic duplexing is only supported on HP's `d`-suffixed models like the P1606dn). It only supports **manual duplexing**.

On macOS, manual duplexing is managed entirely at the application and OS level:
1. macOS prints the odd pages first.
2. The OS prompts you with a dialog saying: *"Please take the printed pages, rotate/flip them, put them back into the tray, and click Resume."*
3. macOS then sends the even pages.

Because of this, the print daemon does not need to send hardware duplex commands to the printer. Hardcoding `-d1` (Duplex Off) in `foo2zjs` is correct and prevents the printer engine from throwing an error.

### B. Auto-Detecting Paper Size (Letter vs. A4)
To support multiple paper formats without hardcoding a single size, the daemon dynamically inspects the Netpbm bitmap header (`P4`) of the generated print job at runtime to extract the exact width and height of the rasterized pages. It then sets the `foo2zjs` `-p` parameter accordingly:

* **Height ~7016 px**: Setting print media to **A4** (`-p9`) — *default fallback size*.
* **Height ~6600 px**: Setting print media to **Letter** (`-p1`).
* **Height ~8400 px**: Setting print media to **Legal** (`-p3`).
* **Height ~4960 px**: Setting print media to **A5** (`-p5`).

This ensures that whatever size is configured in the macOS Print Dialog (A4, Letter, etc.) is perfectly translated and aligned on the printed page.

### C. What the Daemon Relays vs. Hardcodes

| Parameter | Type | Details |
| :--- | :--- | :--- |
| **Document Content** | **Relayed** | The actual visual pages, text, and graphics generated by your Mac applications. |
| **Page Count** | **Relayed** | The daemon handles whatever page numbers/count the application sends to the loopback. |
| **Page Dimensions** | **Relayed** | Extracted dynamically from the rendered PBM file to support A4, Letter, Legal, and A5. |
| **Duplex Mode (`-d1`)** | **Hardcoded** | Hardcoded to `1` (off) since the P1102 only supports manual OS-level duplexing. |
| **Resolution (`-r600x600`)** | **Hardcoded** | Set to `600x600` dpi, matching the native hardware capabilities of the P1102 engine. |
| **Protocol Version (`-z2`)** | **Hardcoded** | Set to ZjStream version 2, which is the exact version of the wire protocol expected by this printer model's firmware. |
| **PJL Headers (`-P`)** | **Hardcoded** | Injects standard HP Printer Job Language headers required by the printer controller to parse the stream. |

---

## 5. Key Lessons for Developers

* **USB Interface Locking**: macOS locks Class 7 (USB Printer) interfaces. Standard PyUSB scripts cannot claim the interface to write raw data unless you detach the kernel class driver, which is restricted on Apple Silicon. Using the OS's own `/usr/libexec/cups/backend/usb` solves this securely.
* **Firmware Timing**: The LaserJet P1102 flashes its orange/green status lights for ~5 seconds while loading firmware. The printer will ignore any print jobs sent during this initialization period. The daemon handles this by separating firmware upload checks from print job processing.
* **PostScript Translation**: Since macOS handles PostScript natively, routing the print job through a loopback socket using a Generic PostScript PPD ensures that macOS does all the layout rendering and outputs standard PostScript. The daemon only needs to perform rasterization (PS -> PBM) and compression (PBM -> ZJS).

