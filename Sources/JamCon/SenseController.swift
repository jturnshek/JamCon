import Foundation
import QuartzCore
import os.lock

/// Represents a discovered Sense controller without exposing its raw IOKit device.
struct DiscoveredController: Identifiable, Equatable, Sendable {
    let id: String  // Unique identifier
    let name: String
    let productID: Int
    let device: any HIDDeviceHandle

    var isLeft: Bool { productID == 0x0E45 }
    var isRight: Bool { productID == 0x0E46 }
    var side: String { isLeft ? "Left" : "Right" }

    /// Convert to UI-safe info struct
    var info: ControllerInfo {
        ControllerInfo(id: id, name: name, productID: productID, kind: .sense)
    }

    static func == (lhs: DiscoveredController, rhs: DiscoveredController) -> Bool {
        lhs.id == rhs.id
    }
}

/// Minimal controller for PlayStation Sense Controller
/// Reads raw HID reports and extracts gyro data
final class SenseController: @unchecked Sendable {
    private static let deactivationRetentionSeconds: TimeInterval = 30.0

    private enum LifecycleState {
        case stopped
        case starting(Thread)
        case running(thread: Thread, runLoop: CFRunLoop)
        case stopping(thread: Thread, runLoop: CFRunLoop)
    }

    // MARK: - Constants (use SenseHIDProtocol for shared constants)

    private static let sonyVendorID = SenseHIDProtocol.sonyVendorID
    private static let senseLeftProductID = SenseHIDProtocol.leftProductID
    private static let senseRightProductID = SenseHIDProtocol.rightProductID

    // MARK: - Properties

    /// Serializes start/stop and makes teardown completion observable. IOKit
    /// resources themselves remain confined to the HID thread.
    private let lifecycleCondition = NSCondition()
    private var lifecycleState: LifecycleState = .stopped
    private let transport: any SenseHIDTransport

    // MARK: - Thread-safe state (read from UI / other threads)

    private struct RetiredController: Sendable {
        let controller: ActiveController
        let retiredAt: TimeInterval
    }

    private final class ActiveController: Sendable {
        let controller: DiscoveredController
        let registration: (any HIDInputRegistration)?

        init(controller: DiscoveredController, registration: (any HIDInputRegistration)? = nil) {
            self.controller = controller
            self.registration = registration
        }
    }

    private struct ControllerState: Sendable {
        var discoveredControllers: [DiscoveredController] = []
        var managedControllerIDs: Set<String> = []
        var activeControllers: [String: ActiveController] = [:]
        var retiredControllers: [RetiredController] = []
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: ControllerState())

    /// UI-safe snapshot of all discovered Sense controllers.
    func controllerInfosSnapshot() -> [ControllerInfo] {
        stateLock.withLock { $0.discoveredControllers.map(\.info) }
    }

    /// Whether any managed controller is currently connected and active (thread-safe).
    var isConnected: Bool {
        stateLock.withLock { !$0.activeControllers.isEmpty }
    }

    /// Name of the connected controller if exactly one is active; otherwise nil. (thread-safe)
    var controllerName: String? {
        stateLock.withLock { state in
            guard state.activeControllers.count == 1, let active = state.activeControllers.values.first else { return nil }
            return active.controller.name
        }
    }

    // MARK: - Callbacks
    //
    // Callback contract:
    // All callbacks are invoked on the controller's HID thread/run loop ("JamCon.Sense.HID").

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
    }

    /// Callback for full report data (bytes are a stable snapshot, includes decoded IMU)
    var onReportData: ((_ report: InputReport) -> Void)?

    /// Callback for connection state changes (includes controller ID to avoid data races)
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?

    /// Callback when available controllers list changes
    var onControllersChanged: (() -> Void)?

    /// Callback for debug/status messages
    var onDebugMessage: ((_ message: String) -> Void)?

    // MARK: - Initialization

    init(transport: any SenseHIDTransport = IOKitSenseHIDTransport()) {
        self.transport = transport
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
            // Selection state is retained while starting and reconciled as
            // soon as enumeration is ready. IOKit work is ignored while
            // stopped or tearing down.
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

        assert(Thread.current === thread, "SenseController IOKit operation must run on the HID thread", file: file, line: line)
    }

    private func log(_ message: String) {
        JamLog.info(.sense, message)
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

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
                thread.name = "JamCon.Sense.HID"
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

    private func runHIDThread() {
        let currentThread = Thread.current
        guard let runLoop = CFRunLoopGetCurrent() else {
            lifecycleCondition.lock()
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
            JamLog.error(.sense, "Failed to obtain HID thread run loop")
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
                JamLog.error(.sense, "Sense HID backend did not start: \(error)")
            }
            return
        }

        lifecycleCondition.lock()
        lifecycleState = .running(thread: currentThread, runLoop: runLoop)
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()

        activateManagedControllersIfNeeded()

        // Run loop with periodic autorelease pool drain to prevent memory accumulation
        // from autoreleased objects created in HID callbacks
        while !Thread.current.isCancelled {
            _ = autoreleasepool {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }

        // This is idempotent and also covers an unexpected run-loop exit.
        cleanupHIDResources(on: runLoop)

        lifecycleCondition.lock()
        lifecycleState = .stopped
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()
    }

    private func configureHIDManager(on runLoop: CFRunLoop) -> Result<Void, HIDTransportError> {
        log("Creating HID manager...")
        log("Matching supported Sony Sense devices...")
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
            log("HID manager started, scanning...")
        }
        return result
    }

    func stop() {
        lifecycleCondition.lock()
        while case .starting = lifecycleState {
            lifecycleCondition.wait()
        }

        switch lifecycleState {
        case .stopped:
            lifecycleCondition.unlock()
            return
        case .stopping:
            while case .stopping = lifecycleState {
                lifecycleCondition.wait()
            }
            lifecycleCondition.unlock()
            return
        case let .running(thread, runLoop):
            lifecycleState = .stopping(thread: thread, runLoop: runLoop)
            thread.cancel()
            lifecycleCondition.unlock()

            if Thread.current === thread {
                CFRunLoopStop(runLoop)
                return
            }

            // Wake the run loop and let runHIDThread perform teardown exactly
            // once after its cancellation loop exits.
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
            // The loop above waits until this state has resolved.
            lifecycleCondition.unlock()
        }
    }

    private func cleanupHIDResources(on runLoop: CFRunLoop) {
        assertOnHIDThread()

        let activeControllers: [ActiveController] = stateLock.withLock { state in
            let active = Array(state.activeControllers.values)
            state.activeControllers.removeAll(keepingCapacity: true)
            return active
        }
        for active in activeControllers {
            close(active)
        }

        transport.stopDiscovery(on: runLoop)

        stateLock.withLock { state in
            state.discoveredControllers.removeAll(keepingCapacity: true)
            state.retiredControllers.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Controller Selection

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

    /// Enable/disable processing for a specific physical controller ID.
    func setControllerManaged(id: String, managed: Bool) {
        if managed {
            let controller: DiscoveredController? = stateLock.withLock { state in
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

    private func activateController(_ controller: DiscoveredController) {
        assertOnHIDThread()

        let controllerID = controller.id
        // This method is commonly queued from another thread. Re-resolve the
        // device at execution time so a preceding unmanage or removal callback
        // cannot make us open a stale controller.
        let currentController: DiscoveredController? = stateLock.withLock { state in
            guard state.managedControllerIDs.contains(controllerID),
                  state.activeControllers[controllerID] == nil,
                  let discovered = state.discoveredControllers.first(where: { $0.id == controllerID }),
                  discovered.device.transportIdentifier == controller.device.transportIdentifier else {
                return nil
            }
            return discovered
        }
        guard let currentController else { return }

        // Do not open the raw HID device. Both exclusive and non-exclusive
        // opens cause PS VR2 Sense Bluetooth sessions to terminate on macOS.
        // IOKit remains responsible only for stable discovery/identity; input
        // arrives through SenseGameControllerSession.
        let active = ActiveController(controller: currentController)
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
            return
        }

        let displayName = "\(currentController.name) (\(currentController.side))"
        log("Activated for Game Controller input: \(displayName)")
        onConnectionChange?(true, displayName, currentController.id)
    }

    private func deactivateController(id: String) {
        assertOnHIDThread()

        let now = CACurrentMediaTime()
        let active: ActiveController? = stateLock.withLock { state in
            guard let active = state.activeControllers.removeValue(forKey: id) else { return nil }
            state.retiredControllers.append(RetiredController(controller: active, retiredAt: now))
            state.retiredControllers.removeAll(where: { now - $0.retiredAt > Self.deactivationRetentionSeconds })
            return active
        }
        guard let active else { return }

        close(active)
        let displayName = "\(active.controller.name) (\(active.controller.side))"
        onConnectionChange?(false, displayName, active.controller.id)
    }

    private func close(_ active: ActiveController) {
        assertOnHIDThread()
        guard let registration = active.registration else { return }
        if case let .failure(error) = transport.closeInput(registration) {
            JamLog.errorThrottled(
                .sense,
                key: "device.close.\(active.controller.id)",
                interval: 2,
                "Failed to close Sense device: \(error)"
            )
        }
    }

    // MARK: - Device Callbacks

    private func handleDeviceConnected(_ device: any HIDDeviceHandle) {
        assertOnHIDThread()

        guard let properties = transport.properties(for: device) else {
            JamLog.error(.sense, "Ignoring Sense device with unreadable HID properties")
            return
        }
        let vendorID = properties.vendorID
        let productID = properties.productID
        let name = properties.name

        // Only log Sony devices
        if vendorID == Self.sonyVendorID {
            log("Sony device: \(name) (PID:0x\(String(format: "%04X", productID)))")
        }

        // Check if it's a Sony Sense controller
        guard vendorID == Self.sonyVendorID,
              productID == Self.senseLeftProductID || productID == Self.senseRightProductID else {
            return
        }

        let uniqueID = HIDDeviceIdentity.identifier(for: properties)

        // Check if already discovered
        let alreadyDiscovered = stateLock.withLock { state in
            state.discoveredControllers.contains(where: { $0.id == uniqueID })
        }
        if alreadyDiscovered { return }

        let controller = DiscoveredController(
            id: uniqueID,
            name: name,
            productID: productID,
            device: device
        )

        stateLock.withLock { state in
            state.discoveredControllers.append(controller)
        }
        log("Sense \(controller.side) Controller discovered!")
        onControllersChanged?()

        // Auto-activate if this controller is currently managed.
        let shouldAutoActivate = stateLock.withLock { state in
            state.managedControllerIDs.contains(uniqueID)
        }
        if shouldAutoActivate {
            activateController(controller)
        }
    }

    private func handleDeviceDisconnected(_ device: any HIDDeviceHandle) {
        assertOnHIDThread()

        // Find and remove the disconnected controller
        let disconnected: DiscoveredController? = stateLock.withLock { state in
            guard let index = state.discoveredControllers.firstIndex(where: {
                $0.device.transportIdentifier == device.transportIdentifier
            }) else { return nil }
            let controller = state.discoveredControllers[index]
            state.discoveredControllers.remove(at: index)
            return controller
        }
        if let controller = disconnected {
            log("Sense \(controller.side) Controller disconnected")

            // If this managed device was active, publish its disconnection and
            // release the associated engine state.
            deactivateController(id: controller.id)
            onControllersChanged?()
        }
    }

    // MARK: - Input Report Processing

    private func handleInputReport(controllerID: String, report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        // Only process main input reports
        guard reportID == SenseHIDProtocol.inputReportID else { return }
        guard length >= SenseHIDProtocol.minimumReportLength else {
            JamLog.errorThrottled(
                .sense,
                key: "malformed.input",
                interval: 2,
                "Discarded malformed Sense input report (length=\(length))"
            )
            return
        }

        let timestamp = CACurrentMediaTime()

        // Snapshot report bytes so decoding and consumers never observe a live
        // IOHID callback buffer.
        let maxLength = min(SenseHIDProtocol.reportLength, length)
        var bytes = [UInt8](repeating: 0, count: maxLength)
        for i in 0..<maxLength { bytes[i] = report[i] }

        guard let decoded = try? SenseInputReportDecoder.decode(bytes) else {
            JamLog.errorThrottled(
                .sense,
                key: "malformed.decode",
                interval: 2,
                "Discarded undecodable Sense input report (length=\(maxLength))"
            )
            return
        }
        let motion = decoded.motion

        // Raw report callbacks do not include an associated kernel timestamp.
        // Use the timestamp captured at callback entry rather than a cached value
        // from a separately ordered IOHIDValue callback.
        let effectiveTimestamp = timestamp

        if let onReportData {
            onReportData(
                InputReport(
                    controllerID: controllerID,
                    bytes: bytes,
                    length: maxLength,
                    gyroX: motion.gyroX,
                    gyroY: motion.gyroY,
                    gyroZ: motion.gyroZ,
                    accelX: motion.accelX,
                    accelY: motion.accelY,
                    accelZ: motion.accelZ,
                    timestamp: effectiveTimestamp,
                    receivedTimestamp: timestamp,
                    inputTimestamp: nil,
                    timestampSource: .hostReceipt
                )
            )
        }
    }
}
