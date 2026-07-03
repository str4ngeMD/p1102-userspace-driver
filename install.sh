#!/bin/bash
# Description: Automated native driver installer for HP LaserJet Pro P1102 on macOS ARM64.
#              Copies binaries, PPD descriptions, firmware, configures a self-contained
#              python virtual environment, and loads the user launchd uploader daemon.
#              Run as normal user (the script will prompt for sudo when copying system files).

set -e

# Prevent running as root/sudo
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Do not run this script as root or with sudo!"
    echo "Please run it as a regular user: ./install.sh"
    echo "The script will ask for your administrator password automatically when writing to system folders."
    exit 1
fi

# Target folders
TARGET_DIR="/Library/Printers/foo2zjs-str4ngemd"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

echo "=== HP LaserJet Pro P1102 Native Driver Installer ==="

# 1. Create target system directories
echo "Creating system printer directories at $TARGET_DIR..."
sudo mkdir -p "$TARGET_DIR/filter"
sudo mkdir -p "$TARGET_DIR/bin"
sudo mkdir -p "$TARGET_DIR/firmware"

# 2. Copy the native filter binary
echo "Installing native C filter binary..."
if [ ! -f rastertozjs ]; then
    echo "ERROR: rastertozjs binary not found in current folder! Please compile it first."
    exit 1
fi
sudo cp rastertozjs "$TARGET_DIR/filter/rastertozjs"
sudo chown root:wheel "$TARGET_DIR/filter/rastertozjs"
sudo chmod 0555 "$TARGET_DIR/filter/rastertozjs"

# 3. Copy the custom PPD file
echo "Installing custom PPD definition..."
if [ ! -f HP_LaserJet_Professional_P1102.ppd ]; then
    echo "ERROR: HP_LaserJet_Professional_P1102.ppd not found in current folder!"
    exit 1
fi
sudo mkdir -p "$PPD_DIR"
sudo cp HP_LaserJet_Professional_P1102.ppd "$PPD_DIR/HP_LaserJet_Professional_P1102_Native.ppd"
sudo chown root:wheel "$PPD_DIR/HP_LaserJet_Professional_P1102_Native.ppd"
sudo chmod 0644 "$PPD_DIR/HP_LaserJet_Professional_P1102_Native.ppd"

# 4. Copy uploader daemon & firmware
echo "Installing firmware and uploader daemon script..."
if [ ! -f p1102_fw_uploader.py ]; then
    echo "ERROR: p1102_fw_uploader.py not found in current folder!"
    exit 1
fi
if [ ! -f firmware/sihpP1102.dl ]; then
    echo "ERROR: firmware/sihpP1102.dl not found in current folder!"
    exit 1
fi
sudo cp p1102_fw_uploader.py "$TARGET_DIR/bin/p1102_fw_uploader.py"
sudo chmod 0755 "$TARGET_DIR/bin/p1102_fw_uploader.py"
sudo cp firmware/sihpP1102.dl "$TARGET_DIR/firmware/sihpP1102.dl"

# 5. Create Python virtual environment and install pyusb dependency
echo "Setting up self-contained Python virtual environment inside target bin..."
sudo python3 -m venv "$TARGET_DIR/bin/venv"
sudo -H "$TARGET_DIR/bin/venv/bin/pip" install pyusb

# 6. Install launchd agent
echo "Installing launchd background agent..."
if [ ! -f com.str4ngemd.p1102-fw-uploader.plist ]; then
    echo "ERROR: com.str4ngemd.p1102-fw-uploader.plist not found in current folder!"
    exit 1
fi
mkdir -p "$LAUNCH_AGENTS_DIR"
cp com.str4ngemd.p1102-fw-uploader.plist "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist"
# Replace user home placeholder with the actual home directory path
sed -i '' "s|/Users/REPLACE_WITH_USER_NAME|$HOME|g" "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist"

# 7. Unload previous version of agent if active, then load the new one
echo "Loading launchd agent into user space..."
launchctl unload "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist" 2>/dev/null || true
launchctl load "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist"

echo "======================================================"
echo "Installation complete!"
echo "You can now safely delete the cloned repository directory."
echo "Tail the log file to verify the uploader is active:"
echo "tail -f ~/Library/Logs/com.str4ngemd.p1102-fw-uploader.log"
echo "======================================================"