import Foundation
import IOKit
import IOKit.usb

// Configuration Constants
let PRINTER_VID = 0x03F0
let PRINTER_PID = 0x002A
let FIRMWARE_PATH = "/Library/Printers/foo2zjs-str4ngemd/firmware/sihpP1102.dl"

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
}

// Check if the printer has the firmware already loaded.
// When firmware is NOT loaded (bootloader mode), only 1 interface is exported (Interface 0).
// When firmware IS loaded, 2 interfaces are exported (Interface 0: Printer, Interface 1: HP EWS).
func isFirmwareLoaded(device: io_service_t) -> Bool {
    var childIterator: io_iterator_t = 0
    let kr = IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIterator)
    guard kr == KERN_SUCCESS else {
        log("Warning: Failed to read device registry entry children (error \(kr))")
        return false
    }
    
    defer {
        IOObjectRelease(childIterator)
    }
    
    var interfaceCount = 0
    var child = IOIteratorNext(childIterator)
    while child != 0 {
        var className = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(child, &className)
        let nameStr = String(cString: className)
        if nameStr == "IOUSBHostInterface" {
            interfaceCount += 1
        }
        IOObjectRelease(child)
        child = IOIteratorNext(childIterator)
    }
    
    return interfaceCount > 1
}

// Queries the CUPS usb backend to discover the matching printer's device URI.
func detectPrinterURI() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/cups/backend/usb")
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: .newlines) {
                if line.contains("HP") && line.contains("LaserJet") && line.contains("P1102") {
                    let parts = line.components(separatedBy: .whitespaces)
                    for part in parts {
                        if part.hasPrefix("usb://") {
                            return part
                        }
                    }
                }
            }
        }
    } catch {
        log("Error running CUPS backend to query URI: \(error)")
    }
    return nil
}

// Performs the actual firmware upload by passing the firmware file to CUPS backend via stdin.
func uploadFirmware(uri: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/libexec/cups/backend/usb")
    process.arguments = ["1", "uploader", "Upload firmware", "1", ""]
    
    var env = ProcessInfo.processInfo.environment
    env["DEVICE_URI"] = uri
    process.environment = env
    
    guard FileManager.default.fileExists(atPath: FIRMWARE_PATH) else {
        log("Error: Firmware file not found at \(FIRMWARE_PATH)")
        return false
    }
    
    guard let fileHandle = FileHandle(forReadingAtPath: FIRMWARE_PATH) else {
        log("Error: Cannot read firmware file at \(FIRMWARE_PATH)")
        return false
    }
    
    process.standardInput = fileHandle
    
    let pipeErr = Pipe()
    process.standardError = pipeErr
    
    do {
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            return true
        } else {
            let dataErr = pipeErr.fileHandleForReading.readDataToEndOfFile()
            if let errStr = String(data: dataErr, encoding: .utf8) {
                log("CUPS backend exited with status \(process.terminationStatus): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return false
        }
    } catch {
        log("Failed to run CUPS backend: \(error)")
        return false
    }
}

// Handles individual printer connection event.
func handlePrinterConnected(device: io_service_t) {
    // Get Serial Number from properties for logging
    var serialNumber: String = "unknown"
    var props: Unmanaged<CFMutableDictionary>? = nil
    if IORegistryEntryCreateCFProperties(device, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let dict = props?.takeRetainedValue() as? [String: Any] {
        if let serial = dict[kUSBSerialNumberString] as? String {
            serialNumber = serial
        }
    }
    
    log("Printer connection detected on USB bus (Serial: \(serialNumber)).")
    
    if isFirmwareLoaded(device: device) {
        log("Firmware is already active on this device. Skipping upload.")
        return
    }
    
    log("Firmware not active (device in bootloader mode). Commencing upload...")
    
    // Give macOS 2 seconds to establish the printer backend endpoint
    Thread.sleep(forTimeInterval: 2.0)
    
    guard let uri = detectPrinterURI() else {
        log("Error: Printer detected but failed to resolve CUPS URI. Make sure the printer queue is configured.")
        return
    }
    
    log("Resolved printer URI: \(uri)")
    log("Uploading firmware to device...")
    
    if uploadFirmware(uri: uri) {
        log("Firmware upload successful. Printer should reboot.")
    } else {
        log("Error: Firmware upload failed.")
    }
}

// Callback invoked by IOKit when a matching USB device is connected or matched.
func deviceAddedCallback(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    var device = IOIteratorNext(iterator)
    while device != 0 {
        handlePrinterConnected(device: device)
        IOObjectRelease(device)
        device = IOIteratorNext(iterator)
    }
}

// Background thread function to tail /var/log/cups/error_log for diagnostics.
func startLogMonitor() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    process.arguments = ["-f", "-n", "0", "/var/log/cups/error_log"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    if trimmed.contains("Job ") || trimmed.contains("rastertozjs") {
                        print("[CUPS] \(trimmed)")
                        fflush(stdout)
                    }
                }
            }
        }
    } catch {
        log("Warning: Failed to start CUPS log monitor: \(error)")
    }
}

// Main Execution Entrypoint
func main() {
    log("Starting HP LaserJet P1102 Native Uploader & Monitor Daemon...")
    log("Using firmware file: \(FIRMWARE_PATH)")
    
    // Start unified diagnostics stream
    log("Monitoring CUPS error log at /var/log/cups/error_log for printer logs...")
    startLogMonitor()
    
    // Create the IOKit notification port
    let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    guard notifyPort != nil else {
        log("Fatal Error: Failed to create IOKit notification port.")
        exit(1)
    }
    
    let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.defaultMode)
    
    // Setup matching dictionary
    let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matchingDict[kUSBVendorID] = PRINTER_VID
    matchingDict[kUSBProductID] = PRINTER_PID
    
    var iterator: io_iterator_t = 0
    let kr = IOServiceAddMatchingNotification(
        notifyPort,
        kIOMatchedNotification,
        matchingDict,
        deviceAddedCallback,
        nil,
        &iterator
    )
    
    if kr != KERN_SUCCESS {
        log("Fatal Error: Failed to register IOKit service notifications (error \(kr)).")
        exit(1)
    }
    
    // Process any printer already connected before the daemon was started
    deviceAddedCallback(refCon: nil, iterator: iterator)
    
    // Run loop to keep processing notifications asynchronously
    log("Uploader daemon is active. Listening for printer USB hotplug events...")
    CFRunLoopRun()
}

main()
