#!/usr/bin/env python3
import os
import sys
import time
import socket
import threading
import subprocess
import tempfile
import usb.core
import usb.util

# Configuration
PRINTER_VID = 0x03f0
PRINTER_PID = 0x002a

# Set paths dynamically relative to this script's directory for maximum portability
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIRMWARE_PATH = os.path.join(SCRIPT_DIR, "firmware", "sihpP1102.dl")
FOO2ZJS_PATH = os.path.join(SCRIPT_DIR, "foo2zjs")
GS_PATH = "/opt/homebrew/bin/gs"  # Fallback to 'gs' if not found

# Find gs on PATH if not at homebrew path
if not os.path.exists(GS_PATH):
    GS_PATH = "gs"

PORT = 9100
HOST = "127.0.0.1"

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

# -------------------------------------------------------------
# Dynamic USB URI Detection & Direct USB Backend Print Logic
# -------------------------------------------------------------
def detect_printer_uri():
    try:
        res = subprocess.run(["/usr/libexec/cups/backend/usb"], capture_output=True, text=True)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "usb://" in line and ("P1102" in line or "ZJS" in line):
                    parts = line.split()
                    if len(parts) >= 2:
                        uri = parts[1]
                        # Strip surrounding quotes if any
                        uri = uri.strip('"\'')
                        return uri
    except Exception as e:
        log(f"Error auto-detecting printer USB URI: {e}")
    return None

def send_raw_data(uri, file_path):
    if not uri:
        log("Error: Printer USB URI not detected.")
        return False
    
    env = os.environ.copy()
    env["DEVICE_URI"] = uri
    try:
        # Run CUPS USB backend directly as userspace subprocess
        res = subprocess.run(
            ["/usr/libexec/cups/backend/usb", "1", "", "", "1", "", file_path],
            env=env,
            capture_output=True,
            text=True
        )
        if res.returncode == 0:
            return True
        else:
            log(f"CUPS USB backend execution failed: {res.stderr}")
            return False
    except Exception as e:
        log(f"Exception during raw sending: {e}")
        return False

# -------------------------------------------------------------
# USB Monitor & Firmware Auto-Uploader
# -------------------------------------------------------------
def upload_firmware(uri):
    if not os.path.exists(FIRMWARE_PATH):
        log(f"Error: Firmware file not found at {FIRMWARE_PATH}")
        return False
    
    log(f"Uploading firmware '{FIRMWARE_PATH}' directly to USB device...")
    if send_raw_data(uri, FIRMWARE_PATH):
        log("Firmware upload job sent successfully! Printer should initialize (flashing orange/green lights)...")
        return True
    return False

def usb_monitor_thread():
    log("USB Monitor thread started...")
    was_connected = False
    
    # Run an initial check and upload on daemon startup if printer is connected
    try:
        dev = usb.core.find(idVendor=PRINTER_VID, idProduct=PRINTER_PID)
        if dev:
            uri = detect_printer_uri()
            if uri:
                log(f"Printer detected on startup at {uri}. Triggering initial firmware upload...")
                upload_firmware(uri)
                was_connected = True
    except Exception as e:
        log(f"Startup USB check failed: {e}")

    while True:
        try:
            dev = usb.core.find(idVendor=PRINTER_VID, idProduct=PRINTER_PID)
            if dev:
                if not was_connected:
                    log("Printer connection detected!")
                    # Wait a moment for OS to register device
                    time.sleep(2)
                    uri = detect_printer_uri()
                    if uri:
                        upload_firmware(uri)
                        was_connected = True
            else:
                if was_connected:
                    log("Printer disconnected.")
                    was_connected = False
        except Exception as e:
            # Avoid flooding log on temporary USB errors
            time.sleep(5)
            continue
        time.sleep(2)

# -------------------------------------------------------------
# TCP Port 9100 Print Job Receiver and Processor
# -------------------------------------------------------------
def handle_client(conn, addr):
    log(f"Received connection from {addr}")
    
    # Create temporary files
    fd_ps, temp_ps = tempfile.mkstemp(suffix=".ps")
    temp_pbm = temp_ps.replace(".ps", ".pbm")
    temp_zjs = temp_ps.replace(".ps", ".zjs")
    
    try:
        # 1. Read incoming data stream and save to temp PS file
        with os.fdopen(fd_ps, 'wb') as f:
            while True:
                data = conn.recv(8192)
                if not data:
                    break
                f.write(data)
        
        log(f"Job received. Size: {os.path.getsize(temp_ps)} bytes. Saved to {temp_ps}")
        
        # 2. Render PS/PDF to PBM using Ghostscript
        log("Rendering PostScript/PDF to PBM (600x600 dpi)...")
        gs_cmd = [
            GS_PATH,
            "-q",
            "-dBATCH",
            "-dSAFER",
            "-dQUIET",
            "-dNOPAUSE",
            "-sDEVICE=pbmraw",
            "-r600x600",
            f"-sOutputFile={temp_pbm}",
            temp_ps
        ]
        res_gs = subprocess.run(gs_cmd, capture_output=True, text=True)
        if res_gs.returncode != 0:
            raise Exception(f"Ghostscript rendering failed: {res_gs.stderr}")
            
        if not os.path.exists(temp_pbm) or os.path.getsize(temp_pbm) == 0:
            raise Exception("Ghostscript output PBM is empty or does not exist")
            
        log(f"PBM generated: {os.path.getsize(temp_pbm)} bytes.")
        
        # 3. Convert PBM to ZjStream using foo2zjs
        log("Converting PBM to ZjStream...")
        foo_cmd = [
            FOO2ZJS_PATH,
            "-r600x600",
            "-p1",  # Letter paper
            "-d1",  # Duplex off
            "-P",   # PJL headers
            "-z2",  # ZjStream v2
            "-L0",  # No logical page adjustments
            temp_pbm
        ]
        
        with open(temp_zjs, "wb") as out_f:
            res_foo = subprocess.run(foo_cmd, stdout=out_f, stderr=subprocess.PIPE, text=True)
            
        if res_foo.returncode != 0:
            raise Exception(f"foo2zjs conversion failed: {res_foo.stderr}")
            
        log(f"ZJS stream generated: {os.path.getsize(temp_zjs)} bytes.")
        
        # 4. Push ZJS directly to printer URI via CUPS USB backend
        uri = detect_printer_uri()
        if not uri:
            raise Exception("Failed to print: Printer USB URI not detected.")
            
        log(f"Sending ZJS directly to USB printer URI '{uri}'...")
        if send_raw_data(uri, temp_zjs):
            log("Print job successfully sent directly to USB printer!")
        else:
            log("Failed to send print job to USB printer.")
            
    except Exception as e:
        log(f"Error handling job: {e}")
    finally:
        conn.close()
        # Clean up temp files
        for path in [temp_ps, temp_pbm, temp_zjs]:
            if os.path.exists(path):
                try:
                    os.remove(path)
                except Exception:
                    pass

def tcp_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # Allow address reuse to avoid address already in use errors on restart
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    try:
        server.bind((HOST, PORT))
    except Exception as e:
        log(f"Failed to bind TCP socket to {HOST}:{PORT}: {e}")
        sys.exit(1)
        
    server.listen(5)
    log(f"TCP server listening on {HOST}:{PORT}...")
    
    while True:
        try:
            conn, addr = server.accept()
            client_thread = threading.Thread(target=handle_client, args=(conn, addr))
            client_thread.daemon = True
            client_thread.start()
        except KeyboardInterrupt:
            log("TCP server shutting down...")
            break
        except Exception as e:
            log(f"Accept error: {e}")
            time.sleep(1)

# -------------------------------------------------------------
# Main Entry Point
# -------------------------------------------------------------
if __name__ == "__main__":
    log("Starting HP LaserJet Pro P1102 userspace print daemon...")
    
    # Start USB monitor thread
    monitor = threading.Thread(target=usb_monitor_thread)
    monitor.daemon = True
    monitor.start()
    
    # Start TCP server (runs in main thread)
    try:
        tcp_server()
    except KeyboardInterrupt:
        log("Daemon stopped by user.")
