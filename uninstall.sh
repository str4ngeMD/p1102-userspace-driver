#!/bin/bash
# Description: Automated native driver uninstaller for HP LaserJet Pro P1102 on macOS ARM64.
#              Cleanly unloads the launchd agent, removes the agent plist, deletes the
#              system driver directories, and removes the custom PPD.

set -e

# Prevent running as root/sudo
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Do not run this script as root or with sudo!"
    echo "Please run it as a regular user: ./uninstall.sh"
    echo "The script will ask for your administrator password automatically when removing system folders."
    exit 1
fi

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
TARGET_DIR="/Library/Printers/foo2zjs-str4ngemd"
PPD_FILE="/Library/Printers/PPDs/Contents/Resources/HP_LaserJet_Professional_P1102_Native.ppd"

echo "=== HP LaserJet Pro P1102 Native Driver Uninstaller ==="

# 1. Unload and delete launchd agent
if [ -f "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist" ]; then
    echo "Unloading and removing launchd background agent..."
    launchctl unload "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist" || true
    rm -f "$LAUNCH_AGENTS_DIR/com.str4ngemd.p1102-fw-uploader.plist"
fi

# 2. Remove system directories and driver files
echo "Removing driver folders from $TARGET_DIR..."
sudo rm -rf "$TARGET_DIR"

# 3. Remove native PPD descriptor file
if [ -f "$PPD_FILE" ]; then
    echo "Removing custom PPD file..."
    sudo rm -f "$PPD_FILE"
fi

# 4. Remove user-level log files
echo "Removing user log files..."
rm -f "$HOME/Library/Logs/com.str4ngemd.p1102-fw-uploader.log"
rm -f "$HOME/Library/Logs/com.str4ngemd.p1102-fw-uploader.err"

echo "======================================================"
echo "Uninstallation complete!"
echo "======================================================"
