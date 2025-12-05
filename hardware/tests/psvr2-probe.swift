#!/usr/bin/env swift

// PSVR2 Sense Controller Probe
// Standalone test to see what data we can get from a connected PSVR2 controller
// Run with: swift psvr2-probe.swift

import Foundation
import IOKit
import IOKit.hid

// Sony Vendor ID
let sonyVendorID = 0x054C

// Known PSVR2 Sense Controller Product IDs (may vary)
let knownPSVR2ProductIDs: Set<Int> = [
    0x0E45,  // PSVR2 Sense Controller (Left)
    0x0E46,  // PSVR2 Sense Controller (Right)
    0x0DF2,  // Possible alternate ID
]

print("=== PSVR2 Sense Controller Probe ===\n")

// Create HID Manager
let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// Open the HID Manager
let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    print("ERROR: Failed to open HID Manager: \(openResult)")
    exit(1)
}

// Set to match all devices first, then we'll filter
IOHIDManagerSetDeviceMatching(hidManager, nil)

// Get all HID devices
guard let deviceSet = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> else {
    print("No HID devices found")
    exit(0)
}

print("Found \(deviceSet.count) HID devices total\n")
print("Looking for Sony devices (Vendor ID: 0x054C)...\n")

var sonyDevices: [IOHIDDevice] = []

for device in deviceSet {
    // Get vendor ID
    guard let vendorIDRef = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int else {
        continue
    }

    // Get product ID
    let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0

    // Get product name
    let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

    // Get manufacturer
    let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? "Unknown"

    if vendorIDRef == sonyVendorID {
        sonyDevices.append(device)

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("SONY DEVICE FOUND!")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("  Product Name:  \(productName)")
        print("  Manufacturer:  \(manufacturer)")
        print("  Vendor ID:     0x\(String(format: "%04X", vendorIDRef))")
        print("  Product ID:    0x\(String(format: "%04X", productID))")

        // Check if it's a known PSVR2 controller
        if knownPSVR2ProductIDs.contains(productID) {
            print("  Status:        ✅ Known PSVR2 Sense Controller!")
        } else {
            print("  Status:        ⚠️  Sony device (not in known PSVR2 list)")
        }

        // Get usage page and usage
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        print("  Usage Page:    0x\(String(format: "%02X", usagePage)) (\(usagePageName(usagePage)))")
        print("  Usage:         0x\(String(format: "%02X", usage)) (\(usageName(usagePage, usage)))")

        // Get transport
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        print("  Transport:     \(transport)")

        // Get max input report size
        let maxInputReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let maxOutputReport = IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
        let maxFeatureReport = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0
        print("  Max Input:     \(maxInputReport) bytes")
        print("  Max Output:    \(maxOutputReport) bytes")
        print("  Max Feature:   \(maxFeatureReport) bytes")

        // Try to get report descriptor info
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            print("  Elements:      \(elements.count) HID elements")

            // Categorize elements
            var buttons = 0
            var axes = 0
            var hatSwitches = 0
            var others = 0
            var hasGyro = false
            var hasAccel = false

            for element in elements {
                let elementUsagePage = IOHIDElementGetUsagePage(element)
                let elementUsage = IOHIDElementGetUsage(element)
                _ = IOHIDElementGetType(element)

                switch Int(elementUsagePage) {
                case 0x09: // Button page
                    buttons += 1
                case 0x01: // Generic Desktop
                    switch Int(elementUsage) {
                    case 0x30...0x35: // X, Y, Z, Rx, Ry, Rz
                        axes += 1
                    case 0x39: // Hat switch
                        hatSwitches += 1
                    default:
                        others += 1
                    }
                case 0x20: // Sensor page
                    // Check for gyro/accel
                    if elementUsage >= 0x450 && elementUsage <= 0x453 {
                        hasGyro = true
                    }
                    if elementUsage >= 0x453 && elementUsage <= 0x456 {
                        hasAccel = true
                    }
                    others += 1
                default:
                    others += 1
                }
            }

            print("\n  Element Summary:")
            print("    Buttons:     \(buttons)")
            print("    Axes:        \(axes)")
            print("    Hat Switches:\(hatSwitches)")
            print("    Other:       \(others)")
            print("    Gyro Data:   \(hasGyro ? "✅ Yes" : "❌ No")")
            print("    Accel Data:  \(hasAccel ? "✅ Yes" : "❌ No")")
        }

        print("")
    }
}

if sonyDevices.isEmpty {
    print("No Sony devices found.")
    print("\nMake sure the PSVR2 controller is:")
    print("  1. Paired via Bluetooth (System Settings → Bluetooth)")
    print("  2. Turned on and connected")
    print("  3. Not exclusively claimed by another app")
    exit(0)
}

// Try to read from the first Sony device
print("\n=== Attempting to read input reports ===\n")

for device in sonyDevices {
    let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
    print("Testing: \(productName)")

    // Try to open the device
    let openDeviceResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    if openDeviceResult != kIOReturnSuccess {
        print("  ❌ Failed to open device: \(openDeviceResult)")
        if openDeviceResult == kIOReturnExclusiveAccess {
            print("     Device is exclusively claimed by another process")
        }
        continue
    }
    print("  ✅ Device opened successfully")

    // Set up input callback
    var reportBuffer = [UInt8](repeating: 0, count: 256)
    let maxReports = 100
    let startTime = Date()
    let timeout: TimeInterval = 5.0

    // Create a callback context
    class CallbackContext {
        var reportsReceived = 0
        var lastReport: [UInt8] = []
        var hasGyroActivity = false
    }
    let context = CallbackContext()
    let contextPtr = Unmanaged.passRetained(context).toOpaque()

    // Input report callback
    let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
        guard let ctx = context else { return }
        let callbackCtx = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()

        callbackCtx.reportsReceived += 1

        if reportLength > 0 {
            let reportData = Array(UnsafeBufferPointer(start: report, count: reportLength))

            // Only print first few reports and when data changes significantly
            if callbackCtx.reportsReceived <= 5 || callbackCtx.reportsReceived % 50 == 0 {
                print("  Report #\(callbackCtx.reportsReceived): ID=\(reportID), Len=\(reportLength)")

                // Print hex dump of first 32 bytes
                let bytesToShow = min(32, reportLength)
                var hexStr = "    Data: "
                for i in 0..<bytesToShow {
                    hexStr += String(format: "%02X ", reportData[i])
                }
                if reportLength > 32 {
                    hexStr += "..."
                }
                print(hexStr)
            }

            callbackCtx.lastReport = reportData
        }
    }

    // Register callback
    IOHIDDeviceRegisterInputReportCallback(
        device,
        &reportBuffer,
        reportBuffer.count,
        inputCallback,
        contextPtr
    )

    // Schedule with run loop
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    print("  Listening for input reports (\(Int(timeout)) seconds)...")
    print("  Try pressing buttons or moving the controller!\n")

    // Run the loop
    while Date().timeIntervalSince(startTime) < timeout {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)

        if context.reportsReceived >= maxReports {
            print("\n  Reached \(maxReports) reports, stopping...")
            break
        }
    }

    // Cleanup
    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()

    print("\n  Total reports received: \(context.reportsReceived)")

    if context.reportsReceived == 0 {
        print("  ⚠️  No input reports received!")
        print("     The device may not be sending data in this mode.")
    } else {
        print("  ✅ Device is sending data!")

        if !context.lastReport.isEmpty {
            print("\n  Last report (\(context.lastReport.count) bytes):")
            var hexStr = "    "
            for (i, byte) in context.lastReport.prefix(64).enumerated() {
                hexStr += String(format: "%02X ", byte)
                if (i + 1) % 16 == 0 {
                    print(hexStr)
                    hexStr = "    "
                }
            }
            if !hexStr.trimmingCharacters(in: .whitespaces).isEmpty {
                print(hexStr)
            }
        }
    }

    print("")
}

print("=== Probe Complete ===")

// Helper functions
func usagePageName(_ page: Int) -> String {
    switch page {
    case 0x01: return "Generic Desktop"
    case 0x02: return "Simulation"
    case 0x05: return "Game Controls"
    case 0x06: return "Generic Device"
    case 0x07: return "Keyboard"
    case 0x08: return "LED"
    case 0x09: return "Button"
    case 0x0C: return "Consumer"
    case 0x0D: return "Digitizers"
    case 0x20: return "Sensors"
    case 0xFF00...0xFFFF: return "Vendor Defined"
    default: return "Unknown"
    }
}

func usageName(_ page: Int, _ usage: Int) -> String {
    if page == 0x01 { // Generic Desktop
        switch usage {
        case 0x01: return "Pointer"
        case 0x02: return "Mouse"
        case 0x04: return "Joystick"
        case 0x05: return "Gamepad"
        case 0x06: return "Keyboard"
        case 0x30: return "X"
        case 0x31: return "Y"
        case 0x32: return "Z"
        case 0x33: return "Rx"
        case 0x34: return "Ry"
        case 0x35: return "Rz"
        case 0x39: return "Hat Switch"
        default: return "Unknown"
        }
    }
    return "Unknown"
}
