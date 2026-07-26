import Foundation
import QuartzCore
import os.lock

private enum JoyCon {
    enum OutputType: UInt8 {
        case subcommand = 0x01
        case rumble = 0x10
    }

    enum InputMode: UInt8 {
        case standardFull = 0x30
    }
}

private enum Subcommand {
    enum CommandType: UInt8 {
        case readSPI = 0x10
        case setInputMode = 0x03
        case setPlayerLights = 0x30
        case enableIMU = 0x40
        case enableVibration = 0x48
    }
}

/// Discovered Joy-Con metadata plus an opaque transport handle.
struct DiscoveredJoyCon: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let productID: Int
    let device: any HIDDeviceHandle

    var handedness: ControllerHandedness {
        productID == JoyConHIDProtocol.leftProductID ? .left : .right
    }
    var side: String { handedness.displayName }

    var info: ControllerInfo {
        ControllerInfo(
            id: id,
            name: name,
            productID: productID,
            kind: .joyCon,
            handedness: handedness
        )
    }

    static func == (lhs: DiscoveredJoyCon, rhs: DiscoveredJoyCon) -> Bool {
        lhs.id == rhs.id
    }
}

/// Joy-Con selection, configuration, and report decoding policy. Raw IOKit
/// objects are confined to the injected transport and its dedicated HID thread.
final class JoyConHIDController: @unchecked Sendable {
    private static let deactivationRetentionSeconds: TimeInterval = 30.0
    private static let calibrationRequestMaxAttempts = 3
    private static let calibrationRetryDelay: TimeInterval = 0.25

    private enum LifecycleState {
        case stopped
        case starting(Thread)
        case running(thread: Thread, runLoop: CFRunLoop)
        case stopping(thread: Thread, runLoop: CFRunLoop)
    }

    struct InputReport: Sendable {
        let controllerID: String
        let bytes: [UInt8]
        let length: Int
        let gyroX: Int16
        let gyroY: Int16
        let gyroZ: Int16
        let accelX: Int16
        let accelY: Int16
        let accelZ: Int16
        let timestamp: TimeInterval
        let receivedTimestamp: TimeInterval
        let inputTimestamp: TimeInterval?
        let timestampSource: InputTimestampSource
        let motionSamples: [IMUSample]
        let analogStickCalibration: InputDeviceAnalogStickCalibration

        var averagedGyro: (x: Int16, y: Int16, z: Int16) {
            JoyConDecodedInputReport(motionSamples: motionSamples).averagedGyro
        }
    }

    // Callback contract: every callback runs on "JamCon.JoyConHID".
    var onReportData: ((_ report: InputReport) -> Void)?
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?
    var onControllersChanged: (() -> Void)?
    var onDebugMessage: ((_ message: String) -> Void)?

    private let lifecycleCondition = NSCondition()
    private var lifecycleState: LifecycleState = .stopped
    private let transport: any JoyConHIDTransport

    private struct RetiredController: Sendable {
        let controller: ActiveController
        let retiredAt: TimeInterval
    }

    /// Mutable members are confined to the Joy-Con HID thread. The object is
    /// retained in locked state so UI snapshots can observe connection status.
    private final class ActiveController: @unchecked Sendable {
        let controller: DiscoveredJoyCon
        let registration: any HIDInputRegistration
        var outputPacketCounter: UInt8 = 0
        var packetTimingTracker = JoyConPacketTimingTracker()
        var transportAggregator = JoyConTransportAggregator()
        var stickCalibration = JoyConHIDProtocol.conservativeStickCalibration
        var calibrationRequestAttempts = 0
        var calibrationRetryWorkItem: DispatchWorkItem?
        var hapticStopWorkItem: DispatchWorkItem?
        var lastHapticTimestamp: TimeInterval = 0
        var hasLoadedFactoryCalibration = false

        init(controller: DiscoveredJoyCon, registration: any HIDInputRegistration) {
            self.controller = controller
            self.registration = registration
        }
    }

    private struct ControllerState: Sendable {
        var discoveredControllers: [DiscoveredJoyCon] = []
        var managedControllerIDs: Set<String> = []
        var activeControllers: [String: ActiveController] = [:]
        var retiredControllers: [RetiredController] = []
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: ControllerState())

    func controllerInfosSnapshot() -> [ControllerInfo] {
        stateLock.withLock { $0.discoveredControllers.map(\.info) }
    }

    var isConnected: Bool {
        stateLock.withLock { !$0.activeControllers.isEmpty }
    }

    var controllerName: String? {
        stateLock.withLock { state in
            guard state.activeControllers.count == 1,
                  let active = state.activeControllers.values.first else {
                return nil
            }
            return active.controller.name
        }
    }

    init(transport: any JoyConHIDTransport = IOKitJoyConHIDTransport()) {
        self.transport = transport
    }

    deinit {
        stop()
    }

    private func performHIDOperation(_ work: @escaping () -> Void) {
        lifecycleCondition.lock()
        let target: (thread: Thread, runLoop: CFRunLoop)?
        if case let .running(thread, runLoop) = lifecycleState {
            target = (thread, runLoop)
        } else {
            target = nil
        }
        lifecycleCondition.unlock()

        guard let target else {
            // Managed selection is retained and reconciled once discovery runs.
            return
        }
        if Thread.current === target.thread {
            work()
            return
        }
        CFRunLoopPerformBlock(target.runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(target.runLoop)
    }

    private func assertOnHIDThread(file: StaticString = #fileID, line: UInt = #line) {
        lifecycleCondition.lock()
        let thread: Thread?
        switch lifecycleState {
        case let .starting(candidate), let .running(candidate, _), let .stopping(candidate, _):
            thread = candidate
        case .stopped:
            thread = nil
        }
        lifecycleCondition.unlock()
        assert(
            Thread.current === thread,
            "JoyConHIDController operation must run on the HID thread",
            file: file,
            line: line
        )
    }

    @discardableResult
    func start() -> Bool {
        lifecycleCondition.lock()
        while true {
            switch lifecycleState {
            case .running:
                lifecycleCondition.unlock()
                return true
            case .starting, .stopping:
                lifecycleCondition.wait()
            case .stopped:
                let thread = Thread { [weak self] in
                    self?.runHIDThread()
                }
                thread.name = "JamCon.JoyConHID"
                thread.qualityOfService = .userInteractive
                lifecycleState = .starting(thread)
                lifecycleCondition.unlock()
                thread.start()

                lifecycleCondition.lock()
                while case .starting = lifecycleState {
                    lifecycleCondition.wait()
                }
                let started: Bool
                if case .running = lifecycleState {
                    started = true
                } else {
                    started = false
                }
                lifecycleCondition.unlock()
                return started
            }
        }
    }

    func stop() {
        lifecycleCondition.lock()
        while case .starting = lifecycleState {
            lifecycleCondition.wait()
        }

        switch lifecycleState {
        case .stopped:
            lifecycleCondition.unlock()
        case .stopping:
            while case .stopping = lifecycleState {
                lifecycleCondition.wait()
            }
            lifecycleCondition.unlock()
        case let .running(thread, runLoop):
            lifecycleState = .stopping(thread: thread, runLoop: runLoop)
            thread.cancel()
            lifecycleCondition.unlock()

            if Thread.current === thread {
                CFRunLoopStop(runLoop)
                return
            }

            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)

            lifecycleCondition.lock()
            while case .stopping = lifecycleState {
                lifecycleCondition.wait()
            }
            lifecycleCondition.unlock()
        case .starting:
            lifecycleCondition.unlock()
        }
    }

    private func runHIDThread() {
        let currentThread = Thread.current
        guard let runLoop = CFRunLoopGetCurrent() else {
            lifecycleCondition.lock()
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
            JamLog.error(.joyCon, "Failed to obtain Joy-Con HID thread run loop")
            return
        }

        lifecycleCondition.lock()
        guard case let .starting(thread) = lifecycleState, thread === currentThread else {
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
            return
        }
        lifecycleCondition.unlock()

        let startupResult = configureHIDManager(on: runLoop)
        guard case .success = startupResult else {
            cleanupHIDResources(on: runLoop)
            lifecycleCondition.lock()
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
            if case let .failure(error) = startupResult {
                JamLog.error(.joyCon, "Joy-Con HID backend did not start: \(error)")
            }
            return
        }

        lifecycleCondition.lock()
        lifecycleState = .running(thread: currentThread, runLoop: runLoop)
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()

        activateManagedControllersIfNeeded()
        while !Thread.current.isCancelled {
            _ = autoreleasepool {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }

        cleanupHIDResources(on: runLoop)
        lifecycleCondition.lock()
        lifecycleState = .stopped
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()
    }

    private func configureHIDManager(on runLoop: CFRunLoop) -> Result<Void, HIDTransportError> {
        let result = transport.startDiscovery(
            on: runLoop,
            deviceConnected: { [weak self] device in
                self?.handleDeviceConnected(device)
            },
            deviceDisconnected: { [weak self] device in
                self?.handleDeviceDisconnected(device)
            }
        )
        if case .success = result {
            log("Joy-Con HID manager started (matching Joy-Con L/R)")
        }
        return result
    }

    private func cleanupHIDResources(on runLoop: CFRunLoop) {
        assertOnHIDThread()

        let activeControllers = stateLock.withLock { state in
            let active = Array(state.activeControllers.values)
            state.activeControllers.removeAll(keepingCapacity: true)
            return active
        }
        let now = CACurrentMediaTime()
        for active in activeControllers {
            flushTransportSummary(for: active, at: now)
            close(active)
        }
        transport.stopDiscovery(on: runLoop)

        stateLock.withLock { state in
            state.discoveredControllers.removeAll(keepingCapacity: true)
            state.retiredControllers.removeAll(keepingCapacity: true)
        }
    }

    private func activateManagedControllersIfNeeded() {
        assertOnHIDThread()
        let controllers = stateLock.withLock { state in
            state.discoveredControllers.filter {
                state.managedControllerIDs.contains($0.id) && state.activeControllers[$0.id] == nil
            }
        }
        for controller in controllers {
            activateController(controller)
        }
    }

    private func handleDeviceConnected(_ device: any HIDDeviceHandle) {
        assertOnHIDThread()
        guard let properties = transport.properties(for: device) else {
            JamLog.error(.joyCon, "Ignoring Joy-Con with unreadable HID properties")
            return
        }

        let vendorID = properties.vendorID
        let productID = properties.productID
        let name = properties.name
        log(
            "HID device: vendor=0x\(String(format: "%04X", vendorID)) "
                + "pid=0x\(String(format: "%04X", productID)) name=\(name)"
        )
        guard vendorID == JoyConHIDProtocol.nintendoVendorID,
              productID == JoyConHIDProtocol.leftProductID
                || productID == JoyConHIDProtocol.rightProductID else {
            return
        }

        let uniqueID = HIDDeviceIdentity.identifier(for: properties)
        let alreadyDiscovered = stateLock.withLock { state in
            state.discoveredControllers.contains(where: { $0.id == uniqueID })
        }
        guard !alreadyDiscovered else { return }

        let controller = DiscoveredJoyCon(
            id: uniqueID,
            name: name,
            productID: productID,
            device: device
        )
        stateLock.withLock { state in
            state.discoveredControllers.append(controller)
        }
        onControllersChanged?()
        log("Joy-Con discovered: \(name) (PID: 0x\(String(format: "%04X", productID)))")

        let shouldAutoActivate = stateLock.withLock { state in
            state.managedControllerIDs.contains(uniqueID)
        }
        if shouldAutoActivate {
            activateController(controller)
        }
    }

    private func handleDeviceDisconnected(_ device: any HIDDeviceHandle) {
        assertOnHIDThread()
        let disconnected: DiscoveredJoyCon? = stateLock.withLock { state in
            guard let index = state.discoveredControllers.firstIndex(where: {
                $0.device.transportIdentifier == device.transportIdentifier
            }) else {
                return nil
            }
            return state.discoveredControllers.remove(at: index)
        }

        if let controller = disconnected {
            log("Joy-Con disconnected: \(controller.name)")
            deactivateController(id: controller.id)
            onControllersChanged?()
        }
    }

    func setControllerManaged(id: String, managed: Bool) {
        if managed {
            let controller: DiscoveredJoyCon? = stateLock.withLock { state in
                state.managedControllerIDs.insert(id)
                return state.discoveredControllers.first(where: { $0.id == id })
            }
            guard let controller else { return }
            performHIDOperation { [weak self] in
                self?.activateController(controller)
            }
        } else {
            stateLock.withLock { state in
                _ = state.managedControllerIDs.remove(id)
            }
            performHIDOperation { [weak self] in
                self?.deactivateController(id: id)
            }
        }
    }

    @discardableResult
    func playHaptic(deviceID: String, effect: InputDeviceHapticEffect) -> Bool {
        let isActive = stateLock.withLock { $0.activeControllers[deviceID] != nil }
        guard isActive else { return false }
        performHIDOperation { [weak self] in
            self?.playHapticOnHIDThread(deviceID: deviceID, effect: effect)
        }
        return true
    }

    private func activateController(_ controller: DiscoveredJoyCon) {
        assertOnHIDThread()
        let controllerID = controller.id
        let currentController: DiscoveredJoyCon? = stateLock.withLock { state in
            guard state.managedControllerIDs.contains(controllerID),
                  state.activeControllers[controllerID] == nil,
                  let discovered = state.discoveredControllers.first(where: { $0.id == controllerID }),
                  discovered.device.transportIdentifier == controller.device.transportIdentifier else {
                return nil
            }
            return discovered
        }
        guard let currentController,
              let runLoop = CFRunLoopGetCurrent() else {
            return
        }

        let registrationResult = transport.openInput(
            for: currentController.device,
            on: runLoop,
            reportLength: 64,
            handler: { [weak self] reportID, report, length in
                self?.handleInputReport(
                    controllerID: controllerID,
                    report: report,
                    length: length,
                    reportID: reportID
                )
            }
        )
        guard case let .success(registration) = registrationResult else {
            if case let .failure(error) = registrationResult {
                JamLog.error(.joyCon, "Failed to seize managed Joy-Con: \(error)")
            }
            return
        }

        let active = ActiveController(controller: currentController, registration: registration)
        let activated = stateLock.withLock { state in
            guard state.managedControllerIDs.contains(controllerID),
                  state.activeControllers[controllerID] == nil,
                  let discovered = state.discoveredControllers.first(where: { $0.id == controllerID }),
                  discovered.device.transportIdentifier == currentController.device.transportIdentifier else {
                return false
            }
            state.activeControllers[controllerID] = active
            return true
        }
        guard activated else {
            if case let .failure(error) = transport.closeInput(registration) {
                JamLog.error(.joyCon, "Failed to close stale managed Joy-Con: \(error)")
            }
            return
        }

        sendSubcommand(.enableIMU, data: [0x01], to: active)
        sendSubcommand(.setInputMode, data: [JoyCon.InputMode.standardFull.rawValue], to: active)
        sendSubcommand(.enableVibration, data: [0x01], to: active)
        sendSubcommand(.setPlayerLights, data: [0x01], to: active)
        requestFactoryStickCalibration(for: active)

        let displayName = "\(currentController.name) (\(currentController.side))"
        onConnectionChange?(true, displayName, currentController.id)
        log("Joy-Con activated: \(displayName)")
    }

    private func deactivateController(id: String) {
        assertOnHIDThread()
        let now = CACurrentMediaTime()
        let active: ActiveController? = stateLock.withLock { state in
            guard let active = state.activeControllers.removeValue(forKey: id) else { return nil }
            state.retiredControllers.append(RetiredController(controller: active, retiredAt: now))
            state.retiredControllers.removeAll {
                now - $0.retiredAt > Self.deactivationRetentionSeconds
            }
            return active
        }
        guard let active else { return }

        flushTransportSummary(for: active, at: now)
        close(active)
        let displayName = "\(active.controller.name) (\(active.controller.side))"
        onConnectionChange?(false, displayName, active.controller.id)
    }

    private func close(_ active: ActiveController) {
        assertOnHIDThread()
        active.calibrationRetryWorkItem?.cancel()
        active.calibrationRetryWorkItem = nil
        active.hapticStopWorkItem?.cancel()
        active.hapticStopWorkItem = nil
        if case let .failure(error) = transport.closeInput(active.registration) {
            JamLog.errorThrottled(
                .joyCon,
                key: "device.close.\(active.controller.id)",
                interval: 2,
                "Failed to close Joy-Con: \(error)"
            )
        }
    }

    private func flushTransportSummary(for active: ActiveController, at timestamp: TimeInterval) {
        if let summary = active.transportAggregator.flush(at: timestamp) {
            JamLog.info(
                .health,
                "device=joyCon:\(active.controller.id) transport \(summary.logMessage)"
            )
        }
    }

    #if DEBUG
    private var didLogInputReportSample = false
    #endif

    private func handleInputReport(
        controllerID: String,
        report: UnsafeMutablePointer<UInt8>,
        length: Int,
        reportID: UInt32
    ) {
        if reportID == JoyConHIDProtocol.subcommandReplyReportID {
            let bytes = Array(UnsafeBufferPointer(start: report, count: min(length, 64)))
            handleSubcommandReply(controllerID: controllerID, bytes: bytes)
            return
        }
        guard reportID == JoyConHIDProtocol.inputReportID else { return }
        let receivedTimestamp = CACurrentMediaTime()
        let maxLength = min(length, JoyConHIDProtocol.reportLength)
        let bytes = Array(UnsafeBufferPointer(start: report, count: maxLength))

        let timerByte = bytes.indices.contains(JoyConHIDProtocol.Offset.timer)
            ? bytes[JoyConHIDProtocol.Offset.timer]
            : nil
        let timingResult: (
            JoyConPacketTimingObservation,
            JoyConTransportSummary?,
            InputDeviceAnalogStickCalibration
        )? = stateLock.withLock { state in
            guard let active = state.activeControllers[controllerID] else { return nil }
            let observation = active.packetTimingTracker.observe(
                timerByte: timerByte,
                bytes: bytes,
                receivedTimestamp: receivedTimestamp
            )
            let summary = active.transportAggregator.record(observation, at: receivedTimestamp)
            return (observation, summary, active.stickCalibration)
        }
        guard let (timing, transportSummary, stickCalibration) = timingResult else { return }
        if let transportSummary {
            JamLog.info(
                .health,
                "device=joyCon:\(controllerID) transport \(transportSummary.logMessage)"
            )
        }
        guard timing.accepted else { return }

        #if DEBUG
        if !didLogInputReportSample {
            didLogInputReportSample = true
            let hexBytes = bytes.prefix(50).map { String(format: "%02X", $0) }.joined(separator: " ")
            JamLog.debug(
                .joyCon,
                "Input report sample len=\(length) id=0x\(String(format: "%02X", reportID)): \(hexBytes)"
            )
        }
        #endif

        guard let decoded = try? JoyConInputReportDecoder.decode(bytes) else {
            JamLog.errorThrottled(
                .joyCon,
                key: "malformed.input",
                interval: 2,
                "Discarded malformed Joy-Con input report (length=\(maxLength))"
            )
            return
        }
        let motion = decoded.latest
        onReportData?(InputReport(
            controllerID: controllerID,
            bytes: bytes,
            length: maxLength,
            gyroX: motion.gyroX,
            gyroY: motion.gyroY,
            gyroZ: motion.gyroZ,
            accelX: motion.accelX,
            accelY: motion.accelY,
            accelZ: motion.accelZ,
            timestamp: timing.processingTimestamp,
            receivedTimestamp: receivedTimestamp,
            inputTimestamp: nil,
            timestampSource: timing.timestampSource,
            motionSamples: decoded.motionSamples,
            analogStickCalibration: stickCalibration
        ))
    }

    private func handleSubcommandReply(controllerID: String, bytes: [UInt8]) {
        assertOnHIDThread()
        let loaded: InputDeviceAnalogStickCalibration? = stateLock.withLock { state in
            guard let active = state.activeControllers[controllerID],
                  let calibration = JoyConHIDProtocol.decodeFactoryStickCalibrationReply(
                      bytes,
                      isLeft: active.controller.handedness == .left
                  ) else {
                return nil
            }
            active.stickCalibration = calibration
            active.hasLoadedFactoryCalibration = true
            active.calibrationRetryWorkItem?.cancel()
            active.calibrationRetryWorkItem = nil
            return calibration
        }
        guard let loaded else { return }
        JamLog.info(
            .joyCon,
            "Original Joy-Con factory stick calibration loaded "
                + "(center=\(loaded.centerX),\(loaded.centerY))"
        )
    }

    private func requestFactoryStickCalibration(for active: ActiveController) {
        assertOnHIDThread()
        guard !active.hasLoadedFactoryCalibration,
              active.calibrationRequestAttempts < Self.calibrationRequestMaxAttempts else {
            return
        }

        active.calibrationRequestAttempts += 1
        sendSubcommand(
            .readSPI,
            data: JoyConHIDProtocol.factoryStickCalibrationReadPayload(
                isLeft: active.controller.handedness == .left
            ),
            to: active
        )

        active.calibrationRetryWorkItem?.cancel()
        let controllerID = active.controller.id
        let retry = DispatchWorkItem { [weak self, weak active] in
            guard let self, let active else { return }
            self.performHIDOperation { [weak self, weak active] in
                guard let self, let active else { return }
                let isCurrent = self.stateLock.withLock {
                    $0.activeControllers[controllerID] === active
                }
                guard isCurrent, !active.hasLoadedFactoryCalibration else { return }

                if active.calibrationRequestAttempts < Self.calibrationRequestMaxAttempts {
                    self.requestFactoryStickCalibration(for: active)
                } else {
                    active.calibrationRetryWorkItem = nil
                    JamLog.error(
                        .joyCon,
                        "Original Joy-Con factory stick calibration did not answer after "
                            + "\(Self.calibrationRequestMaxAttempts) attempts; "
                            + "using conservative fallback"
                    )
                }
            }
        }
        active.calibrationRetryWorkItem = retry
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + Self.calibrationRetryDelay,
            execute: retry
        )
    }

    private func playHapticOnHIDThread(
        deviceID: String,
        effect: InputDeviceHapticEffect
    ) {
        assertOnHIDThread()
        guard let active = stateLock.withLock({ $0.activeControllers[deviceID] }) else {
            return
        }

        let now = CACurrentMediaTime()
        guard now - active.lastHapticTimestamp >= 0.03 else { return }
        active.lastHapticTimestamp = now
        active.hapticStopWorkItem?.cancel()
        let pulse: [UInt8]
        switch effect {
        case .selection:
            // 320 Hz / 160 Hz, about 3% amplitude. Both slots are populated
            // because an individual Joy-Con may be used on either side.
            pulse = [0x00, 0x15, 0x40, 0x44]
        }
        sendRumble(pulse, to: active)

        let stop = DispatchWorkItem { [weak self, weak active] in
            guard let self, let active else { return }
            self.performHIDOperation { [weak self, weak active] in
                guard let self, let active else { return }
                let isCurrent = self.stateLock.withLock {
                    $0.activeControllers[deviceID] === active
                }
                guard isCurrent else { return }
                active.hapticStopWorkItem = nil
                self.sendRumble([0x00, 0x01, 0x40, 0x40], to: active)
            }
        }
        active.hapticStopWorkItem = stop
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + 0.032,
            execute: stop
        )
    }

    private func sendRumble(_ actuator: [UInt8], to active: ActiveController) {
        precondition(actuator.count == 4)
        var report = [UInt8](repeating: 0, count: 10)
        report[0] = JoyCon.OutputType.rumble.rawValue
        report[1] = active.outputPacketCounter
        active.outputPacketCounter = (active.outputPacketCounter &+ 1) & 0x0F
        report.replaceSubrange(2...5, with: actuator)
        report.replaceSubrange(6...9, with: actuator)

        if case let .failure(error) = transport.sendOutputReport(
            report,
            reportID: JoyCon.OutputType.rumble.rawValue,
            using: active.registration
        ) {
            JamLog.errorThrottled(
                .joyCon,
                key: "haptic.\(active.controller.id)",
                interval: 2,
                "Joy-Con haptic output failed: \(error)"
            )
        }
    }

    private func sendSubcommand(
        _ command: Subcommand.CommandType,
        data: [UInt8],
        to active: ActiveController
    ) {
        var report = [UInt8](repeating: 0, count: 11 + data.count)
        report[0] = JoyCon.OutputType.subcommand.rawValue
        report[1] = active.outputPacketCounter
        active.outputPacketCounter = (active.outputPacketCounter &+ 1) & 0x0F

        let silentRumble: [UInt8] = [0x00, 0x01, 0x00, 0x40, 0x00, 0x01, 0x00, 0x40]
        for index in silentRumble.indices {
            report[2 + index] = silentRumble[index]
        }
        report[10] = command.rawValue
        for (index, byte) in data.enumerated() {
            report[11 + index] = byte
        }

        if case let .failure(error) = transport.sendOutputReport(
            report,
            reportID: JoyCon.OutputType.subcommand.rawValue,
            using: active.registration
        ) {
            JamLog.errorThrottled(
                .joyCon,
                key: "subcommand.\(command.rawValue)",
                interval: 2,
                "Joy-Con subcommand \(command) failed: \(error)"
            )
        }
    }

    private func log(_ message: String) {
        JamLog.info(.joyCon, message)
    }
}
