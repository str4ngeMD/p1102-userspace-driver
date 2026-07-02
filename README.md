# HP LaserJet Pro P1102 userspace Loopback Print Driver for macOS (Apple Silicon)

This repository contains a lightweight, future-proof userspace translation driver that allows the HP LaserJet Pro P1102 (and other ZjStream-based printers) to print natively on macOS ARM64 (Apple Silicon).

It completely bypasses the macOS CUPS sandbox restrictions and kernel-level USB interface locking without needing custom PPD hacks or SIP/security bypasses.

---

## How It Works

```
[Mac Apps] --> [CUPS User Queue] (Generic PostScript)
                     |
                     v (socket://127.0.0.1:9100)
             [p1102_daemon.py] (Userspace Translation Loop)
                     |
                     +---> Converts PS/PDF to PBM (via Ghostscript)
                     +---> Encodes PBM to ZJS (via foo2zjs)
                     |
                     v (lp -d HP_LaserJet_P1102_Raw -o raw)
             [CUPS Raw Queue] (Bypasses filters, pipes directly to USB)
                     |
                     v
             [P1102 Printer] (USB)
```

1. **Auto-Firmware Upload**: The daemon monitors the USB bus. When you turn on the printer, it automatically uploads the volatile firmware file `sihpP1102.dl` via the raw queue, initializing the printer.
2. **Translation Bridge**: When you print, macOS formats the pages as standard PostScript and sends them to our local socket server on port 9100. The daemon converts it to ZJS using userspace programs (`gs` and `foo2zjs`) and pipes the raw ZJS data directly to the printer.

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

### 5. Create the CUPS Queues

#### A. The Raw USB Queue
To create a raw byte channel to the printer without sandbox issues, we register the printer using the custom `raw.ppd` located in this directory:

1. Locate the printer's native USB URI:
   ```bash
   lpinfo -v | grep usb
   # Output example: direct usb://Hewlett-Packard/HP%20LaserJet%20Professional%20P1102?serial=000000000Q808QHRPR1a
   ```
2. Create the raw queue (replace `"YOUR_USB_URI"` with the output from the previous command):
   ```bash
   sudo lpadmin -p HP_LaserJet_P1102_Raw -E -v "YOUR_USB_URI" -P raw.ppd
   ```

#### B. The Loopback User Queue
Create the printer queue that you will print to from your Mac applications. This queue uses the standard, built-in Generic PostScript driver and points to our loopback socket server:
```bash
sudo lpadmin -p HP_LaserJet_P1102 -E -v "socket://127.0.0.1:9100" -m "drv:///sample.drv/generic.ppd"
```

---

## Running the Daemon

### Manual Verification
Run the daemon script in your terminal to verify everything works:
```bash
./venv/bin/python3 p1102_daemon.py
```
* **Verify firmware upload**: Connect or turn on your printer. The daemon output should log `Printer connection detected!` and send the firmware file. The printer's green/orange lights will flash for 5 seconds as it initializes.
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
