import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import MachO
import os.lock

/// Represents a discovered Sense controller (internal use only - contains IOHIDDevice)
struct DiscoveredController: Identifiable, Equatable {
    let id: String  // Unique identifier
    let name: String
    let productID: Int
    let device: IOHIDDevice

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
class SenseController {
    private static let deactivationRetentionSeconds: TimeInterval = 30.0

    // MARK: - Constants (use SenseHIDProtocol for shared constants)

    private static let sonyVendorID = SenseHIDProtocol.sonyVendorID
    private static let senseLeftProductID = SenseHIDProtocol.leftProductID
    private static let senseRightProductID = SenseHIDProtocol.rightProductID

    // MARK: - Properties

    private var hidManager: IOHIDManager?
    private var hidRunLoop: CFRunLoop?
    private var hidThread: Thread?
    private let hidRunLoopReady = DispatchSemaphore(value: 0)

    // MARK: - Thread-safe state (read from UI / other threads)

    private final class CallbackContext {
        weak var owner: SenseController?
        let controllerID: String

        init(owner: SenseController, controllerID: String) {
            self.owner = owner
            self.controllerID = controllerID
        }
    }

    private struct RetiredController {
        let controller: ActiveController
        let retiredAt: TimeInterval
    }

    private final class ActiveController {
        let controller: DiscoveredController
        let callbackContext: CallbackContext
        let reportBuffer: UnsafeMutablePointer<UInt8>
        let reportBufferLength: Int
        var lastDeviceTimestamp: TimeInterval?
        var lastDeviceTicks: UInt64?

        init(controller: DiscoveredController, owner: SenseController) {
            self.controller = controller
            self.callbackContext = CallbackContext(owner: owner, controllerID: controller.id)
            self.reportBufferLength = 256
            self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferLength)
            self.reportBuffer.initialize(repeating: 0, count: reportBufferLength)
        }

        deinit {
            reportBuffer.deinitialize(count: reportBufferLength)
            reportBuffer.deallocate()
        }
    }

    private struct ControllerState {
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

    /// Callback for gyro data (x, y, z in raw units, timestamp)
    var onGyroData: ((_ x: Int16, _ y: Int16, _ z: Int16, _ timestamp: TimeInterval) -> Void)?

    /// Callback for combined IMU data (gyro + accel for sensor fusion)
    var onIMUData: ((_ gyroX: Int16, _ gyroY: Int16, _ gyroZ: Int16,
                     _ accelX: Int16, _ accelY: Int16, _ accelZ: Int16,
                     _ timestamp: TimeInterval) -> Void)?

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

    /// Callback for full report data (bytes are a stable snapshot, includes decoded IMU)
    var onReportData: ((_ report: InputReport) -> Void)?

    /// Callback for connection state changes (includes controller ID to avoid data races)
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?

    /// Callback when available controllers list changes
    var onControllersChanged: (() -> Void)?

    /// Callback for debug/status messages
    var onDebugMessage: ((_ message: String) -> Void)?

    // MARK: - Timestamped Value Handling

    /// Report ID for IMU input reports (vendor-defined usage)
    private static let imuReportID: UInt32 = SenseHIDProtocol.inputReportID
    /// Timebase for converting mach absolute ticks to seconds (device timestamps)
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(numer: 0, denom: 0)
        mach_timebase_info(&tb)
        return tb
    }()

    /// Convert mach absolute ticks to seconds using system timebase
    private func ticksToSeconds(_ ticks: UInt64) -> TimeInterval {
        let nanos = (Double(ticks) * Double(timebase.numer)) / Double(timebase.denom)
        return nanos / 1_000_000_000.0
    }

    // MARK: - IMU Decoding

    // Gyroscope: bytes 17-22 (CONFIRMED - see SenseHIDProtocol)
    var gyroOffsetX: Int = SenseHIDProtocol.Offset.gyroXLow
    var gyroOffsetY: Int = SenseHIDProtocol.Offset.gyroYLow
    var gyroOffsetZ: Int = SenseHIDProtocol.Offset.gyroZLow

    // Accelerometer: bytes 23-28 (CONFIRMED, ~4096/g - see SenseHIDProtocol)
    var accelOffsetX: Int = SenseHIDProtocol.Offset.accelXLow
    var accelOffsetY: Int = SenseHIDProtocol.Offset.accelYLow
    var accelOffsetZ: Int = SenseHIDProtocol.Offset.accelZLow

    /// Track how many devices we've seen
    private(set) var devicesScanned: Int = 0

    // MARK: - Initialization

    init() {}

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

    private func log(_ message: String) {
        print("[Sense] \(message)")
        dispatchToHIDThread { [weak self] in
            self?.onDebugMessage?(message)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        startHIDThreadIfNeeded()
    }

    private func startHIDThreadIfNeeded() {
        guard hidThread == nil else { return }

        let thread = Thread { [weak self] in
            self?.runHIDThread()
        }
        thread.name = "JamCon.Sense.HID"
        thread.qualityOfService = .userInteractive
        hidThread = thread
        thread.start()

        // Wait until the HID run loop is ready so callers know callbacks are active
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

        // Cleanup after the run loop stops
        hidRunLoop = nil
        hidThread = nil
    }

    private func configureHIDManager(on runLoop: CFRunLoop) {
        guard hidManager == nil else { return }

        log("Creating HID manager...")
        // Use kIOHIDOptionsTypeNone for the manager - we'll seize individual Sense devices in handleDeviceConnected
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            log("Failed to create HID manager")
            return
        }

        // Match ALL HID devices (we'll filter in the callback)
        log("Matching all HID devices...")
        IOHIDManagerSetDeviceMatching(manager, nil)

        // Set up device callbacks
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let ctx = context else { return }
            let controller = Unmanaged<SenseController>.fromOpaque(ctx).takeUnretainedValue()
            controller.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let ctx = context else { return }
            let controller = Unmanaged<SenseController>.fromOpaque(ctx).takeUnretainedValue()
            controller.handleDeviceDisconnected(device)
        }, context)

        // Schedule with run loop
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        // Open the manager (individual devices will be seized in handleDeviceConnected)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log("Failed to open HID manager: \(result)")
        } else {
            log("HID manager started, scanning...")
        }
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

        // Wake the run loop so the stop block executes promptly
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Controller Selection

    /// Select a controller by ID
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
        assert(Thread.current == hidThread, "SenseController.activateController must run on the HID thread")

        let controllerID = controller.id
        let needsActivation: Bool = stateLock.withLock { state in
            state.activeControllers[controllerID] == nil
        }
        guard needsActivation else { return }

        let device = controller.device

        // Open the device with exclusive access (prevents macOS Game Controller from seeing inputs)
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess && result != -536870201 { // Already open is OK
            log("Failed to open device: \(result)")
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

        // Register value callback to get device timestamps for IMU reports
        IOHIDDeviceRegisterInputValueCallback(
            device,
            { context, _, _, value in
                guard let context else { return }
                let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                callbackContext.owner?.handleInputValue(controllerID: callbackContext.controllerID, value)
            },
            context
        )

        let displayName = "\(controller.name) (\(controller.side))"
        log("Activated: \(displayName)")
        onConnectionChange?(true, displayName, controller.id)
    }

    private func deactivateController(id: String) {
        assert(Thread.current == hidThread, "SenseController.deactivateController must run on the HID thread")

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
        let displayName = "\(active.controller.name) (\(active.controller.side))"
        onConnectionChange?(false, displayName, active.controller.id)
    }

    // MARK: - Device Callbacks

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        devicesScanned += 1

        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

        // Only log Sony devices
        if vendorID == Self.sonyVendorID {
            log("Sony device: \(name) (PID:0x\(String(format: "%04X", productID)))")
        }

        // Check if it's a Sony Sense controller
        guard vendorID == Self.sonyVendorID,
              productID == Self.senseLeftProductID || productID == Self.senseRightProductID else {
            return
        }

        // Seize this specific device to prevent macOS Game Controller framework
        // from intercepting button presses and mapping them to keyboard keys
        let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if seizeResult != kIOReturnSuccess {
            log("Warning: Could not seize device exclusively: \(seizeResult)")
        } else {
            log("Device seized for exclusive access")
        }

        // Create unique ID from device properties
        let serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        let uniqueID = serialNumber ?? "loc-\(locationID)-pid-\(productID)"

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

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        // Find and remove the disconnected controller
        let disconnected: DiscoveredController? = stateLock.withLock { state in
            guard let index = state.discoveredControllers.firstIndex(where: { $0.device == device }) else { return nil }
            let controller = state.discoveredControllers[index]
            state.discoveredControllers.remove(at: index)
            return controller
        }
        if let controller = disconnected {
            log("Sense \(controller.side) Controller disconnected")

            // If this was active, deactivate first to ensure callbacks are unregistered.
            deactivateController(id: controller.id)

            // Close the seized device to release exclusive access
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            onControllersChanged?()
        }
    }

    // MARK: - Input Report Processing

    private func handleInputReport(controllerID: String, report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        // Only process main input reports
        guard reportID == SenseHIDProtocol.inputReportID,
              length >= SenseHIDProtocol.minimumReportLength else { return }

        let timestamp = CACurrentMediaTime()

        // Extract gyro/accel only if callbacks are present
        let needsGyro = onGyroData != nil || onIMUData != nil || onReportData != nil
        var gyroX: Int16 = 0
        var gyroY: Int16 = 0
        var gyroZ: Int16 = 0
        var accelX: Int16 = 0
        var accelY: Int16 = 0
        var accelZ: Int16 = 0

        if needsGyro {
            func readInt16LE(_ offset: Int) -> Int16 {
                guard offset + 1 < length else { return 0 }
                return Int16(bitPattern: UInt16(report[offset]) | (UInt16(report[offset + 1]) << 8))
            }

            gyroX = readInt16LE(gyroOffsetX)
            gyroY = readInt16LE(gyroOffsetY)
            gyroZ = readInt16LE(gyroOffsetZ)

            // Extract accelerometer data
            accelX = readInt16LE(accelOffsetX)
            accelY = readInt16LE(accelOffsetY)
            accelZ = readInt16LE(accelOffsetZ)
        }

        // Call the gyro callback (on the HID thread for low latency) using device timestamp if available
        let effectiveTimestamp = stateLock.withLock { state in
            state.activeControllers[controllerID]?.lastDeviceTimestamp ?? timestamp
        }
        if let onGyroData {
            onGyroData(gyroX, gyroY, gyroZ, effectiveTimestamp)
        }

        // Call the combined IMU callback for sensor fusion
        if let onIMUData {
            onIMUData(gyroX, gyroY, gyroZ, accelX, accelY, accelZ, effectiveTimestamp)
        }

        // Snapshot report bytes so consumers never observe a live IOHID callback buffer.
        let maxLength = min(SenseHIDProtocol.reportLength, length)
        var bytes = [UInt8](repeating: 0, count: maxLength)
        for i in 0..<maxLength { bytes[i] = report[i] }

        if let onReportData {
            onReportData(
                InputReport(
                    controllerID: controllerID,
                    bytes: bytes,
                    length: maxLength,
                    gyroX: gyroX,
                    gyroY: gyroY,
                    gyroZ: gyroZ,
                    accelX: accelX,
                    accelY: accelY,
                    accelZ: accelZ,
                    timestamp: effectiveTimestamp
                )
            )
        }
    }

    /// Handle input values to capture device timestamps for IMU reports
    private func handleInputValue(controllerID: String, _ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let reportID = IOHIDElementGetReportID(element)

        // We only care about the main IMU report (0x31). Values for other report IDs are ignored.
        guard reportID == Self.imuReportID else { return }

        // Convert kernel tick to seconds
        let ts = IOHIDValueGetTimeStamp(value)
        stateLock.withLock { state in
            guard let active = state.activeControllers[controllerID] else { return }
            // Avoid duplicate timestamps; fall back to host if they repeat
            if let lastTicks = active.lastDeviceTicks, lastTicks == ts {
                active.lastDeviceTimestamp = nil
                return
            }
            active.lastDeviceTicks = ts
            active.lastDeviceTimestamp = ticksToSeconds(ts)
        }
    }

    // MARK: - Output Reports (EXPERIMENTAL - based on DualSense/Sense protocol)

    /// Sequence tag for Bluetooth output reports
    private var outputSeqTag: UInt8 = 0

    /// Send a raw output report to the controller
    /// Returns true if the report was sent successfully
    @discardableResult
    func sendOutputReport(_ data: [UInt8], reportID: UInt8 = SenseHIDProtocol.OutputReport.reportID) -> Bool {
        let devices: [IOHIDDevice] = stateLock.withLock { state in
            state.activeControllers.values.map { $0.controller.device }
        }
        guard !devices.isEmpty else {
            log("Cannot send output: no active devices")
            return false
        }

        var didSucceed = true
        for device in devices {
            var reportData = data
            let result = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(reportID),
                &reportData,
                reportData.count
            )

            if result != kIOReturnSuccess {
                didSucceed = false
                log("Output report failed: \(result)")
            }
        }
        return didSucceed
    }

    /// Build a DualSense-style Bluetooth output report
    /// This is EXPERIMENTAL - Sense controller may use different format
    private func buildBTOutputReport(
        motorLeft: UInt8 = 0,
        motorRight: UInt8 = 0,
        ledRed: UInt8 = 0,
        ledGreen: UInt8 = 0,
        ledBlue: UInt8 = 0,
        playerLEDs: UInt8 = 0,
        validFlags0: UInt8 = 0,
        validFlags1: UInt8 = 0
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: SenseHIDProtocol.OutputReport.length)

        // Bluetooth header
        report[0] = outputSeqTag << 4  // Sequence tag in upper nibble
        outputSeqTag = (outputSeqTag + 1) & 0x0F
        report[1] = SenseHIDProtocol.OutputReport.tagByteValue

        // Common report structure starts at offset 2
        report[2] = validFlags0  // Valid flags 0
        report[3] = validFlags1  // Valid flags 1
        report[4] = motorRight   // Right motor
        report[5] = motorLeft    // Left motor

        // Skip audio/mic settings (bytes 6-10)

        // Trigger effects would go here (bytes 11-21 for right, 22-32 for left)

        // LED settings (offset varies - trying DualSense offsets)
        report[SenseHIDProtocol.OutputReport.lightbarSetup] = 0x02  // Lightbar setup - enable
        report[SenseHIDProtocol.OutputReport.ledBrightness] = 0x02  // LED brightness
        report[SenseHIDProtocol.OutputReport.playerLEDs] = playerLEDs
        report[SenseHIDProtocol.OutputReport.ledRed] = ledRed
        report[SenseHIDProtocol.OutputReport.ledGreen] = ledGreen
        report[SenseHIDProtocol.OutputReport.ledBlue] = ledBlue

        // CRC32 would go in bytes 74-77, but we'll try without first

        return report
    }

    // MARK: - Convenience Methods for Testing

    /// Test rumble motors (EXPERIMENTAL - may not work over Bluetooth)
    func testRumble(left: UInt8, right: UInt8) {
        log("Testing rumble: L=\(left), R=\(right)")

        // Flag 0x01 = enable rumble
        let report = buildBTOutputReport(
            motorLeft: left,
            motorRight: right,
            validFlags0: 0x01
        )
        sendOutputReport(report)
    }

    /// Test LED/lightbar color (EXPERIMENTAL)
    func testLED(red: UInt8, green: UInt8, blue: UInt8) {
        log("Testing LED: R=\(red), G=\(green), B=\(blue)")

        // Flag 0x04 = enable LED control
        let report = buildBTOutputReport(
            ledRed: red,
            ledGreen: green,
            ledBlue: blue,
            validFlags0: 0x04
        )
        sendOutputReport(report)
    }

    /// Test player indicator LEDs (EXPERIMENTAL)
    func testPlayerLEDs(mask: UInt8) {
        log("Testing player LEDs: 0x\(String(format: "%02X", mask))")

        let report = buildBTOutputReport(
            playerLEDs: mask,
            validFlags0: 0x04
        )
        sendOutputReport(report)
    }

    /// Stop all effects
    func stopAllEffects() {
        log("Stopping all effects")

        let report = buildBTOutputReport(
            motorLeft: 0,
            motorRight: 0,
            ledRed: 0,
            ledGreen: 0,
            ledBlue: 0,
            validFlags0: 0x05  // Rumble + LED
        )
        sendOutputReport(report)
    }
}
