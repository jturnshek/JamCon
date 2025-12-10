import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import MachO

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

    // MARK: - Constants (use SenseHIDProtocol for shared constants)

    private static let sonyVendorID = SenseHIDProtocol.sonyVendorID
    private static let senseLeftProductID = SenseHIDProtocol.leftProductID
    private static let senseRightProductID = SenseHIDProtocol.rightProductID

    // MARK: - Properties

    private var hidManager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 256)
    private var hidRunLoop: CFRunLoop?
    private var hidThread: Thread?
    private let hidRunLoopReady = DispatchSemaphore(value: 0)

    /// All discovered Sense controllers
    private(set) var discoveredControllers: [DiscoveredController] = []

    /// Currently selected controller ID
    private(set) var selectedControllerID: String?

    /// Preferred controller ID (persisted from last user selection)
    /// Used to auto-select only previously selected controllers
    var preferredControllerID: String?

    /// Callback for gyro data (x, y, z in raw units, timestamp)
    var onGyroData: ((_ x: Int16, _ y: Int16, _ z: Int16, _ timestamp: TimeInterval) -> Void)?

    /// Callback for combined IMU data (gyro + accel for sensor fusion)
    var onIMUData: ((_ gyroX: Int16, _ gyroY: Int16, _ gyroZ: Int16,
                     _ accelX: Int16, _ accelY: Int16, _ accelZ: Int16,
                     _ timestamp: TimeInterval) -> Void)?

    struct InputReport {
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

    /// Callback for full report data (reuses internal buffer, includes decoded IMU)
    var onReportData: ((_ report: InputReport) -> Void)?

    /// Callback for connection state changes (includes controller ID to avoid data races)
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?

    /// Callback when available controllers list changes
    var onControllersChanged: (() -> Void)?

    /// Callback for debug/status messages
    var onDebugMessage: ((_ message: String) -> Void)?

    /// Whether a controller is currently connected and active
    private(set) var isConnected: Bool = false

    /// Name of the connected controller
    private(set) var controllerName: String?

    // MARK: - Timestamped Value Handling

    /// Report ID for IMU input reports (vendor-defined usage)
    private static let imuReportID: UInt32 = SenseHIDProtocol.inputReportID
    /// Cached last timestamp from device (seconds, monotonic)
    private var lastDeviceTimestamp: TimeInterval?
    /// Last raw device ticks to detect duplicates
    private var lastDeviceTicks: UInt64?
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

    /// Last known gyro timestamp in seconds (device if available, else host time)
    var lastGyroTimestamp: TimeInterval {
        lastDeviceTimestamp ?? CACurrentMediaTime()
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

    private func log(_ message: String) {
        print("[Sense] \(message)")
        DispatchQueue.main.async {
            self.onDebugMessage?(message)
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
            if let device = activeDevice {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                activeDevice = nil
            }
            if let manager = hidManager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                hidManager = nil
            }
            discoveredControllers.removeAll()
            selectedControllerID = nil
            isConnected = false
            controllerName = nil
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }

            if let device = self.activeDevice {
                IOHIDDeviceRegisterInputReportCallback(device, &self.reportBuffer, self.reportBuffer.count, nil, nil)
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                self.activeDevice = nil
            }

            if let manager = self.hidManager {
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                self.hidManager = nil
            }

            self.discoveredControllers.removeAll()
            self.selectedControllerID = nil
            self.isConnected = false
            self.controllerName = nil

            CFRunLoopStop(runLoop)
        }

        // Wake the run loop so the stop block executes promptly
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Controller Selection

    /// Select a controller by ID
    func selectController(id: String) {
        guard let controller = discoveredControllers.first(where: { $0.id == id }) else {
            log("Controller \(id) not found")
            return
        }

        // Deactivate current controller if different
        if let currentID = selectedControllerID, currentID != id {
            deactivateCurrentController()
        }

        // Activate the new controller
        activateController(controller)
    }

    /// Deselect the current controller (stop receiving input)
    func deselectController() {
        selectedControllerID = nil
        preferredControllerID = nil
        deactivateCurrentController()
    }

    private func activateController(_ controller: DiscoveredController) {
        let device = controller.device

        // Open the device with exclusive access (prevents macOS Game Controller from seeing inputs)
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess && result != -536870201 { // Already open is OK
            log("Failed to open device: \(result)")
            return
        }

        self.activeDevice = device
        self.selectedControllerID = controller.id
        self.controllerName = "\(controller.name) (\(controller.side))"
        self.isConnected = true

        // Register input report callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            &reportBuffer,
            reportBuffer.count,
            { context, result, sender, type, reportID, report, length in
                guard let ctx = context else { return }
                let sense = Unmanaged<SenseController>.fromOpaque(ctx).takeUnretainedValue()
                sense.handleInputReport(report: report, length: length, reportID: reportID)
            },
            context
        )

        // Register value callback to get device timestamps for IMU reports
        IOHIDDeviceRegisterInputValueCallback(
            device,
            { context, result, sender, value in
                guard let ctx = context else { return }
                let sense = Unmanaged<SenseController>.fromOpaque(ctx).takeUnretainedValue()
                sense.handleInputValue(value)
            },
            context
        )

        log("Activated: \(controllerName ?? "Unknown")")

        // Capture values before dispatching to avoid data races
        let name = self.controllerName
        let controllerID = self.selectedControllerID
        DispatchQueue.main.async {
            self.onConnectionChange?(true, name, controllerID)
        }
    }

    private func deactivateCurrentController() {
        if let device = activeDevice {
            IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        }
        activeDevice = nil
        isConnected = false
        let name = controllerName
        let controllerID = selectedControllerID
        controllerName = nil

        DispatchQueue.main.async {
            self.onConnectionChange?(false, name, controllerID)
        }
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
        if discoveredControllers.contains(where: { $0.id == uniqueID }) {
            return
        }

        let controller = DiscoveredController(
            id: uniqueID,
            name: name,
            productID: productID,
            device: device
        )

        discoveredControllers.append(controller)
        log("Sense \(controller.side) Controller discovered!")

        DispatchQueue.main.async {
            self.onControllersChanged?()
        }

        // Only auto-select if this controller was previously selected by user
        // (matches saved preference) or is reconnecting current session's selection
        if selectedControllerID == uniqueID ||
           (selectedControllerID == nil && preferredControllerID == uniqueID) {
            activateController(controller)
        }
    }

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        // Find and remove the disconnected controller
        if let index = discoveredControllers.firstIndex(where: { $0.device == device }) {
            let controller = discoveredControllers[index]
            log("Sense \(controller.side) Controller disconnected")

            // Close the seized device to release exclusive access
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

            discoveredControllers.remove(at: index)

            DispatchQueue.main.async {
                self.onControllersChanged?()
            }

            // If this was the active controller, deactivate
            if controller.id == selectedControllerID {
                deactivateCurrentController()
                // Don't auto-select another - user must manually select
            }
        }
    }

    // MARK: - Input Report Processing

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
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
        let effectiveTimestamp = lastDeviceTimestamp ?? timestamp
        if let onGyroData {
            onGyroData(gyroX, gyroY, gyroZ, effectiveTimestamp)
        }

        // Call the combined IMU callback for sensor fusion
        if let onIMUData {
            onIMUData(gyroX, gyroY, gyroZ, accelX, accelY, accelZ, effectiveTimestamp)
        }

        // Copy full report into reused buffer for debug display
        let maxLength = min(SenseHIDProtocol.reportLength, min(length, reportBuffer.count))
        for i in 0..<maxLength {
            reportBuffer[i] = report[i]
        }

        if let onReportData {
            onReportData(
                InputReport(
                    bytes: reportBuffer,
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
    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let reportID = IOHIDElementGetReportID(element)

        // We only care about the main IMU report (0x31). Values for other report IDs are ignored.
        guard reportID == Self.imuReportID else { return }

        // Convert kernel tick to seconds
        let ts = IOHIDValueGetTimeStamp(value)
        // Avoid duplicate timestamps; fall back to host if they repeat
        if let lastTicks = lastDeviceTicks, lastTicks == ts {
            lastDeviceTimestamp = nil
            return
        }
        lastDeviceTicks = ts
        if (lastDeviceTicks ?? 0) == ts { lastDeviceTimestamp = nil; return }
        lastDeviceTicks = ts
        lastDeviceTimestamp = ticksToSeconds(ts)
    }

    // MARK: - Output Reports (EXPERIMENTAL - based on DualSense/Sense protocol)

    /// Sequence tag for Bluetooth output reports
    private var outputSeqTag: UInt8 = 0

    /// Send a raw output report to the controller
    /// Returns true if the report was sent successfully
    @discardableResult
    func sendOutputReport(_ data: [UInt8], reportID: UInt8 = SenseHIDProtocol.OutputReport.reportID) -> Bool {
        guard let device = activeDevice else {
            log("Cannot send output: no active device")
            return false
        }

        var reportData = data
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            CFIndex(reportID),
            &reportData,
            reportData.count
        )

        if result != kIOReturnSuccess {
            log("Output report failed: \(result)")
            return false
        }
        return true
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
