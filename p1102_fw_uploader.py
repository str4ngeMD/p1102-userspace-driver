#!/usr/bin/env python3
# Save as: print lab 2/p1102_fw_uploader.py
# Description: Simple, lightweight background daemon that monitors USB connection
#              events for the HP LaserJet Pro P1102, automatically uploads firmware,
#              and dynamically consolidates CUPS print logs in real-time.
#              Requires `pyusb` installed.

import os
import sys
import time
import subprocess
import threading
import re
import usb.core
import usb.util

PRINTER_VID = 0x03F0
PRINTER_PID = 0x002A

# Try to find the firmware file in standard installation locations
FIRMWARE_LOCATIONS = [
    "/Library/Printers/foo2zjs/firmware/sihpP1102.dl",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "sihpP1102.dl"),
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "../sihpP1102.dl"),
    "/Users/sorce/code/hplipmaybe/sihpP1102.dl"
]

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

def find_firmware():
    for loc in FIRMWARE_LOCATIONS:
        if os.path.exists(loc):
            return loc
    return None

def detect_printer_uri():
    try:
        # Run the cups USB backend to discover the printer's connection URI
        res = subprocess.run(["/usr/libexec/cups/backend/usb"], capture_output=True, text=True)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "usb://" in line and ("P1102" in line or "ZJS" in line or "002A" in line.upper()):
                    parts = line.split()
                    if len(parts) >= 2:
                        uri = parts[1]
                        return uri.strip('"\'')
    except Exception as e:
        log(f"Error auto-detecting printer USB URI: {e}")
    return None

def upload_firmware(uri, fw_path):
    log(f"Uploading firmware '{fw_path}' to device URI '{uri}'...")
    env = os.environ.copy()
    env["DEVICE_URI"] = uri
    try:
        # Send raw firmware via CUPS native USB backend
        res = subprocess.run(["/usr/libexec/cups/backend/usb", "1", "", "", "1", "", fw_path], env=env, capture_output=True, text=True)
        if res.returncode == 0:
            log("Firmware upload successful. Printer should boot up.")
            return True
        else:
            log(f"Firmware upload failed with code {res.returncode}. Stderr: {res.stderr}")
    except Exception as e:
        log(f"Exception during firmware upload: {e}")
    return False

def cups_log_monitor_thread():
    log_path = "/var/log/cups/error_log"
    if not os.path.exists(log_path):
        log(f"Warning: CUPS error log not found at {log_path}. CUPS log tailing disabled.")
        return

    log(f"Monitoring CUPS error log at {log_path} for P1102 print jobs...")
    
    # Set to keep track of job IDs related to our printer
    active_jobs = set()
    
    try:
        with open(log_path, "r", errors="ignore") as f:
            # Seek to the end of the file so we only tail new entries
            f.seek(0, os.SEEK_END)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.1)
                    continue
                
                # Check for Job ID in brackets like [Job 50]
                job_match = re.search(r"\[Job (\d+)\]", line)
                if job_match:
                    job_id = job_match.group(1)
                    
                    # Dynamically track print jobs relating to our printer queue or filter
                    if "HP_LaserJet_Professional_P1102" in line or "rastertozjs" in line:
                        active_jobs.add(job_id)
                        
                    # If this is a line for an active P1102 job, print it!
                    if job_id in active_jobs:
                        clean_line = line.strip()
                        # Strip timestamp brackets from CUPS to keep logs clean
                        clean_line = re.sub(r"^[DIEF] \[\d{2}/\w+/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4}\] ", "", clean_line)
                        print(f"[CUPS] {clean_line}", flush=True)
                        
                    # Stop tracking job when it is completed or unloaded
                    if "Job completed" in line or "Unloading..." in line:
                        active_jobs.discard(job_id)
                        
    except Exception as e:
        log(f"Error in CUPS log monitor: {e}")

def main():
    log("Starting HP LaserJet P1102 USB Uploader & Monitor Daemon...")
    
    fw_path = find_firmware()
    if not fw_path:
        log("ERROR: Firmware file 'sihpP1102.dl' not found in any standard location:")
        for loc in FIRMWARE_LOCATIONS:
            log(f"  - {loc}")
        log("Please place the firmware file in one of these paths.")
        sys.exit(1)
        
    log(f"Using firmware: {fw_path}")
    
    # Start the CUPS log monitor thread
    log_thread = threading.Thread(target=cups_log_monitor_thread, daemon=True)
    log_thread.start()
    
    was_connected = False
    
    # Run initial check in case printer is already plugged in at startup
    try:
        dev = usb.core.find(idVendor=PRINTER_VID, idProduct=PRINTER_PID)
        if dev:
            uri = detect_printer_uri()
            if uri:
                upload_firmware(uri, fw_path)
                was_connected = True
    except Exception as e:
        log(f"Initial setup check failed: {e}")

    # Core uploader loop
    while True:
        try:
            dev = usb.core.find(idVendor=PRINTER_VID, idProduct=PRINTER_PID)
            if dev and not was_connected:
                log("Printer connection detected on USB bus.")
                # Give it a moment to initialize the descriptor tables
                time.sleep(2)
                uri = detect_printer_uri()
                if uri:
                    upload_firmware(uri, fw_path)
                    was_connected = True
                else:
                    log("Warning: Printer connected but CUPS USB backend did not return a URI yet. Retrying...")
            elif not dev and was_connected:
                log("Printer disconnected from USB bus.")
                was_connected = False
        except Exception as e:
            log(f"Error in monitor loop: {e}")
            time.sleep(5)
            continue
            
        time.sleep(2)

if __name__ == "__main__":
    main()
