import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import os.lock

extension G502XHIDController {

    // MARK: - Input Report Processing

    func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        let now = Date()
        let timestamp = CACurrentMediaTime()

        // Look up which interface sent this report using the buffer pointer
        guard let deviceID = bufferPointerToDeviceID[report],
              let buffer = interfaceBuffers[deviceID] else {
            return
        }

        let debugInterfaceEnabled = interfaceDebugEnabledLock.withLock { _interfaceDebugEnabled }
        let isVendor = buffer.usagePage >= 0xFF00
        let isStandardMouse = buffer.usagePage == 0x0001 && buffer.usage == 0x0002
        guard debugInterfaceEnabled || isVendor || isStandardMouse else { return }

        // Update this interface's stored bytes + per-byte change tracking
        buffer.update(from: report, length: length, at: now)
        let copyLength = buffer.lastLength

        // Log first 5 reports from each interface for debugging
        buffer.reportCount += 1
        if buffer.reportCount <= 5 {
            let bytesHex = (0..<min(8, copyLength)).map { String(format: "%02X", buffer.bytes[$0]) }.joined(separator: " ")
            log("Report #\(buffer.reportCount) id=0x\(String(format: "%02X", reportID)) from UsagePage=0x\(String(format: "%04X", buffer.usagePage)) Usage=0x\(String(format: "%04X", buffer.usage)): [\(bytesHex)...]")
        }

        // Update cached interface info for debug UI (thread-safe), throttled to reduce overhead.
        if debugInterfaceEnabled, timestamp - lastInterfaceInfoUpdate > (1.0 / 10.0) {
            updateCachedInterfaceInfo()
            lastInterfaceInfoUpdate = timestamp
        }

        // Only forward unified button reports from relevant interfaces (vendor + standard mouse).
        guard isVendor || isStandardMouse else { return }

        if isVendor, copyLength >= 4 {
            let rid = buffer.bytes[0]

            // HID++ short/long messages (0x10/0x11) from the Lightspeed receiver.
            if rid == 0x10 || rid == 0x11 {
                let devNumber = buffer.bytes[1]
                let featureIndex = buffer.bytes[2]
                let function = buffer.bytes[3]
                let functionHigh = function & 0xF0

                // Match pending HID++ request (used during setup) and snapshot feature indexes.
                let (spyIdx, onboardIdx, reprogIdx): (UInt8?, UInt8?, UInt8?) = hidppLock.withLock {
                    hidppDeviceNumber = devNumber

                    let spy = mouseButtonSpyFeatureIndex
                    let onboard = onboardProfilesFeatureIndex
                    let reprog = reprogControlsFeatureIndex

                    if var pending = pendingHIDPPRequest,
                       pending.featureIndex == featureIndex,
                       pending.functionHighNibble == functionHigh {
                        var resp: [UInt8] = []
                        resp.reserveCapacity(copyLength)
                        for i in 0..<copyLength { resp.append(buffer.bytes[i]) }
                        pending.response = resp
                        pendingHIDPPRequest = pending
                        pending.semaphore.signal()
                    }

                    return (spy, onboard, reprog)
                }

                // MouseButtonSpy (0x8110) event0: pressed buttons bitfield (big-endian u16)
                if let spyIdx,
                   featureIndex == spyIdx,
                   functionHigh == 0x00,
                   copyLength >= 6 {
                    let bits = (UInt16(buffer.bytes[4]) << 8) | UInt16(buffer.bytes[5])
                    let previousBits: UInt16 = hidppLock.withLock {
                        let prev = lastMouseButtonSpyBits
                        lastMouseButtonSpyBits = bits
                        return prev
                    }
                    if previousBits != bits {
                        log("HID++: MouseButtonSpy bits=0x\(String(format: "%04X", bits))")
                    }
                    applyMouseButtonSpyBits(bits)
                    emitUnifiedReport(timestamp: timestamp)
                    return
                }

                // OnboardProfiles (0x8100) event0: currentProfileChanged (memoryType, profileIndex)
                if let onboardIdx,
                   featureIndex == onboardIdx,
                   functionHigh == 0x00,
                   copyLength >= 6 {
                    let memType = buffer.bytes[4]
                    let profileIndex = buffer.bytes[5]
                    log("HID++: profile changed mem=\(memType) index=\(profileIndex)")
                    // Not a physical button down/up event.
                    return
                }

                // Reprogrammable-controls notification: payload[0..7] contains up to 4 pressed CIDs.
                if let reprogIndex = reprogIdx,
                   featureIndex == reprogIndex,
                   functionHigh == 0x00,
                   copyLength >= 12 {
                    var newPressed: Set<UInt16> = []
                    let payloadStart = 4
                    for offset in stride(from: 0, to: 8, by: 2) {
                        let hi = buffer.bytes[payloadStart + offset]
                        let lo = buffer.bytes[payloadStart + offset + 1]
                        let cid = (UInt16(hi) << 8) | UInt16(lo)
                        if cid != 0 { newPressed.insert(cid) }
                    }

                    let pressedNow = newPressed.subtracting(pressedCIDs)
                    let releasedNow = pressedCIDs.subtracting(newPressed)
                    pressedCIDs = newPressed

                    for cid in pressedNow {
                        if let button = logicalButton(forCID: cid) {
                            setStableButton(button, pressed: true)
                        }
                    }
                    for cid in releasedNow {
                        if let button = logicalButton(forCID: cid) {
                            setStableButton(button, pressed: false)
                        }
                    }

                    emitUnifiedReport(timestamp: timestamp)
                }

                // Don't forward raw HID++ frames directly.
                return
            }

            // Legacy vendor bitfield reports (if diversion isn't active).
            if copyLength >= 2 {
                stableButtonBytes[0] = buffer.bytes[0]
                stableButtonBytes[1] = buffer.bytes[1]
                emitUnifiedReport(timestamp: timestamp)
            }
            return
        }

        if isStandardMouse {
            lastStandardMouseReport = Array(buffer.bytes.prefix(copyLength))
            emitUnifiedReport(timestamp: timestamp)
            return
        }
    }

    private func setStableButton(_ button: G502XLogicalButton, pressed: Bool) {
        guard let loc = logicalButtonMapping.buttonLocation(for: button) else { return }
        if loc.byte >= stableButtonBytes.count {
            stableButtonBytes += Array(repeating: 0, count: loc.byte - stableButtonBytes.count + 1)
        }
        let mask = UInt8(1 << loc.bit)
        if pressed {
            stableButtonBytes[loc.byte] |= mask
        } else {
            stableButtonBytes[loc.byte] &= ~mask
        }
    }

    private func applyMouseButtonSpyBits(_ bits: UInt16) {
        // MouseButtonSpy reports a 16-bit bitfield where bit 0 = button 1, bit 1 = button 2, etc.
        // Logitech G HUB numbering matches common mouse buttons:
        //  1=Left, 2=Right, 3=Middle, 4=Back, 5=Forward, 6=DPI Shift, 7=DPI Down, 8=DPI Up, 9=G9, 10/11=Tilts.
        let mapping: [(bit: Int, button: G502XLogicalButton)] = [
            (0, .left),
            (1, .right),
            (2, .middle),
            (3, .back),
            (4, .forward),
            (5, .dpiShift),
            (6, .dpiDown),
            (7, .dpiUp),
            (8, .g9),
            (9, .scrollTiltLeft),
            (10, .scrollTiltRight),
        ]

        for entry in mapping {
            let pressed = (bits & (UInt16(1) << UInt16(entry.bit))) != 0
            setStableButton(entry.button, pressed: pressed)
        }
    }

    private func emitUnifiedReport(timestamp: TimeInterval) {
        if !lastStandardMouseReport.isEmpty {
            var unified = lastStandardMouseReport
            for i in 0..<min(2, unified.count, stableButtonBytes.count) {
                unified[i] |= stableButtonBytes[i]
            }
            onReportData?(InputReport(bytes: unified, length: unified.count, timestamp: timestamp))
        } else {
            onReportData?(InputReport(bytes: stableButtonBytes, length: stableButtonBytes.count, timestamp: timestamp))
        }
    }
}

