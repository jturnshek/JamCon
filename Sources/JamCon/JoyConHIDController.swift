import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import MachO
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
    }

    // MARK: - Callbacks
    //
    // Callback contract:
    // All callbacks are invoked on the controller's HID thread/run loop ("JamCon.JoyConHID").

    var onReportData: ((_ report: InputReport) -> Void)?
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?
    var onControllersChanged: (() -> Void)?
    var onDebugMessage: ((_ message: String) -> Void)?

    /// Whether to use packet timer fallback when device timestamps are unavailable
    var useTimerFallback: Bool = true
    /// Whether to prefer a hybrid timer path (controller timer with device timestamp as anchor)
    var useTimerHybrid: Bool = false

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

        // Device timestamp support (used if available from IOHIDValue)
        var lastDeviceTimestamp: TimeInterval?
        var lastDeviceTicks: UInt64?
        var lastTimerByte: UInt8?
        var lastTimerTimestamp: TimeInterval?

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
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(numer: 0, denom: 0)
        mach_timebase_info(&tb)
        return tb
    }()

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
                IOHIDDeviceRegisterInputValueCallback(active.controller.device, nil, nil)
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
                IOHIDDeviceRegisterInputValueCallback(active.controller.device, nil, nil)
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

    func selectController(id: String) {
        setControllerManaged(id: id, managed: true)
    }

    /// Deselect all controllers (stop receiving input).
    func deselectController() {
        let activeIDs = stateLock.withLock { state in
            state.managedControllerIDs.removeAll(keepingCapacity: true)
            return Array(state.activeControllers.keys)
        }
        guard !activeIDs.isEmpty else { return }

        performHIDOperation { [weak self] in
            guard let self else { return }
            for id in activeIDs {
                self.deactivateController(id: id)
            }
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

        // Register value callback to capture device timestamps (if provided by stack)
        IOHIDDeviceRegisterInputValueCallback(
            device,
            { context, _, _, value in
                guard let context else { return }
                let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                callbackContext.owner?.handleInputValue(controllerID: callbackContext.controllerID, value)
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
        IOHIDDeviceRegisterInputValueCallback(active.controller.device, nil, nil)
        IOHIDDeviceClose(active.controller.device, IOOptionBits(kIOHIDOptionsTypeNone))

        let displayName = "\(active.controller.name) (\(active.controller.side))"
        onConnectionChange?(false, displayName, active.controller.id)
    }

    // MARK: - Input reports

    #if DEBUG
    private static var debugLogCounter = 0
    #endif

    private func handleInputReport(controllerID: String, report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        guard reportID == JoyConHIDProtocol.inputReportID else { return }
        let timestamp = computeTimestamp(controllerID: controllerID, report: report, length: length)

        let maxLength = min(length, JoyConHIDProtocol.reportLength)
        var bytes = [UInt8](repeating: 0, count: maxLength)
        for i in 0..<maxLength { bytes[i] = report[i] }

        #if DEBUG
        // Debug: log first few reports to see structure
        Self.debugLogCounter += 1
        if Self.debugLogCounter <= 5 {
            let hexBytes = bytes.prefix(50).map { String(format: "%02X", $0) }.joined(separator: " ")
            JamLog.debug(.joyCon, "Report[\(Self.debugLogCounter)] len=\(length) id=0x\(String(format: "%02X", reportID)): \(hexBytes)")
        }
        #endif

        func readInt16LE(_ offset: Int) -> Int16 {
            guard offset + 1 < maxLength else { return 0 }
            return Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
        }

        let gyroX = readInt16LE(JoyConHIDProtocol.Offset.gyroXLow)
        let gyroY = readInt16LE(JoyConHIDProtocol.Offset.gyroYLow)
        let gyroZ = readInt16LE(JoyConHIDProtocol.Offset.gyroZLow)
        let accelX = readInt16LE(JoyConHIDProtocol.Offset.accelXLow)
        let accelY = readInt16LE(JoyConHIDProtocol.Offset.accelYLow)
        let accelZ = readInt16LE(JoyConHIDProtocol.Offset.accelZLow)

        onReportData?(InputReport(
            controllerID: controllerID,
            bytes: bytes,
            length: maxLength,
            gyroX: gyroX,
            gyroY: gyroY,
            gyroZ: gyroZ,
            accelX: accelX,
            accelY: accelY,
            accelZ: accelZ,
            timestamp: timestamp
        ))
    }

    /// Compute a stable timestamp using device time if available; otherwise fall back to packet timer (byte 1) before host time.
    private func computeTimestamp(controllerID: String, report: UnsafeMutablePointer<UInt8>, length: Int) -> TimeInterval {
        let hostNow = CACurrentMediaTime()

        // Timer byte (packet counter)
        let timerByteIndex = JoyConHIDProtocol.Offset.timer
        let timerAvailable = timerByteIndex < length
        let timerByte = timerAvailable ? UInt8(report[timerByteIndex]) : nil
        let tickSeconds: TimeInterval = 0.001

        return stateLock.withLock { state in
            guard let active = state.activeControllers[controllerID] else { return hostNow }

            if useTimerHybrid, let timer = timerByte {
                // Hybrid: prefer controller timer; device timestamp seeds anchor if present
                let anchor = active.lastTimerTimestamp ?? active.lastDeviceTimestamp ?? hostNow
                if let lastByte = active.lastTimerByte {
                    let deltaTicks = UInt8(bitPattern: Int8(timer &- lastByte))
                    if deltaTicks > 0 && deltaTicks < 200 {
                        let ts = anchor + TimeInterval(deltaTicks) * tickSeconds
                        active.lastTimerByte = timer
                        active.lastTimerTimestamp = ts
                        return ts
                    }
                }
                // Seed timer timeline
                active.lastTimerByte = timer
                active.lastTimerTimestamp = anchor
                return anchor
            }

            if let deviceTs = active.lastDeviceTimestamp {
                // Reset timer fallback state when device timestamps are active
                active.lastTimerByte = nil
                active.lastTimerTimestamp = nil
                return deviceTs
            }

            guard useTimerFallback, let timer = timerByte else {
                active.lastTimerByte = nil
                active.lastTimerTimestamp = nil
                return hostNow
            }

            // Fallback: only use timer when device timestamp is absent
            if let lastByte = active.lastTimerByte, let lastTs = active.lastTimerTimestamp {
                let deltaTicks = UInt8(bitPattern: Int8(timer &- lastByte))
                if deltaTicks > 0 && deltaTicks < 200 {
                    let ts = lastTs + TimeInterval(deltaTicks) * tickSeconds
                    active.lastTimerByte = timer
                    active.lastTimerTimestamp = ts
                    return ts
                }
            }

            active.lastTimerByte = timer
            active.lastTimerTimestamp = hostNow
            return hostNow
        }
    }

    /// Capture device-provided timestamps (if available) to improve dt stability.
    private func handleInputValue(controllerID: String, _ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let reportID = IOHIDElementGetReportID(element)

        guard reportID == JoyConHIDProtocol.inputReportID else { return }

        let ts = IOHIDValueGetTimeStamp(value)
        stateLock.withLock { state in
            guard let active = state.activeControllers[controllerID] else { return }
            // Avoid duplicate timestamps; fall back to host time if they repeat
            if let lastTicks = active.lastDeviceTicks, lastTicks == ts {
                active.lastDeviceTimestamp = nil
                return
            }

            active.lastDeviceTicks = ts
            active.lastDeviceTimestamp = ticksToSeconds(ts)
            // Reset timer fallback state when real device timestamps arrive
            active.lastTimerByte = nil
            active.lastTimerTimestamp = nil
        }
    }

    /// Convert mach ticks to seconds using cached timebase.
    private func ticksToSeconds(_ ticks: UInt64) -> TimeInterval {
        let nanos = (Double(ticks) * Double(timebase.numer)) / Double(timebase.denom)
        return nanos / 1_000_000_000.0
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
