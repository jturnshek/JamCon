#!/usr/bin/env swift

// PSVR2 Sense Controller Deep Analyzer
// Shows all 16-bit values to find gyro/accel offsets
// Run with: swift psvr2-analyze.swift

import Foundation
import IOKit
import IOKit.hid

let sonyVendorID = 0x054C
let psvr2ProductIDs: Set<Int> = [0x0E45, 0x0E46]

print("=== PSVR2 Deep Analyzer ===\n")

let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hidManager, nil)

guard let deviceSet = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> else {
    print("No HID devices found")
    exit(0)
}

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

print("Device opened\n")

// Track min/max for each 16-bit position to find changing values
class AnalyzerContext {
    var frameCount = 0
    var minValues: [Int: Int16] = [:]
    var maxValues: [Int: Int16] = [:]
    var lastReport: [UInt8] = []
    var baselineReport: [UInt8]?
    var lastPrint = Date()
}

let context = AnalyzerContext()
let contextPtr = Unmanaged.passRetained(context).toOpaque()
var reportBuffer = [UInt8](repeating: 0, count: 256)

let inputCallback: IOHIDReportCallback = { ctx, result, sender, type, reportID, report, reportLength in
    guard let context = ctx else { return }
    let analyzer = Unmanaged<AnalyzerContext>.fromOpaque(context).takeUnretainedValue()

    guard reportLength >= 40 else { return }

    let data = Array(UnsafeBufferPointer(start: report, count: reportLength))
    analyzer.frameCount += 1
    analyzer.lastReport = data

    // Capture baseline on first frame
    if analyzer.baselineReport == nil {
        analyzer.baselineReport = data
    }

    // Track min/max for each 16-bit offset
    for offset in stride(from: 0, to: min(60, reportLength - 1), by: 2) {
        let value = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
        if let existing = analyzer.minValues[offset] {
            analyzer.minValues[offset] = min(existing, value)
            analyzer.maxValues[offset] = max(analyzer.maxValues[offset]!, value)
        } else {
            analyzer.minValues[offset] = value
            analyzer.maxValues[offset] = value
        }
    }

    // Print periodically
    let now = Date()
    guard now.timeIntervalSince(analyzer.lastPrint) >= 0.5 else { return }
    analyzer.lastPrint = now

    print("\u{1B}[2J\u{1B}[H")  // Clear screen
    print("=== PSVR2 Analyzer - Frame \(analyzer.frameCount) ===\n")

    print("Finding values that CHANGE (potential gyro/accel):\n")
    print("Offset  Current    Min        Max        Range      Notes")
    print("─────────────────────────────────────────────────────────────")

    var candidateIMU: [(offset: Int, range: Int)] = []

    for offset in stride(from: 0, to: min(60, reportLength - 1), by: 2) {
        let current = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
        let minVal = analyzer.minValues[offset] ?? 0
        let maxVal = analyzer.maxValues[offset] ?? 0
        let range = Int(maxVal) - Int(minVal)

        // Only show values with significant range
        if range > 100 {
            var notes = ""

            // Check if it looks like gyro (bipolar, centered around 0)
            if minVal < -500 && maxVal > 500 {
                notes = "← GYRO?"
            }
            // Check if it looks like accel (typically has gravity offset)
            else if (minVal > 1000 && maxVal < 5000) || (minVal > -5000 && maxVal < -1000) {
                notes = "← ACCEL?"
            }
            // Large swings might be motion data
            else if range > 5000 {
                notes = "← IMU?"
            }

            print(String(format: " %2d     %+6d     %+6d     %+6d     %6d     %@",
                         offset, current, minVal, maxVal, range, notes))

            if range > 500 {
                candidateIMU.append((offset: offset, range: range))
            }
        }
    }

    print("\n\nRaw bytes (first 40):")
    var hexLine1 = "Offset: "
    var hexLine2 = "  Hex:  "
    for i in 0..<min(40, data.count) {
        if i > 0 && i % 20 == 0 {
            print(hexLine1)
            print(hexLine2)
            hexLine1 = "        "
            hexLine2 = "        "
        }
        hexLine1 += String(format: "%2d ", i)
        hexLine2 += String(format: "%02X ", data[i])
    }
    print(hexLine1)
    print(hexLine2)

    // Highlight changed bytes vs baseline
    if let baseline = analyzer.baselineReport {
        var changedBytes = "Changed:"
        for i in 0..<min(40, data.count) {
            if data[i] != baseline[i] {
                changedBytes += " [\(i)]"
            }
        }
        print("\n\(changedBytes)")
    }

    print("\n\nMove the controller to see which values change!")
    print("Gyro values should swing positive/negative around 0")
    print("Accel should show ~2000-4000 range with gravity offset")
}

IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, inputCallback, contextPtr)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

print("Collecting baseline... move the controller!\n")

let startTime = Date()
let runDuration: TimeInterval = 12.0

while Date().timeIntervalSince(startTime) < runDuration {
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
}

// Final summary
print("\n\n=== FINAL ANALYSIS ===\n")

var gyroOffsets: [Int] = []
var accelOffsets: [Int] = []

for offset in stride(from: 0, to: 60, by: 2) {
    let minVal = context.minValues[offset] ?? 0
    let maxVal = context.maxValues[offset] ?? 0
    let range = Int(maxVal) - Int(minVal)

    if range > 2000 {
        if minVal < -1000 && maxVal > 1000 {
            gyroOffsets.append(offset)
        } else {
            accelOffsets.append(offset)
        }
    }
}

print("Likely GYRO offsets: \(gyroOffsets)")
print("Likely ACCEL offsets: \(accelOffsets)")
print("\nTotal frames analyzed: \(context.frameCount)")

IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
