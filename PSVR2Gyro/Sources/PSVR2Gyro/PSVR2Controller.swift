import Foundation
import IOKit
import IOKit.hid
import QuartzCore

/// Minimal controller for PSVR2 Sense Controller
/// Reads raw HID reports and extracts gyro data
class PSVR2Controller {

    // MARK: - Constants

    private static let sonyVendorID = 0x054C
    private static let psvr2LeftProductID = 0x0E45
    private static let psvr2RightProductID = 0x0E46

    // MARK: - Properties

    private var hidManager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 256)

    /// Callback for gyro data (x, y, z in raw units, timestamp)
    var onGyroData: ((_ x: Int16, _ y: Int16, _ z: Int16, _ timestamp: TimeInterval) -> Void)?

    /// Callback for full report data
    var onReportData: ((_ bytes: [UInt8], _ length: Int) -> Void)?

    /// Callback for connection state changes
    var onConnectionChange: ((_ connected: Bool, _ name: String?) -> Void)?

    /// Callback for debug/status messages
    var onDebugMessage: ((_ message: String) -> Void)?

    /// Whether a controller is currently connected
    private(set) var isConnected: Bool = false

    /// Name of the connected controller
    private(set) var controllerName: String?

    // MARK: - IMU Decoding

    // These offsets are experimental - we'll tune them based on testing
    // Based on analysis, IMU data appears to be around bytes 17-30
    var gyroOffsetX: Int = 17
    var gyroOffsetY: Int = 19
    var gyroOffsetZ: Int = 21

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
        if let device = device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }

        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }

        isConnected = false
        controllerName = nil
    }

    // MARK: - Device Callbacks

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        devicesScanned += 1

        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

        // Only log Sony devices or every 10th device to avoid spam
        if vendorID == Self.sonyVendorID {
            log("Sony device: \(name) (PID:0x\(String(format: "%04X", productID)))")
        }

        // Check if it's a Sony device
        guard vendorID == Self.sonyVendorID else {
            return
        }

        // Check if it's a PSVR2 controller
        guard productID == Self.psvr2LeftProductID || productID == Self.psvr2RightProductID else {
            log("Sony device but not PSVR2, skipping")
            return
        }

        log("PSVR2 Sense Controller found!")

        // Open the device
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            print("[PSVR2] Failed to open device: \(result)")
            return
        }

        self.device = device
        self.controllerName = name
        self.isConnected = true

        // Register input report callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            &reportBuffer,
            reportBuffer.count,
            { context, result, sender, type, reportID, report, length in
                guard let ctx = context else { return }
                let controller = Unmanaged<PSVR2Controller>.fromOpaque(ctx).takeUnretainedValue()
                controller.handleInputReport(report: report, length: length, reportID: reportID)
            },
            context
        )

        DispatchQueue.main.async {
            self.onConnectionChange?(true, name)
        }
    }

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        guard self.device == device else { return }

        print("[PSVR2] Controller disconnected")

        self.device = nil
        self.isConnected = false
        let name = self.controllerName
        self.controllerName = nil

        DispatchQueue.main.async {
            self.onConnectionChange?(false, name)
        }
    }

    // MARK: - Input Report Processing

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        // Only process main input reports (0x31)
        guard reportID == 0x31, length >= 40 else { return }

        let timestamp = CACurrentMediaTime()

        // Extract gyro data as signed 16-bit little-endian values
        func readInt16LE(_ offset: Int) -> Int16 {
            guard offset + 1 < length else { return 0 }
            return Int16(bitPattern: UInt16(report[offset]) | (UInt16(report[offset + 1]) << 8))
        }

        let gyroX = readInt16LE(gyroOffsetX)
        let gyroY = readInt16LE(gyroOffsetY)
        let gyroZ = readInt16LE(gyroOffsetZ)

        // Call the gyro callback (on the HID thread for low latency)
        onGyroData?(gyroX, gyroY, gyroZ, timestamp)

        // Extract full report for debug display
        var reportBytes = [UInt8](repeating: 0, count: 78)
        for i in 0..<min(78, length) {
            reportBytes[i] = report[i]
        }
        onReportData?(reportBytes, length)
    }
}
