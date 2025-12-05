#!/usr/bin/env swift

// PSVR2 Sense Controller Data Decoder
// Attempts to decode and visualize gyro/accel data from the raw reports
// Run with: swift psvr2-decode.swift

import Foundation
import IOKit
import IOKit.hid

let sonyVendorID = 0x054C
let psvr2ProductIDs: Set<Int> = [0x0E45, 0x0E46]

print("=== PSVR2 Sense Controller Decoder ===\n")
print("Press Ctrl+C to stop\n")

let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hidManager, nil)

guard let deviceSet = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> else {
    print("No HID devices found")
    exit(0)
}

// Find PSVR2 controller
var targetDevice: IOHIDDevice?
for device in deviceSet {
    guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
          let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int else {
        continue
    }

    if vendorID == sonyVendorID && psvr2ProductIDs.contains(productID) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        print("Found: \(name)")
        targetDevice = device
        break
    }
}

guard let device = targetDevice else {
    print("No PSVR2 controller found")
    exit(1)
}

let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    print("Failed to open device")
    exit(1)
}

print("Device opened, decoding reports...\n")

// Callback context
class DecoderContext {
    var frameCount = 0
    var lastPrint = Date()
    var printInterval: TimeInterval = 0.1  // Print every 100ms

    // Store last values for change detection
    var lastButtons: UInt32 = 0
    var lastStickL: (x: Int, y: Int) = (0, 0)
    var lastStickR: (x: Int, y: Int) = (0, 0)
    var lastGyro: (x: Int16, y: Int16, z: Int16) = (0, 0, 0)
    var lastAccel: (x: Int16, y: Int16, z: Int16) = (0, 0, 0)
}

let context = DecoderContext()
let contextPtr = Unmanaged.passRetained(context).toOpaque()

var reportBuffer = [UInt8](repeating: 0, count: 256)

let inputCallback: IOHIDReportCallback = { ctx, result, sender, type, reportID, report, reportLength in
    guard let context = ctx else { return }
    let decoder = Unmanaged<DecoderContext>.fromOpaque(context).takeUnretainedValue()

    guard reportLength >= 50 else { return }

    let data = Array(UnsafeBufferPointer(start: report, count: reportLength))
    decoder.frameCount += 1

    // Based on DualSense-like report structure (report ID 0x31)
    // The PSVR2 Sense controller likely uses similar format

    // Try to extract data at various offsets
    // DualSense-style offsets (after report ID):
    // Offset 0: Report ID (0x31)
    // Offset 1-2: Stick L X, Stick L Y
    // Offset 3-4: Stick R X, Stick R Y
    // ... buttons around offset 7-9
    // ... gyro/accel starting around offset 15-27

    let stickLX = Int(data[1])
    let stickLY = Int(data[2])
    let stickRX = Int(data[3])
    let stickRY = Int(data[4])

    // Buttons might be at offset 7-9
    let buttons1 = data[7]
    let buttons2 = data[8]
    let buttons3 = data[9]
    let buttons = UInt32(buttons1) | (UInt32(buttons2) << 8) | (UInt32(buttons3) << 16)

    // Try multiple offsets for gyro/accel data
    // Common pattern is 6 signed 16-bit values (gyro x,y,z then accel x,y,z)

    func readInt16LE(_ offset: Int) -> Int16 {
        guard offset + 1 < data.count else { return 0 }
        return Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
    }

    // Try offset 15 (DualSense-like)
    let gyroX_15 = readInt16LE(15)
    let gyroY_15 = readInt16LE(17)
    let gyroZ_15 = readInt16LE(19)
    let accelX_15 = readInt16LE(21)
    let accelY_15 = readInt16LE(23)
    let accelZ_15 = readInt16LE(25)

    // Try offset 19 (alternative)
    let gyroX_19 = readInt16LE(19)
    let gyroY_19 = readInt16LE(21)
    let gyroZ_19 = readInt16LE(23)
    let accelX_19 = readInt16LE(25)
    let accelY_19 = readInt16LE(27)
    let accelZ_19 = readInt16LE(29)

    // Check if enough time has passed to print
    let now = Date()
    guard now.timeIntervalSince(decoder.lastPrint) >= decoder.printInterval else { return }
    decoder.lastPrint = now

    // Clear line and print
    print("\u{1B}[2K\r", terminator: "")  // Clear line

    // Print formatted output
    var output = "Frame \(decoder.frameCount) | "

    // Sticks
    output += "Sticks: L(\(String(format: "%3d", stickLX)),\(String(format: "%3d", stickLY))) "
    output += "R(\(String(format: "%3d", stickRX)),\(String(format: "%3d", stickRY))) | "

    // Buttons
    output += "Btn: \(String(format: "%06X", buttons)) | "

    // IMU at offset 15
    output += "IMU@15: G(\(String(format: "%+6d", gyroX_15)),\(String(format: "%+6d", gyroY_15)),\(String(format: "%+6d", gyroZ_15))) "
    output += "A(\(String(format: "%+6d", accelX_15)),\(String(format: "%+6d", accelY_15)),\(String(format: "%+6d", accelZ_15)))"

    print(output, terminator: "")
    fflush(stdout)

    // Also periodically print raw hex for analysis
    if decoder.frameCount % 100 == 1 {
        print("\n\nRaw (first 40 bytes):")
        var hex = ""
        for i in 0..<min(40, data.count) {
            hex += String(format: "%02X ", data[i])
            if (i + 1) % 16 == 0 { hex += "\n" }
        }
        print(hex)
        print("")
    }
}

IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, inputCallback, contextPtr)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

print("Move the controller or press buttons...")
print("(Running for 8 seconds)\n")

// Run for 8 seconds
let startTime = Date()
let runDuration: TimeInterval = 8.0

while Date().timeIntervalSince(startTime) < runDuration {
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
}

print("\n\n=== Test Complete ===")
IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
