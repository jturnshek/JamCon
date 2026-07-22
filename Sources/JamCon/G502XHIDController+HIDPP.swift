import Foundation

extension G502XHIDController {

    // MARK: - HID++ setup

    func teardownHIDPPButtonReporting() {
        let (device, spyIdx, spyActive, onboardIdx, restoreMode, devNumber): ((any HIDDeviceHandle)?, UInt8?, Bool, UInt8?, UInt8?, UInt8) = hidppLock.withLock {
            return (
                hidppDevice,
                mouseButtonSpyFeatureIndex,
                mouseButtonSpyActive,
                onboardProfilesFeatureIndex,
                onboardProfilesRestoreMode,
                hidppDeviceNumber
            )
        }

        guard let device else { return }

        // Stop MouseButtonSpy if we started it.
        if let spyIdx, spyActive {
            sendHIDPPRequest(reportID: 0x10, deviceNumber: devNumber, featureIndex: spyIdx, function: 0x20, params: [], on: device)
        }

        // Restore OnboardProfiles mode if we changed it.
        if let onboardIdx, let restoreMode {
            sendHIDPPRequest(reportID: 0x10, deviceNumber: devNumber, featureIndex: onboardIdx, function: 0x10, params: [restoreMode], on: device)
        }
    }

    /// Configure the mouse so we can observe all physical button presses/releases.
    ///
    /// For G502X via Lightspeed receiver, G9 defaults to switching on-board profiles (HID++ 0x8100),
    /// which produces profile-change events instead of a button down/up. BetterMouse-style behavior is:
    /// 1) Switch OnboardProfiles to Host mode (disable on-board mode)
    /// 2) Start MouseButtonSpy (HID++ 0x8110) which reports a 16-bit pressed-bitfield
    func setupHIDPPDivertedButtons(expectedGeneration: UInt64) {
        let (device, initialDevNumber) = hidppLock.withLock { () -> ((any HIDDeviceHandle)?, UInt8) in
            guard hidppGeneration == expectedGeneration else { return (nil, hidppDeviceNumber) }
            return (hidppDevice, hidppDeviceNumber)
        }
        guard let device else { return }

        var devNumbersToTry: [UInt8] = []
        for dev in [initialDevNumber, 0x01, 0xFF] where !devNumbersToTry.contains(dev) {
            devNumbersToTry.append(dev)
        }

        // 1) Enumerate HID++ features via FEATURE_SET so we can find vendor gaming features (0x8100/0x8110).
        var devNumberUsed: UInt8?
        var features: [UInt16: UInt8] = [:]

        for dev in devNumbersToTry {
            if let mapping = enumerateHIDPPFeatures(deviceNumber: dev, on: device) {
                features = mapping
                devNumberUsed = dev
                break
            }
        }

        guard isHIDPPSessionActive(generation: expectedGeneration, device: device) else { return }

        if let devNumberUsed {
            hidppLock.withLock {
                hidppDeviceNumber = devNumberUsed
            }
        }

        let onboardIdx = features[Self.hidppFeatureIDOnboardProfiles]
        let spyIdx = features[Self.hidppFeatureIDMouseButtonSpy]

        let featuresSnapshot = features
        hidppLock.withLock {
            featureIndexByFeatureID = featuresSnapshot
            onboardProfilesFeatureIndex = onboardIdx
            mouseButtonSpyFeatureIndex = spyIdx
        }

        let activeDevNumberForLog = hidppLock.withLock { hidppDeviceNumber }
        if onboardIdx != nil || spyIdx != nil {
            let onboardStr = onboardIdx.map { String(format: "0x%02X", $0) } ?? "n/a"
            let spyStr = spyIdx.map { String(format: "0x%02X", $0) } ?? "n/a"
            log("HID++: features: OnboardProfiles=\(onboardStr) MouseButtonSpy=\(spyStr) dev=0x\(String(format: "%02X", activeDevNumberForLog))")
        }

        // 2) Switch OnboardProfiles to Host mode (2) so G9 becomes a button, not a profile switch.
        if let onboardIdx {
            // GetMode: function 2 -> 0x20
            if let modePayload = performHIDPPRequest(featureIndex: onboardIdx, function: 0x20, params: [], on: device),
               let mode = modePayload.first {
                if mode != 0x02 {
                    hidppLock.withLock {
                        onboardProfilesRestoreMode = mode
                    }
                    _ = performHIDPPRequest(featureIndex: onboardIdx, function: 0x10, params: [0x02], on: device)
                    guard isHIDPPSessionActive(generation: expectedGeneration, device: device) else { return }
                    log("HID++: OnboardProfiles mode \(mode) -> Host (2)")
                } else {
                    log("HID++: OnboardProfiles already Host mode")
                }
            } else {
                log("HID++: failed to read OnboardProfiles mode")
            }
        }

        // 3) Start MouseButtonSpy which reports a 16-bit pressed-bitfield (event0).
        if let spyIdx {
            let buttonCount: Int = {
                if let countPayload = performHIDPPRequest(featureIndex: spyIdx, function: 0x00, params: [], on: device),
                   let countByte = countPayload.first {
                    return Int(countByte)
                }
                return 0
            }()
            guard isHIDPPSessionActive(generation: expectedGeneration, device: device) else { return }
            hidppLock.withLock { mouseButtonSpyButtonCount = buttonCount }
            _ = performHIDPPRequest(featureIndex: spyIdx, function: 0x10, params: [], on: device)
            guard isHIDPPSessionActive(generation: expectedGeneration, device: device) else { return }
            hidppLock.withLock { mouseButtonSpyActive = true }
            log("HID++: MouseButtonSpy started (buttons=\(buttonCount))")
            return
        }

        // 4) Fallback: REPROG_CONTROLS_V4 (0x1B04) for devices that expose it.
        // G502X via Lightspeed does not expose 0x1B04, but some Logitech devices do.
        var reprogIndex: UInt8?
        var reprogDevNumber: UInt8?
        for dev in devNumbersToTry {
            if let idx = requestRootFeatureIndex(featureID: 0x1B04, deviceNumber: dev, on: device), idx != 0 {
                reprogIndex = idx
                reprogDevNumber = dev
                break
            }
        }

        guard let reprogIndex, let reprogDevNumber else {
            return
        }

        guard isHIDPPSessionActive(generation: expectedGeneration, device: device) else { return }

        hidppLock.withLock {
            hidppDeviceNumber = reprogDevNumber
            reprogControlsFeatureIndex = reprogIndex
        }
        log("HID++: REPROG_CONTROLS_V4 index=0x\(String(format: "%02X", reprogIndex)) dev=0x\(String(format: "%02X", reprogDevNumber))")

        // Get count of reprogrammable controls
        guard let countPayload = performHIDPPRequest(featureIndex: reprogIndex, function: 0x00, params: [], on: device),
              let countByte = countPayload.first else {
            log("HID++: failed to read control count")
            return
        }

        let count = Int(countByte)
        if count == 0 {
            log("HID++: control count is 0")
            return
        }

        var cids: [UInt16] = []
        cids.reserveCapacity(count)

        // Enumerate controls and collect CIDs
        for index in 0..<count {
            if let keyPayload = performHIDPPRequest(featureIndex: reprogIndex, function: 0x10, params: [UInt8(index)], on: device),
               keyPayload.count >= 2 {
                let cid = (UInt16(keyPayload[0]) << 8) | UInt16(keyPayload[1])
                if cid != 0 {
                    cids.append(cid)
                }
            }
        }

        guard isHIDPPSessionActive(generation: expectedGeneration, device: device) else { return }
        let cidsSnapshot = cids
        hidppLock.withLock { knownCIDs = cidsSnapshot }
        if !cidsSnapshot.isEmpty {
            let list = cidsSnapshot.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
            log("HID++: discovered CIDs: [\(list)]")
        }

        // Divert all controls so notifications include down/up state.
        // HID++ expects a bitfield with “valid” bits; Solaar sets:
        //  - DIVERTED => 0x01 + 0x02 = 0x03
        //  - PERSISTENTLY_DIVERTED => 0x04 + 0x08 = 0x0C
        // Some devices don’t support persistent diversion, so we apply DIVERTED first,
        // then try to upgrade to persistent.
        let divertedFlags: UInt8 = 0x03
        let persistentFlags: UInt8 = 0x0C

        for cid in cidsSnapshot {
            let hi = UInt8((cid >> 8) & 0xFF)
            let lo = UInt8(cid & 0xFF)

            let divertPkt: [UInt8] = [hi, lo, divertedFlags, 0x00, 0x00]
            sendHIDPPNoReply(featureIndex: reprogIndex, function: 0x30, params: divertPkt, on: device)

            let persistPkt: [UInt8] = [hi, lo, persistentFlags, 0x00, 0x00]
            sendHIDPPNoReply(featureIndex: reprogIndex, function: 0x30, params: persistPkt, on: device)
        }
    }

    private func enumerateHIDPPFeatures(deviceNumber: UInt8, on device: any HIDDeviceHandle) -> [UInt16: UInt8]? {
        guard let featureSetIndex = requestRootFeatureIndex(featureID: Self.hidppFeatureIDFeatureSet, deviceNumber: deviceNumber, on: device),
              featureSetIndex != 0 else {
            return nil
        }

        guard let countPayload = performHIDPPRequest(
            deviceNumber: deviceNumber,
            featureIndex: featureSetIndex,
            function: 0x00,
            params: [],
            timeout: 0.8,
            on: device
        ),
        let countByte = countPayload.first else {
            return nil
        }

        // Solaar: ROOT not included in count.
        let count = min(Int(countByte) + 1, 64)
        var mapping: [UInt16: UInt8] = [:]
        mapping[Self.hidppFeatureIDFeatureSet] = featureSetIndex

        for featureIndex in 1..<count {
            if let info = performHIDPPRequest(
                deviceNumber: deviceNumber,
                featureIndex: featureSetIndex,
                function: 0x10,
                params: [UInt8(featureIndex)],
                timeout: 0.8,
                on: device
            ),
            info.count >= 2 {
                let featureID = (UInt16(info[0]) << 8) | UInt16(info[1])
                mapping[featureID] = UInt8(featureIndex)
            }
        }

        return mapping
    }

    private func requestRootFeatureIndex(featureID: UInt16, deviceNumber: UInt8, on device: any HIDDeviceHandle) -> UInt8? {
        let params = [UInt8((featureID >> 8) & 0xFF), UInt8(featureID & 0xFF)]
        guard let payload = performHIDPPRequest(
            reportID: 0x10,
            deviceNumber: deviceNumber,
            featureIndex: 0x00,
            function: 0x00,
            params: params,
            on: device
        ) else {
            return nil
        }
        return payload.first
    }

    /// Perform a HID++ request and synchronously wait for the matching response.
    /// Returns payload bytes (starting at byte 4 of the report).
    private func performHIDPPRequest(
        reportID: UInt8? = nil,
        deviceNumber: UInt8? = nil,
        featureIndex: UInt8,
        function: UInt8,
        params: [UInt8],
        timeout: TimeInterval = 0.5,
        on device: any HIDDeviceHandle
    ) -> [UInt8]? {
        let reportIDToUse: UInt8 = reportID ?? (params.count <= 3 ? 0x10 : 0x11)

        let semaphore = DispatchSemaphore(value: 0)
        let (devNumber, requestID): (UInt8, UInt64) = hidppLock.withLock {
            let dev = deviceNumber ?? hidppDeviceNumber
            hidppRequestSequence &+= 1
            let requestID = hidppRequestSequence
            pendingHIDPPRequest = PendingHIDPPRequest(
                requestID: requestID,
                featureIndex: featureIndex,
                functionHighNibble: function & 0xF0,
                semaphore: semaphore,
                response: nil
            )
            return (dev, requestID)
        }

        sendHIDPPRequest(reportID: reportIDToUse, deviceNumber: devNumber, featureIndex: featureIndex, function: function, params: params, on: device)

        _ = semaphore.wait(timeout: .now() + timeout)

        let response: [UInt8]? = hidppLock.withLock {
            guard pendingHIDPPRequest?.requestID == requestID else { return nil }
            let resp = pendingHIDPPRequest?.response
            pendingHIDPPRequest = nil
            return resp
        }

        guard let response, response.count >= 4 else { return nil }
        let payloadStart = 4
        let payload = Array(response.dropFirst(payloadStart))
        return payload
    }

    private func sendHIDPPNoReply(featureIndex: UInt8, function: UInt8, params: [UInt8], on device: any HIDDeviceHandle) {
        let reportID: UInt8 = params.count <= 3 ? 0x10 : 0x11
        let devNumber = hidppLock.withLock { hidppDeviceNumber }
        sendHIDPPRequest(reportID: reportID, deviceNumber: devNumber, featureIndex: featureIndex, function: function, params: params, on: device)
    }

    private func sendHIDPPRequest(
        reportID: UInt8,
        deviceNumber: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        params: [UInt8],
        on device: any HIDDeviceHandle
    ) {
        let totalLength = reportID == 0x10 ? 7 : 20
        var report = [UInt8](repeating: 0, count: totalLength)
        report[0] = reportID
        report[1] = deviceNumber
        report[2] = featureIndex
        report[3] = (function & 0xF0) | Self.hidppSoftwareID
        for (i, b) in params.enumerated() where (4 + i) < totalLength {
            report[4 + i] = b
        }

        let featureResult = transport.sendReport(
            report,
            reportID: reportID,
            type: .feature,
            to: device
        )
        if case let .failure(featureError) = featureResult {
            let outputResult = transport.sendReport(
                report,
                reportID: reportID,
                type: .output,
                to: device
            )
            if case let .failure(outputError) = outputResult {
                log(
                    "HID++ write failed id=0x\(String(format: "%02X", reportID)) "
                        + "feat=0x\(String(format: "%02X", featureIndex)) "
                        + "fn=0x\(String(format: "%02X", function)) "
                        + "featureErr=\(featureError) outputErr=\(outputError)"
                )
            }
        }
    }

    func logicalButton(forCID cid: UInt16) -> G502XLogicalButton? {
        if let mapped = hidppLock.withLock({ cidToLogicalButton[cid] }) { return mapped }

        // Seed some common CIDs (from Logitech HID++ control list) on demand.
        // These IDs are stable across many mice.
        let seeded: [UInt16: G502XLogicalButton] = [
            0x0050: .left,
            0x0051: .right,
            0x0052: .middle,
            0x0053: .back,
            0x0056: .forward,
            0x005B: .scrollTiltLeft,
            0x005D: .scrollTiltRight,
        ]
        if let seed = seeded[cid] {
            hidppLock.withLock { cidToLogicalButton[cid] = seed }
            return seed
        }

        // Assign remaining unknown CIDs in a deterministic order to discoverable buttons.
        let candidates: [G502XLogicalButton] = [.g9, .dpiUp, .dpiDown, .dpiShift, .scrollTiltLeft, .scrollTiltRight]
        let next = hidppLock.withLock {
            let next = candidates.first(where: { !cidToLogicalButton.values.contains($0) })
            if let next { cidToLogicalButton[cid] = next }
            return next
        }
        if let next {
            log("HID++: mapped CID 0x\(String(format: "%04X", cid)) -> \(next.displayName)")
            return next
        }

        return nil
    }

    private func isHIDPPSessionActive(
        generation: UInt64,
        device: any HIDDeviceHandle
    ) -> Bool {
        hidppLock.withLock {
            hidppGeneration == generation
                && hidppDevice?.transportIdentifier == device.transportIdentifier
        }
    }
}
