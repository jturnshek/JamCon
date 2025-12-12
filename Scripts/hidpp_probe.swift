#!/usr/bin/env swift
import Foundation
import IOKit
import IOKit.hid

// JamCon HID++ probe for Logitech mice / receivers.
//
// Usage:
//   swift Scripts/hidpp_probe.swift
//
// What it does:
//   - Lists all Logitech (046D) HID interfaces.
//   - Opens vendor (usagePage >= 0xFF00) interfaces.
//   - Tries HID++ root feature-index queries for REPROG_CONTROLS (v4/v3/v2/v1)
//     across common device numbers.
//   - Prints every HID++ 0x10/0x11 input frame seen so you can press buttons
//     and observe notifications.

private let logitechVendorID: Int = 0x046D
private let featureIDsToProbe: [(String, UInt16)] = [
    ("FEATURE_SET",        0x0001),
    ("REPROG_CONTROLS_V4", 0x1B04),
    ("REPROG_CONTROLS_V3", 0x1B03),
    ("REPROG_CONTROLS_V2", 0x1B01),
    ("REPROG_CONTROLS",    0x1B00),
]

private let deviceNumbersToProbe: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xFF]
private let hidppSoftwareID: UInt8 = 0x02

final class HIDPPProbe {
    private struct Pending {
        let featureIndex: UInt8
        let functionHighNibble: UInt8
        let semaphore: DispatchSemaphore
        var response: [UInt8]? = nil
    }

    private let device: IOHIDDevice
    private var buffer: [UInt8]
    private var pending: Pending?
    private let lock = NSLock()
    var mouseButtonSpyFeatureIndex: UInt8? = nil
    private var lastMouseButtonSpyBits: UInt16?

    init(device: IOHIDDevice, bufferSize: Int) {
        self.device = device
        self.buffer = [UInt8](repeating: 0, count: max(64, bufferSize))
    }

    func openAndRegisterCallback() -> Bool {
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess && openResult != -536870201 {
            print("  !! failed to open vendor interface: \(openResult)")
            return false
        }

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            guard let baseAddr = bufferPtr.baseAddress else { return }
            IOHIDDeviceRegisterInputReportCallback(
                device,
                baseAddr,
                bufferPtr.count,
                { context, result, sender, type, reportID, report, length in
                    guard let ctx = context else { return }
                    let probe = Unmanaged<HIDPPProbe>.fromOpaque(ctx).takeUnretainedValue()
                    probe.handleInput(report: report, length: length, reportID: reportID)
                },
                context
            )
        }

        return true
    }

    private func pumpRunLoopUntilSignaled(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if semaphore.wait(timeout: .now()) == .success {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return false
    }

    func requestRootFeatureIndex(featureID: UInt16, deviceNumber: UInt8, timeout: TimeInterval = 0.8) -> UInt8? {
        let params: [UInt8] = [
            UInt8((featureID >> 8) & 0xFF),
            UInt8(featureID & 0xFF),
        ]

        let sema = DispatchSemaphore(value: 0)
        lock.lock()
        pending = Pending(featureIndex: 0x00, functionHighNibble: 0x00, semaphore: sema, response: nil)
        lock.unlock()

        sendHIDPPRequest(reportID: 0x10, deviceNumber: deviceNumber, featureIndex: 0x00, functionHighNibble: 0x00, params: params)

        _ = pumpRunLoopUntilSignaled(sema, timeout: timeout)

        lock.lock()
        let resp = pending?.response
        pending = nil
        lock.unlock()

        guard let resp, resp.count >= 5 else { return nil }
        return resp[4]
    }

    func performRequest(featureIndex: UInt8, functionHighNibble: UInt8, params: [UInt8], deviceNumber: UInt8, timeout: TimeInterval = 0.8) -> [UInt8]? {
        let reportIDToUse: UInt8 = params.count <= 3 ? 0x10 : 0x11

        let sema = DispatchSemaphore(value: 0)
        lock.lock()
        pending = Pending(featureIndex: featureIndex, functionHighNibble: functionHighNibble & 0xF0, semaphore: sema, response: nil)
        lock.unlock()

        sendHIDPPRequest(reportID: reportIDToUse, deviceNumber: deviceNumber, featureIndex: featureIndex, functionHighNibble: functionHighNibble, params: params)

        _ = pumpRunLoopUntilSignaled(sema, timeout: timeout)

        lock.lock()
        let resp = pending?.response
        pending = nil
        lock.unlock()

        guard let resp, resp.count >= 4 else { return nil }
        return Array(resp.dropFirst(4))
    }

    func listen(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func sendHIDPPRequest(
        reportID: UInt8,
        deviceNumber: UInt8,
        featureIndex: UInt8,
        functionHighNibble: UInt8,
        params: [UInt8]
    ) {
        let totalLength = reportID == 0x10 ? 7 : 20
        var report = [UInt8](repeating: 0, count: totalLength)
        report[0] = reportID
        report[1] = deviceNumber
        report[2] = featureIndex
        report[3] = (functionHighNibble & 0xF0) | hidppSoftwareID
        for (i, b) in params.enumerated() where (4 + i) < totalLength {
            report[4 + i] = b
        }

        let featureResult = report.withUnsafeMutableBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, CFIndex(ptr.count))
        }
        if featureResult != kIOReturnSuccess {
            let outputResult = report.withUnsafeMutableBytes { ptr -> IOReturn in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return kIOReturnError }
                return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, CFIndex(ptr.count))
            }
            if outputResult != kIOReturnSuccess {
                print("  !! HID++ write failed reportID=0x\(String(format: "%02X", reportID)) dev=0x\(String(format: "%02X", deviceNumber)) feat=0x\(String(format: "%02X", featureIndex)) fn=0x\(String(format: "%02X", functionHighNibble)) featureErr=\(featureResult) outputErr=\(outputResult)")
            }
        }
    }

    private func handleInput(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        guard length > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let rid = bytes[0]

        if rid == 0x10 || rid == 0x11 {
            let dev = bytes.count > 1 ? bytes[1] : 0
            let featIdx = bytes.count > 2 ? bytes[2] : 0
            let fn = bytes.count > 3 ? bytes[3] : 0
            let fnHigh = fn & 0xF0

            if let spyIdx = mouseButtonSpyFeatureIndex,
               featIdx == spyIdx,
               fnHigh == 0x00,
               bytes.count >= 6 {
                let bits = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
                if lastMouseButtonSpyBits != bits {
                    lastMouseButtonSpyBits = bits
                    var pressed: [String] = []
                    for i in 0..<16 where (bits & (UInt16(1) << UInt16(i))) != 0 {
                        pressed.append(String(i + 1))
                    }
                    let bitsHex = String(format: "%04X", bits)
                    print("  SPY buttons bits=0x\(bitsHex) pressed=[\(pressed.joined(separator: ", "))]")
                }
            }

            let payload = bytes.dropFirst(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  IN HID++ rid=0x\(String(format: "%02X", rid)) dev=0x\(String(format: "%02X", dev)) featIdx=0x\(String(format: "%02X", featIdx)) fn=0x\(String(format: "%02X", fn)) payload=[\(payload)]")

            lock.lock()
            if var p = pending, p.featureIndex == featIdx, p.functionHighNibble == fnHigh {
                p.response = bytes
                pending = p
                p.semaphore.signal()
            }
            lock.unlock()
        }
    }
}

func getIntProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
    IOHIDDeviceGetProperty(device, key) as? Int ?? 0
}

func getStringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
    IOHIDDeviceGetProperty(device, key) as? String ?? ""
}

print("=== JamCon HID++ Probe ===")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [kIOHIDVendorIDKey as String: logitechVendorID]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
    print("No Logitech HID devices found.")
    exit(0)
}

var vendorDevices: [IOHIDDevice] = []

print("Found \(deviceSet.count) Logitech HID interface(s):")
for (i, dev) in deviceSet.enumerated() {
    let pid = getIntProperty(dev, kIOHIDProductIDKey as CFString)
    let name = getStringProperty(dev, kIOHIDProductKey as CFString)
    let usagePage = getIntProperty(dev, kIOHIDPrimaryUsagePageKey as CFString)
    let usage = getIntProperty(dev, kIOHIDPrimaryUsageKey as CFString)
    let maxInput = getIntProperty(dev, kIOHIDMaxInputReportSizeKey as CFString)
    let loc = getIntProperty(dev, kIOHIDLocationIDKey as CFString)
    print(" [\(i)] \(name) pid=0x\(String(format: "%04X", pid)) usagePage=0x\(String(format: "%04X", usagePage)) usage=0x\(String(format: "%04X", usage)) maxIn=\(maxInput) loc=0x\(String(format: "%08X", loc))")
    if usagePage >= 0xFF00 && maxInput > 0 {
        vendorDevices.append(dev)
    }
}

if vendorDevices.isEmpty {
    print("No vendor (HID++) interfaces found.")
    exit(0)
}

for (idx, dev) in vendorDevices.enumerated() {
    let pid = getIntProperty(dev, kIOHIDProductIDKey as CFString)
    let name = getStringProperty(dev, kIOHIDProductKey as CFString)
    let maxInput = getIntProperty(dev, kIOHIDMaxInputReportSizeKey as CFString)
    let usagePage = getIntProperty(dev, kIOHIDPrimaryUsagePageKey as CFString)
    let usage = getIntProperty(dev, kIOHIDPrimaryUsageKey as CFString)

    print("\n=== Vendor interface \(idx): \(name) pid=0x\(String(format: "%04X", pid)) usagePage=0x\(String(format: "%04X", usagePage)) usage=0x\(String(format: "%04X", usage)) ===")

    let probe = HIDPPProbe(device: dev, bufferSize: maxInput)
    guard probe.openAndRegisterCallback() else { continue }

    print("Probing root feature indexes… (press no buttons yet)")
    for devNum in deviceNumbersToProbe {
        for (label, featID) in featureIDsToProbe {
            if let featIdx = probe.requestRootFeatureIndex(featureID: featID, deviceNumber: devNum) {
                if featIdx != 0 {
                    print("  dev=0x\(String(format: "%02X", devNum)) \(label) (0x\(String(format: "%04X", featID))) -> featureIndex=0x\(String(format: "%02X", featIdx))")
                }
            }
        }
    }

    // If FEATURE_SET is available on dev=0x01, enumerate feature IDs so we can see what featureIndex 0x09 actually is.
    if let featureSetIndex = probe.requestRootFeatureIndex(featureID: 0x0001, deviceNumber: 0x01), featureSetIndex != 0 {
        if let countPayload = probe.performRequest(featureIndex: featureSetIndex, functionHighNibble: 0x00, params: [], deviceNumber: 0x01),
           let countByte = countPayload.first {
            let count = Int(countByte) + 1  // Solaar: ROOT not included in count
            print("\nEnumerating FEATURES via FEATURE_SET (idx=0x\(String(format: "%02X", featureSetIndex))) count=\(count):")
            var onboardIdx: UInt8?
            var spyIdx: UInt8?
            for featureIndex in 0..<min(64, count) {
                if featureIndex == 0 { continue } // ROOT
                if let info = probe.performRequest(featureIndex: featureSetIndex, functionHighNibble: 0x10, params: [UInt8(featureIndex)], deviceNumber: 0x01),
                   info.count >= 4 {
                    let fid = (UInt16(info[0]) << 8) | UInt16(info[1])
                    let flags = info[2]
                    let ver = info[3]
                    print("  featureIndex=0x\(String(format: "%02X", featureIndex)) featureID=0x\(String(format: "%04X", fid)) flags=0x\(String(format: "%02X", flags)) ver=\(ver)")
                    if fid == 0x8100 { onboardIdx = UInt8(featureIndex) }
                    if fid == 0x8110 { spyIdx = UInt8(featureIndex) }
                }
            }
            print("End FEATURES\n")

            // BetterMouse-style setup for getting physical button down/up:
            // 1) OnboardProfiles -> Host mode (2)
            // 2) Start MouseButtonSpy (0x8110) to get a 16-bit pressed-bitfield event.
            if let onboardIdx, let spyIdx {
                print("Setting OnboardProfiles (0x8100) Host mode…")
                _ = probe.performRequest(featureIndex: onboardIdx, functionHighNibble: 0x10, params: [0x02], deviceNumber: 0x01)

                print("Starting MouseButtonSpy (0x8110)…")
                probe.mouseButtonSpyFeatureIndex = spyIdx
                _ = probe.performRequest(featureIndex: spyIdx, functionHighNibble: 0x10, params: [], deviceNumber: 0x01)
            }
        }
    }

    print("\nNow press G9 / other buttons for ~6s to see any HID++ notifications…")
    probe.listen(seconds: 6.0)
}

print("\nDone.")
