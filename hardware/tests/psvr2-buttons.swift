#!/usr/bin/env swift
// PSVR2 Button Probe - Monitor bytes to identify button bit positions
// Run with: swift psvr2-buttons.swift

import Foundation
import IOKit
import IOKit.hid

let sonyVendorID = 0x054C
let psvr2LeftProductID = 0x0E45
let psvr2RightProductID = 0x0E46

var reportBuffer = [UInt8](repeating: 0, count: 256)
var lastReport = [UInt8](repeating: 0, count: 256)
var baselineReport = [UInt8](repeating: 0, count: 256)
var hasBaseline = false
var reportCount = 0

print("=== PSVR2 Button Probe ===")
print("This tool monitors raw HID bytes to identify button mappings.")
print("Keep the controller STILL for the first 2 seconds to establish baseline.")
print("Then press buttons one at a time and watch which bytes change.\n")

// Create HID manager
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// Match all devices
IOHIDManagerSetDeviceMatching(manager, nil)

// Device matched callback
let matchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

    guard vendorID == sonyVendorID,
          productID == psvr2LeftProductID || productID == psvr2RightProductID else {
        return
    }

    print("✓ Found PSVR2 Controller: \(name)")
    print("  Vendor: 0x\(String(format: "%04X", vendorID))")
    print("  Product: 0x\(String(format: "%04X", productID))\n")

    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
        print("Failed to open device: \(openResult)")
        return
    }

    // Register input report callback
    IOHIDDeviceRegisterInputReportCallback(
        device,
        &reportBuffer,
        reportBuffer.count,
        { context, result, sender, type, reportID, report, length in
            handleReport(report: report, length: length, reportID: reportID)
        },
        nil
    )

    print("Monitoring HID reports... Press Ctrl+C to exit.\n")
    print("Establishing baseline (keep still for 2 seconds)...")
}

func handleReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
    guard reportID == 0x31, length >= 40 else { return }

    reportCount += 1

    // Copy report for comparison
    var currentReport = [UInt8](repeating: 0, count: length)
    for i in 0..<length {
        currentReport[i] = report[i]
    }

    // Establish baseline after ~120 reports (2 seconds at 60Hz)
    if !hasBaseline {
        if reportCount >= 120 {
            baselineReport = currentReport
            lastReport = currentReport
            hasBaseline = true
            print("✓ Baseline established!\n")
            print("Now press buttons one at a time. Changed bytes will be highlighted.\n")
            print("Key bytes to watch (likely button bytes based on DualSense layout):")
            print("  Bytes 7-9: Button bytes")
            print("  Bytes 4-5: Joystick X/Y\n")
        }
        return
    }

    // Check for changes from baseline
    var changedBytes: [(offset: Int, baseline: UInt8, current: UInt8)] = []

    for i in 0..<min(40, length) {
        // Skip gyro/accel bytes (17-30) as they constantly change
        if i >= 17 && i <= 30 { continue }

        if currentReport[i] != baselineReport[i] {
            changedBytes.append((i, baselineReport[i], currentReport[i]))
        }
    }

    // Only print if something changed (and wasn't just printed)
    if !changedBytes.isEmpty {
        var significantChange = false
        for change in changedBytes {
            if currentReport[change.offset] != lastReport[change.offset] {
                significantChange = true
                break
            }
        }

        if significantChange {
            print("─────────────────────────────────────────")
            print("CHANGES DETECTED:")
            for change in changedBytes {
                let diffBits = change.baseline ^ change.current
                let bitsSet = String(change.current, radix: 2).filter { $0 == "1" }.count
                print("  Byte \(String(format: "%2d", change.offset)): " +
                      "0x\(String(format: "%02X", change.baseline)) → " +
                      "0x\(String(format: "%02X", change.current)) " +
                      "(bits changed: \(String(diffBits, radix: 2).filter { $0 == "1" }.count), " +
                      "binary: \(String(format: "%08b", change.current)))")
            }

            // Show likely button interpretation
            print("\n  Interpretation:")
            for change in changedBytes {
                if change.offset >= 7 && change.offset <= 9 {
                    let diffBits = change.baseline ^ change.current
                    for bit in 0..<8 {
                        if (diffBits >> bit) & 1 == 1 {
                            let pressed = (change.current >> bit) & 1 == 1
                            print("    Byte \(change.offset) Bit \(bit): \(pressed ? "PRESSED" : "released")")
                        }
                    }
                } else if change.offset >= 4 && change.offset <= 5 {
                    print("    Byte \(change.offset): Joystick axis = \(change.current)")
                }
            }
            print("")
        }
    }

    lastReport = currentReport
}

// Register callbacks
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)

// Schedule with run loop
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

// Open manager
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    print("Failed to open HID manager: \(openResult)")
    exit(1)
}

print("Scanning for PSVR2 controllers...\n")

// Handle Ctrl+C
signal(SIGINT) { _ in
    print("\n\nExiting...")
    exit(0)
}

// Run
CFRunLoopRun()
