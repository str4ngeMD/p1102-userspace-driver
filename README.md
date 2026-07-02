# HP LaserJet Pro P1102 userspace Loopback Print Driver for macOS (Apple Silicon)

This repository contains a lightweight, future-proof userspace translation driver that allows the HP LaserJet Pro P1102 (and other ZjStream-based printers) to print natively on macOS ARM64 (Apple Silicon).

It completely bypasses the macOS CUPS sandbox restrictions and kernel-level USB interface locking without needing custom PPD hacks or SIP/security bypasses.

---

## How It Works

```
[Mac Apps] --> [CUPS User Queue] (Loopback Socket)
                     |
                     v (socket://127.0.0.1:9100)
             [p1102_daemon.py] (Userspace Translation Loop)
                     |
                     +---> Converts PS/PDF to PBM (via Ghostscript)
                     +---> Encodes PBM to ZJS (via foo2zjs)
                     |
                     v (Subprocess execution)
             [/usr/libexec/cups/backend/usb] (Direct USB transmission)
                     |
                     v
             [P1102 Printer] (USB)
```

1. **Auto-Firmware Upload**: The daemon monitors the USB bus. When you turn on the printer, it dynamically detects the printer's USB URI and automatically uploads the volatile firmware file `sihpP1102.dl` directly to the USB device.
2. **Translation Bridge**: When you print, macOS formats the pages as standard PostScript and sends them to our local socket server on port 9100. The daemon converts it to ZJS using userspace programs (`gs` and `foo2zjs`) and pipes the raw ZJS data directly to the USB printer via the system's USB backend.

*Note: Since the daemon writes directly to the USB port by invoking macOS's built-in CUPS USB backend, **you do not need a Raw Printer Queue or raw PPD files**. Only the single, user-facing print queue is registered on your Mac!*

---

## Step-by-Step Installation (For a Fresh Machine)

### 1. Install System Dependencies
Install Homebrew if not already installed, then fetch standard compiler tools, Ghostscript, and libusb:
```bash
# Install Homebrew dependencies
brew install ghostscript libusb
```

### 2. Set Up the Project Environment
Navigate to this directory and create a Python virtual environment to manage USB monitoring:
```bash
# Create local virtualenv
python3 -m venv venv
./venv/bin/pip install pyusb
```

### 3. Compile the `foo2zjs` Binary
The core printing translator is `foo2zjs`. Since it is written in standard C, we can compile it natively in seconds:
```bash
# Clone the open-source driver suite repository
git clone https://github.com/OpenPrinting/foo2zjs.git foo2zjs-src

# Compile the foo2zjs utility
cd foo2zjs-src
make foo2zjs

# Copy the compiled binary back to the root of this folder
cp foo2zjs ../foo2zjs
cd ..
```

### 4. Fetch the Volatile Firmware File
The LaserJet P1102 lacks a flash chip for its engine firmware and loads it into volatile RAM every time it boots. You can extract this file directly from any Linux machine/VM with HPLIP installed:

1. Locate the file on your Linux VM:
   `/usr/share/hplip/data/firmware/hp_laserjet_professional_p1102.fw.gz`
2. Copy it to your Mac:
   ```bash
   scp user@linux-vm-ip:/usr/share/hplip/data/firmware/hp_laserjet_professional_p1102.fw.gz ./firmware/
   ```
3. Decompress the file and rename it to `sihpP1102.dl`:
   ```bash
   cd firmware
   gunzip -k hp_laserjet_professional_p1102.fw.gz
   mv hp_laserjet_professional_p1102.fw sihpP1102.dl
   cd ..
   ```
*(Note: HPLIP's `.fw` format is already formatted with the HP PJL/ACL header, making it identical in contents to the `.dl` file).*

### 5. Create the CUPS Print Queue
Create the printer queue that you will print to from your Mac applications. This queue uses our local Generic PostScript PPD and points to our loopback socket server:
```bash
sudo lpadmin -p HP_LaserJet_P1102 -E -v "socket://127.0.0.1:9100" -P generic.ppd
```

---

## Running the Daemon

### Manual Verification
Run the daemon script in your terminal to verify everything works:
```bash
./venv/bin/python3 p1102_daemon.py
```
* **Verify firmware upload**: Connect or turn on your printer. The daemon output will dynamically log `Printer connection detected!`, identify the USB URI, and send the firmware file. The printer's green/orange lights will flash for 5 seconds as it initializes.
* **Verify printing**: Print a document from any native app (like Preview, Safari, Word) selecting the `HP_LaserJet_P1102` printer. The daemon will convert the job and print it instantly.

### Automatic Startup (Launchd Agent)
To make the loopback server load on login and run silently in the background:

1. Copy the plist configuration to your user's LaunchAgents directory:
   ```bash
   cp com.nativehp.p1102-daemon.plist ~/Library/LaunchAgents/
   ```
2. Register and start the background agent:
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nativehp.p1102-daemon.plist
   ```

You are all set! The background daemon will handle the printer automatically from now on.
