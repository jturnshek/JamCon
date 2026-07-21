import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import os.lock

private enum JoyCon {
    enum OutputType: UInt8 {
        case subcommand = 0x01
    }

    enum InputMode: UInt8 {
        case standardFull = 0x30
    }
}

private enum Subcommand {
    enum CommandType: UInt8 {
        case setInputMode = 0x03
        case setPlayerLights = 0x30
        case enableIMU = 0x40
        case enableVibration = 0x48
    }
}

/// Represents a discovered Joy-Con (internal - holds IOHIDDevice)
struct DiscoveredJoyCon: Identifiable, Equatable {
    let id: String
    let name: String
    let productID: Int
    let device: IOHIDDevice

    var side: String { productID == JoyConHIDProtocol.leftProductID ? "Left" : "Right" }

    var info: ControllerInfo {
        ControllerInfo(id: id, name: name, productID: productID, kind: .joyCon)
    }

    static func == (lhs: DiscoveredJoyCon, rhs: DiscoveredJoyCon) -> Bool {
        lhs.id == rhs.id
    }
}

/// Minimal Joy-Con HID driver (Bluetooth) that mirrors the Sense controller flow:
/// - Scans for Joy-Con L/R
/// - Seizes the device
/// - Enables IMU + sets input mode 0x30
/// - Streams raw input reports and decodes the newest IMU sample for convenience
final class JoyConHIDController {
    // MARK: - Types

    private static let deactivationRetentionSeconds: TimeInterval = 30.0

    struct InputReport {
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

        var averagedGyro: (x: Int16, y: Int16, z: Int16) {
            JoyConDecodedInputReport(motionSamples: motionSamples).averagedGyro
        }
    }

    // MARK: - Callbacks
    //
    // Callback contract:
    // All callbacks are invoked on the controller's HID thread/run loop ("JamCon.JoyConHID").

    var onReportData: ((_ report: InputReport) -> Void)?
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?
    var onControllersChanged: (() -> Void)?
    var onDebugMessage: ((_ message: String) -> Void)?

    // MARK: - State

    private var hidManager: IOHIDManager?
    private var hidRunLoop: CFRunLoop?
    private var hidThread: Thread?
    private let hidRunLoopReady = DispatchSemaphore(value: 0)

    // MARK: - Thread-safe state (read from UI / other threads)

    private final class CallbackContext {
        weak var owner: JoyConHIDController?
        let controllerID: String

        init(owner: JoyConHIDController, controllerID: String) {
            self.owner = owner
            self.controllerID = controllerID
        }
    }

    private struct RetiredController {
        let controller: ActiveController
        let retiredAt: TimeInterval
    }

    private final class ActiveController {
        let controller: DiscoveredJoyCon
        let callbackContext: CallbackContext
        let reportBuffer: UnsafeMutablePointer<UInt8>
        let reportBufferLength: Int

        var outputPacketCounter: UInt8 = 0
        var packetTimingTracker = JoyConPacketTimingTracker()
        var transportAggregator = JoyConTransportAggregator()

        init(controller: DiscoveredJoyCon, owner: JoyConHIDController) {
            self.controller = controller
            self.callbackContext = CallbackContext(owner: owner, controllerID: controller.id)
            self.reportBufferLength = 64
            self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferLength)
            self.reportBuffer.initialize(repeating: 0, count: reportBufferLength)
        }

        deinit {
            reportBuffer.deinitialize(count: reportBufferLength)
            reportBuffer.deallocate()
        }
    }

    private struct ControllerState {
        var discoveredControllers: [DiscoveredJoyCon] = []
        var managedControllerIDs: Set<String> = []
        var activeControllers: [String: ActiveController] = [:]
        var retiredControllers: [RetiredController] = []
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: ControllerState())

    /// UI-safe snapshot of all discovered Joy-Con controllers.
    func controllerInfosSnapshot() -> [ControllerInfo] {
        stateLock.withLock { $0.discoveredControllers.map(\.info) }
    }

    /// Get the product ID for a discovered controller ID (thread-safe).
    func productID(forControllerID id: String?) -> Int? {
        guard let id else { return nil }
        return stateLock.withLock { state in
            state.discoveredControllers.first(where: { $0.id == id })?.productID
        }
    }

    /// Whether any managed Joy-Con is currently connected and active (thread-safe).
    var isConnected: Bool {
        stateLock.withLock { !$0.activeControllers.isEmpty }
    }

    /// Name of the connected Joy-Con if exactly one is active; otherwise nil. (thread-safe)
    var controllerName: String? {
        stateLock.withLock { state in
            guard state.activeControllers.count == 1, let active = state.activeControllers.values.first else { return nil }
            return active.controller.name
        }
    }
    // MARK: - Init / lifecycle

    init() {}

    deinit { stop() }

    private func dispatchToHIDThread(_ work: @escaping () -> Void) {
        if Thread.current == hidThread {
            work()
            return
        }

        guard let runLoop = hidRunLoop else {
            work()
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    private func performHIDOperation(_ work: @escaping () -> Void) {
        if Thread.current == hidThread {
            work()
            return
        }

        guard let runLoop = hidRunLoop else {
            // If the HID thread isn't running yet, don't perform IOKit operations on an arbitrary thread.
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    func start() {
        startHIDThreadIfNeeded()
    }

    func stop() {
        // Signal the HID thread to exit its run loop
        hidThread?.cancel()

        guard let runLoop = hidRunLoop else {
            // Fallback cleanup if the HID thread was never started
            let activeControllersSnapshot: [ActiveController] = stateLock.withLock { state in
                Array(state.activeControllers.values) + state.retiredControllers.map(\.controller)
            }
            for active in activeControllersSnapshot {
                IOHIDDeviceRegisterInputReportCallback(active.controller.device, active.reportBuffer, active.reportBufferLength, nil, nil)
                IOHIDDeviceClose(active.controller.device, IOOptionBits(kIOHIDOptionsTypeNone))
            }

            if let manager = hidManager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                hidManager = nil
            }

            stateLock.withLock { state in
                state.discoveredControllers.removeAll(keepingCapacity: true)
                state.managedControllerIDs.removeAll(keepingCapacity: true)
                state.activeControllers.removeAll(keepingCapacity: true)
                state.retiredControllers.removeAll(keepingCapacity: true)
            }
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }

            let activeControllersSnapshot: [ActiveController] = self.stateLock.withLock { state in
                Array(state.activeControllers.values) + state.retiredControllers.map(\.controller)
            }
            for active in activeControllersSnapshot {
                IOHIDDeviceRegisterInputReportCallback(active.controller.device, active.reportBuffer, active.reportBufferLength, nil, nil)
                IOHIDDeviceClose(active.controller.device, IOOptionBits(kIOHIDOptionsTypeNone))
            }

            if let manager = self.hidManager {
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                self.hidManager = nil
            }

            self.stateLock.withLock { state in
                state.discoveredControllers.removeAll(keepingCapacity: true)
                state.managedControllerIDs.removeAll(keepingCapacity: true)
                state.activeControllers.removeAll(keepingCapacity: true)
                state.retiredControllers.removeAll(keepingCapacity: true)
            }

            CFRunLoopStop(runLoop)
        }

        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - HID thread

    private func startHIDThreadIfNeeded() {
        guard hidThread == nil else { return }

        let thread = Thread { [weak self] in
            self?.runHIDThread()
        }
        thread.name = "JamCon.JoyConHID"
        thread.qualityOfService = .userInteractive
        hidThread = thread
        thread.start()

        hidRunLoopReady.wait()
    }

    private func runHIDThread() {
        hidRunLoop = CFRunLoopGetCurrent()
        hidRunLoopReady.signal()

        configureHIDManager(on: hidRunLoop ?? CFRunLoopGetCurrent())

        // Run loop with periodic autorelease pool drain to prevent memory accumulation
        // from autoreleased objects created in HID callbacks
        while !Thread.current.isCancelled {
            _ = autoreleasepool {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }

        hidRunLoop = nil
        hidThread = nil
    }

    private func configureHIDManager(on runLoop: CFRunLoop) {
        guard hidManager == nil else { return }

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            log("Failed to create Joy-Con HID manager")
            return
        }

        // Match Joy-Con L/R
        // Usage can be joystick or gamepad depending on firmware/stack, so include both.
        let usages: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad]
        ]
        var matchDictionaries: [[String: Any]] = []
        for usage in usages {
            matchDictionaries.append(usage.merging([
                kIOHIDVendorIDKey as String: JoyConHIDProtocol.nintendoVendorID,
                kIOHIDProductIDKey as String: JoyConHIDProtocol.leftProductID
            ], uniquingKeysWith: { _, new in new }))
            matchDictionaries.append(usage.merging([
                kIOHIDVendorIDKey as String: JoyConHIDProtocol.nintendoVendorID,
                kIOHIDProductIDKey as String: JoyConHIDProtocol.rightProductID
            ], uniquingKeysWith: { _, new in new }))
        }
        // Include a loose fallback (vendor + PID only) in case usage filtering fails.
        matchDictionaries.append([
            kIOHIDVendorIDKey as String: JoyConHIDProtocol.nintendoVendorID,
            kIOHIDProductIDKey as String: JoyConHIDProtocol.leftProductID
        ])
        matchDictionaries.append([
            kIOHIDVendorIDKey as String: JoyConHIDProtocol.nintendoVendorID,
            kIOHIDProductIDKey as String: JoyConHIDProtocol.rightProductID
        ])
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchDictionaries as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let controller = Unmanaged<JoyConHIDController>.fromOpaque(context).takeUnretainedValue()
            controller.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let controller = Unmanaged<JoyConHIDController>.fromOpaque(context).takeUnretainedValue()
            controller.handleDeviceDisconnected(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log("Failed to open Joy-Con HID manager: \(result)")
        } else {
            log("Joy-Con HID manager started (matching Joy-Con L/R)")
        }
    }

    // MARK: - Device handling

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Joy-Con"

        log("HID device: vendor=0x\(String(format: "%04X", vendorID)) pid=0x\(String(format: "%04X", productID)) name=\(name)")
        guard vendorID == JoyConHIDProtocol.nintendoVendorID,
              (productID == JoyConHIDProtocol.leftProductID || productID == JoyConHIDProtocol.rightProductID) else {
            return
        }

        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        let uniqueID = serial ?? "loc-\(location)-pid-\(productID)"

        let alreadyDiscovered = stateLock.withLock { state in
            state.discoveredControllers.contains(where: { $0.id == uniqueID })
        }
        if alreadyDiscovered { return }

        let controller = DiscoveredJoyCon(id: uniqueID, name: name, productID: productID, device: device)
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

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        let disconnected: DiscoveredJoyCon? = stateLock.withLock { state in
            guard let index = state.discoveredControllers.firstIndex(where: { $0.device == device }) else { return nil }
            let controller = state.discoveredControllers[index]
            state.discoveredControllers.remove(at: index)
            return controller
        }
        if let controller = disconnected {
            log("Joy-Con disconnected: \(controller.name)")
            deactivateController(id: controller.id)
            onControllersChanged?()
        }
    }

    /// Enable/disable processing for a specific Joy-Con controller ID.
    func setControllerManaged(id: String, managed: Bool) {
        if managed {
            let controller: DiscoveredJoyCon? = stateLock.withLock { state in
                state.managedControllerIDs.insert(id)
                return state.discoveredControllers.first(where: { $0.id == id })
            }
            guard let controller else {
                // Not discovered yet; it'll auto-activate when it appears.
                return
            }
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

    private func activateController(_ controller: DiscoveredJoyCon) {
        assert(Thread.current == hidThread, "JoyConHIDController.activateController must run on the HID thread")

        let controllerID = controller.id
        let needsActivation: Bool = stateLock.withLock { state in
            state.activeControllers[controllerID] == nil
        }
        guard needsActivation else { return }

        let device = controller.device
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess && result != -536870201 { // already open OK
            log("Failed to open Joy-Con: \(result)")
            return
        }

        let active = ActiveController(controller: controller, owner: self)
        stateLock.withLock { state in
            state.activeControllers[controllerID] = active
        }

        // Register input report callback
        let context = Unmanaged.passUnretained(active.callbackContext).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            active.reportBuffer,
            active.reportBufferLength,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                callbackContext.owner?.handleInputReport(
                    controllerID: callbackContext.controllerID,
                    report: report,
                    length: length,
                    reportID: reportID
                )
            },
            context
        )

        // Enable IMU + set input mode
        sendSubcommand(.enableIMU, data: [0x01], to: active)
        sendSubcommand(.setInputMode, data: [UInt8(JoyCon.InputMode.standardFull.rawValue)], to: active)
        sendSubcommand(.enableVibration, data: [0x01], to: active) // keep LEDs happy
        sendSubcommand(.setPlayerLights, data: [0x01], to: active)

        let displayName = "\(controller.name) (\(controller.side))"
        onConnectionChange?(true, displayName, controller.id)
        log("Joy-Con activated: \(displayName)")
    }

    private func deactivateController(id: String) {
        assert(Thread.current == hidThread, "JoyConHIDController.deactivateController must run on the HID thread")

        let now = CACurrentMediaTime()
        let active: ActiveController? = stateLock.withLock { state in
            guard let active = state.activeControllers.removeValue(forKey: id) else { return nil }
            state.retiredControllers.append(RetiredController(controller: active, retiredAt: now))
            state.retiredControllers.removeAll(where: { now - $0.retiredAt > Self.deactivationRetentionSeconds })
            return active
        }
        guard let active else { return }

        IOHIDDeviceRegisterInputReportCallback(active.controller.device, active.reportBuffer, active.reportBufferLength, nil, nil)
        IOHIDDeviceClose(active.controller.device, IOOptionBits(kIOHIDOptionsTypeNone))

        if let summary = active.transportAggregator.flush(at: now) {
            JamLog.info(.health, "device=joyCon:\(id) transport \(summary.logMessage)")
        }

        let displayName = "\(active.controller.name) (\(active.controller.side))"
        onConnectionChange?(false, displayName, active.controller.id)
    }

    // MARK: - Input reports

    #if DEBUG
    private var didLogInputReportSample = false
    #endif

    private func handleInputReport(controllerID: String, report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        guard reportID == JoyConHIDProtocol.inputReportID else { return }
        let receivedTimestamp = CACurrentMediaTime()

        let maxLength = min(length, JoyConHIDProtocol.reportLength)
        let bytes = Array(UnsafeBufferPointer(start: report, count: maxLength))

        let timerByte = bytes.indices.contains(JoyConHIDProtocol.Offset.timer)
            ? bytes[JoyConHIDProtocol.Offset.timer]
            : nil
        let timingResult: (JoyConPacketTimingObservation, JoyConTransportSummary?)? = stateLock.withLock { state in
            guard let active = state.activeControllers[controllerID] else { return nil }
            let observation = active.packetTimingTracker.observe(
                timerByte: timerByte,
                bytes: bytes,
                receivedTimestamp: receivedTimestamp
            )
            let summary = active.transportAggregator.record(observation, at: receivedTimestamp)
            return (observation, summary)
        }
        guard let (timing, transportSummary) = timingResult else { return }
        if let transportSummary {
            JamLog.info(.health, "device=joyCon:\(controllerID) transport \(transportSummary.logMessage)")
        }
        guard timing.accepted else { return }

        #if DEBUG
        // One bounded startup sample is enough to identify the report shape.
        if !didLogInputReportSample {
            didLogInputReportSample = true
            let hexBytes = bytes.prefix(50).map { String(format: "%02X", $0) }.joined(separator: " ")
            JamLog.debug(.joyCon, "Input report sample len=\(length) id=0x\(String(format: "%02X", reportID)): \(hexBytes)")
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
            motionSamples: decoded.motionSamples
        ))
    }

    // MARK: - Subcommands

    private func sendSubcommand(_ command: Subcommand.CommandType, data: [UInt8], to active: ActiveController) {
        let device = active.controller.device

        var report = [UInt8](repeating: 0, count: 10 + data.count + 1)
        report[0] = JoyCon.OutputType.subcommand.rawValue
        report[1] = active.outputPacketCounter
        active.outputPacketCounter = (active.outputPacketCounter &+ 1) & 0x0F

        // Default rumble data (silent)
        let rumble: [UInt8] = [0x00, 0x01, 0x00, 0x40, 0x00, 0x01, 0x00, 0x40]
        for i in 0..<rumble.count { report[2 + i] = rumble[i] }

        report[10] = command.rawValue
        for (idx, byte) in data.enumerated() {
            report[11 + idx] = byte
        }

        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(JoyCon.OutputType.subcommand.rawValue), &report, report.count)
        if result != kIOReturnSuccess {
            JamLog.errorThrottled(.joyCon, key: "subcommand.\(command.rawValue)", interval: 2.0, "Joy-Con subcommand \(command) failed: \(result)")
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        JamLog.info(.joyCon, message)
    }
}
