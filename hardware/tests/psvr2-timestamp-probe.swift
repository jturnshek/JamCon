#!/usr/bin/env swift
// PSVR2 Timestamp Probe
// Collects IMU report timing using HID device timestamps vs host time.
// Usage: swift psvr2-timestamp-probe.swift (with controller connected and moving slightly)

import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import MachO

final class Probe {
    private let vendorID = 0x054C
    private let productIDs = [0x0E45, 0x0E46]
    private let reportID: UInt8 = 0x31
    private let reportLen = 78
    private let sampleTarget = 500

    // Vendor-defined IMU element that carries the 0x31 report
    private let imuUsagePage: UInt32 = 0xFF00
    private let imuUsage: UInt32 = 0x003B

    private struct Sample {
        let hostTs: Double
        let deviceTicks: UInt64?
        let bytes: [UInt8]
    }

    private var samples: [Sample] = []
    private var lastDeviceTicks: UInt64?
    private var firstDeviceTicks: UInt64?
    private var lastDeviceTicksSeen: UInt64?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?

    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(numer: 0, denom: 0)
        mach_timebase_info(&tb)
        return tb
    }()

    private func ticksToSeconds(_ ticks: UInt64) -> Double {
        let nanos = (Double(ticks) * Double(timebase.numer)) / Double(timebase.denom)
        return nanos / 1_000_000_000.0
    }

    func run() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = productIDs.map { [kIOHIDVendorIDKey as String: vendorID, kIOHIDProductIDKey as String: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let probe = Unmanaged<Probe>.fromOpaque(ctx).takeUnretainedValue()
            probe.handleMatch(device: device)
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
            print("Failed to open HID manager")
            return
        }

        print("Collecting \(sampleTarget) samples from first matched controller… move it slightly.")
        CFRunLoopRun()

        analyze()
    }

    private func handleMatch(device: IOHIDDevice) {
        // Only capture first match
        guard reportBuffer == nil else { return }

        if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
            print("Failed to open device")
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLen)
        reportBuffer = buffer
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            let probe = Unmanaged<Probe>.fromOpaque(ctx).takeUnretainedValue()
            probe.handleValue(value)
        }, selfPtr)

        IOHIDDeviceRegisterInputReportCallback(device, buffer, reportLen, { ctx, _, _, _, rid, report, length in
            guard let ctx = ctx else { return }
            let probe = Unmanaged<Probe>.fromOpaque(ctx).takeUnretainedValue()
            probe.handleReport(reportID: rid, report: report, length: length)
        }, selfPtr)
    }

    private func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetReportID(element) == reportID else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard page == imuUsagePage, usage == imuUsage else { return }

        let ticks = IOHIDValueGetTimeStamp(value)
        lastDeviceTicks = ticks
        if firstDeviceTicks == nil { firstDeviceTicks = ticks }
        lastDeviceTicksSeen = ticks
    }

    private func handleReport(reportID rid: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard rid == UInt32(reportID), length >= reportLen else { return }
        let host = CACurrentMediaTime()
        var bytes = [UInt8](repeating: 0, count: reportLen)
        for i in 0..<reportLen { bytes[i] = report[i] }
        samples.append(Sample(hostTs: host, deviceTicks: lastDeviceTicks, bytes: bytes))
        if samples.count >= sampleTarget {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func stats(label: String, values: [Double]) {
        guard !values.isEmpty else { print("\(label): no data"); return }
        let mean = values.reduce(0, +) / Double(values.count)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let std = sqrt(variance)
        print(String(format: "%@\\tmean=%.6f ms std=%.6f min=%.6f max=%.6f", label as NSString, mean * 1000, std * 1000, minV * 1000, maxV * 1000))
    }

    private func extendedCounterDts() -> (dts: [Double], ticksPerSec: Double) {
        guard samples.count >= 2 else { return ([], 0) }
        var ext: [Int64] = [0]
        let modulus: Int64 = 1 << 16
        for i in 1..<samples.count {
            let prev = Int64(samples[i-1].bytes[0]) | (Int64(samples[i-1].bytes[1]) << 8)
            let curr = Int64(samples[i].bytes[0]) | (Int64(samples[i].bytes[1]) << 8)
            var d = curr - prev
            if d < 0 { d += modulus }
            ext.append(ext.last! + d)
        }
        let elapsedHost = samples.last!.hostTs - samples.first!.hostTs
        let totalTicks = Double(ext.last!)
        let ticksPerSec = elapsedHost > 0 ? totalTicks / elapsedHost : 0
        var dts: [Double] = []
        for i in 1..<ext.count {
            let dt = Double(ext[i] - ext[i-1]) / ticksPerSec
            dts.append(dt)
        }
        return (dts, ticksPerSec)
    }

    private func analyze() {
        var dtHost: [Double] = []
        for i in 1..<samples.count { dtHost.append(samples[i].hostTs - samples[i-1].hostTs) }
        stats(label: "host", values: dtHost)

        var dtDev: [Double] = []
        for i in 1..<samples.count {
            if let t0 = samples[i-1].deviceTicks, let t1 = samples[i].deviceTicks {
                dtDev.append(ticksToSeconds(t1) - ticksToSeconds(t0))
            }
        }
        stats(label: "device", values: dtDev)

        let (dtCounter, tps) = extendedCounterDts()
        stats(label: "b0-1 ctr", values: dtCounter)
        print(String(format: "Estimated ticks/sec from b0-1: %.2f", tps))
        if let first = firstDeviceTicks, let last = lastDeviceTicksSeen {
            let span = ticksToSeconds(last) - ticksToSeconds(first)
            print(String(format: "Device ts span: %.6f s", span))
        } else {
            print("No device timestamps captured")
        }
        print(String(format: "mach_timebase_info: numer=%u denom=%u", timebase.numer, timebase.denom))
        print("Samples collected: \(samples.count)")

        reportBuffer?.deallocate()
    }
}

Probe().run()
