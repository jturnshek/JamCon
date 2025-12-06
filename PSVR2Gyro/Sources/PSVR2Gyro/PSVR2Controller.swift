import Foundation
import IOKit
import IOKit.hid
import QuartzCore

/// UI-safe controller info (no IOHIDDevice reference - safe for SwiftUI)
struct ControllerInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let productID: Int

    var isLeft: Bool { productID == 0x0E45 }
    var isRight: Bool { productID == 0x0E46 }
    var side: String { isLeft ? "Left" : "Right" }
}

/// Represents a discovered PSVR2 controller (internal use only - contains IOHIDDevice)
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
        ControllerInfo(id: id, name: name, productID: productID)
    }

    static func == (lhs: DiscoveredController, rhs: DiscoveredController) -> Bool {
        lhs.id == rhs.id
    }
}

/// Minimal controller for PSVR2 Sense Controller
/// Reads raw HID reports and extracts gyro data
class PSVR2Controller {

    // MARK: - Constants (use PSVR2HIDProtocol for shared constants)

    private static let sonyVendorID = PSVR2HIDProtocol.sonyVendorID
    private static let psvr2LeftProductID = PSVR2HIDProtocol.leftProductID
    private static let psvr2RightProductID = PSVR2HIDProtocol.rightProductID

    // MARK: - Properties

    private var hidManager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 256)

    /// All discovered PSVR2 controllers
    private(set) var discoveredControllers: [DiscoveredController] = []

    /// Currently selected controller ID
    private(set) var selectedControllerID: String?

    /// Callback for gyro data (x, y, z in raw units, timestamp)
    var onGyroData: ((_ x: Int16, _ y: Int16, _ z: Int16, _ timestamp: TimeInterval) -> Void)?

    /// Callback for combined IMU data (gyro + accel for sensor fusion)
    var onIMUData: ((_ gyroX: Int16, _ gyroY: Int16, _ gyroZ: Int16,
                     _ accelX: Int16, _ accelY: Int16, _ accelZ: Int16,
                     _ timestamp: TimeInterval) -> Void)?

    /// Callback for full report data
    var onReportData: ((_ bytes: [UInt8], _ length: Int) -> Void)?

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

    // MARK: - IMU Decoding

    // Gyroscope: bytes 17-22 (CONFIRMED - see PSVR2HIDProtocol)
    var gyroOffsetX: Int = PSVR2HIDProtocol.Offset.gyroXLow
    var gyroOffsetY: Int = PSVR2HIDProtocol.Offset.gyroYLow
    var gyroOffsetZ: Int = PSVR2HIDProtocol.Offset.gyroZLow

    // Accelerometer: bytes 23-28 (CONFIRMED, ~4096/g - see PSVR2HIDProtocol)
    var accelOffsetX: Int = PSVR2HIDProtocol.Offset.accelXLow
    var accelOffsetY: Int = PSVR2HIDProtocol.Offset.accelYLow
    var accelOffsetZ: Int = PSVR2HIDProtocol.Offset.accelZLow

    /// Track how many devices we've seen
    private(set) var devicesScanned: Int = 0

    // MARK: - Initialization

    init() {}

    private func log(_ message: String) {
        print("[PSVR2] \(message)")
        DispatchQueue.main.async {
            self.onDebugMessage?(message)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        guard hidManager == nil else { return }

        log("Creating HID manager...")
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
            let controller = Unmanaged<PSVR2Controller>.fromOpaque(ctx).takeUnretainedValue()
            controller.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let ctx = context else { return }
            let controller = Unmanaged<PSVR2Controller>.fromOpaque(ctx).takeUnretainedValue()
            controller.handleDeviceDisconnected(device)
        }, context)

        // Schedule with run loop
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Open the manager
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log("Failed to open HID manager: \(result)")
        } else {
            log("HID manager started, scanning...")
        }
    }

    func stop() {
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

    private func activateController(_ controller: DiscoveredController) {
        let device = controller.device

        // Open the device if not already open
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
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
                let psvr2 = Unmanaged<PSVR2Controller>.fromOpaque(ctx).takeUnretainedValue()
                psvr2.handleInputReport(report: report, length: length, reportID: reportID)
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

        // Check if it's a Sony PSVR2 controller
        guard vendorID == Self.sonyVendorID,
              productID == Self.psvr2LeftProductID || productID == Self.psvr2RightProductID else {
            return
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
        log("PSVR2 \(controller.side) Controller discovered!")

        DispatchQueue.main.async {
            self.onControllersChanged?()
        }

        // Auto-select if this is the first/only controller, or if we had a previous selection
        if selectedControllerID == nil || selectedControllerID == uniqueID {
            activateController(controller)
        }
    }

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        // Find and remove the disconnected controller
        if let index = discoveredControllers.firstIndex(where: { $0.device == device }) {
            let controller = discoveredControllers[index]
            log("PSVR2 \(controller.side) Controller disconnected")

            discoveredControllers.remove(at: index)

            DispatchQueue.main.async {
                self.onControllersChanged?()
            }

            // If this was the active controller, deactivate
            if controller.id == selectedControllerID {
                deactivateCurrentController()

                // Auto-select another if available
                if let next = discoveredControllers.first {
                    activateController(next)
                }
            }
        }
    }

    // MARK: - Input Report Processing

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        // Only process main input reports
        guard reportID == PSVR2HIDProtocol.inputReportID,
              length >= PSVR2HIDProtocol.minimumReportLength else { return }

        let timestamp = CACurrentMediaTime()

        // Extract gyro data as signed 16-bit little-endian values
        func readInt16LE(_ offset: Int) -> Int16 {
            guard offset + 1 < length else { return 0 }
            return Int16(bitPattern: UInt16(report[offset]) | (UInt16(report[offset + 1]) << 8))
        }

        let gyroX = readInt16LE(gyroOffsetX)
        let gyroY = readInt16LE(gyroOffsetY)
        let gyroZ = readInt16LE(gyroOffsetZ)

        // Extract accelerometer data
        let accelX = readInt16LE(accelOffsetX)
        let accelY = readInt16LE(accelOffsetY)
        let accelZ = readInt16LE(accelOffsetZ)

        // Call the gyro callback (on the HID thread for low latency)
        onGyroData?(gyroX, gyroY, gyroZ, timestamp)

        // Call the combined IMU callback for sensor fusion
        onIMUData?(gyroX, gyroY, gyroZ, accelX, accelY, accelZ, timestamp)

        // Extract full report for debug display
        var reportBytes = [UInt8](repeating: 0, count: PSVR2HIDProtocol.reportLength)
        for i in 0..<min(PSVR2HIDProtocol.reportLength, length) {
            reportBytes[i] = report[i]
        }
        onReportData?(reportBytes, length)
    }

    // MARK: - Output Reports (EXPERIMENTAL - based on DualSense protocol)

    /// Sequence tag for Bluetooth output reports
    private var outputSeqTag: UInt8 = 0

    /// Send a raw output report to the controller
    /// Returns true if the report was sent successfully
    @discardableResult
    func sendOutputReport(_ data: [UInt8], reportID: UInt8 = PSVR2HIDProtocol.OutputReport.reportID) -> Bool {
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
    /// This is EXPERIMENTAL - PSVR2 Sense may use different format
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
        var report = [UInt8](repeating: 0, count: PSVR2HIDProtocol.OutputReport.length)

        // Bluetooth header
        report[0] = outputSeqTag << 4  // Sequence tag in upper nibble
        outputSeqTag = (outputSeqTag + 1) & 0x0F
        report[1] = PSVR2HIDProtocol.OutputReport.tagByteValue

        // Common report structure starts at offset 2
        report[2] = validFlags0  // Valid flags 0
        report[3] = validFlags1  // Valid flags 1
        report[4] = motorRight   // Right motor
        report[5] = motorLeft    // Left motor

        // Skip audio/mic settings (bytes 6-10)

        // Trigger effects would go here (bytes 11-21 for right, 22-32 for left)

        // LED settings (offset varies - trying DualSense offsets)
        report[PSVR2HIDProtocol.OutputReport.lightbarSetup] = 0x02  // Lightbar setup - enable
        report[PSVR2HIDProtocol.OutputReport.ledBrightness] = 0x02  // LED brightness
        report[PSVR2HIDProtocol.OutputReport.playerLEDs] = playerLEDs
        report[PSVR2HIDProtocol.OutputReport.ledRed] = ledRed
        report[PSVR2HIDProtocol.OutputReport.ledGreen] = ledGreen
        report[PSVR2HIDProtocol.OutputReport.ledBlue] = ledBlue

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
