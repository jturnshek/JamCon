import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import MachO

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

/// Minimal Joy-Con HID driver (Bluetooth) that mirrors the PSVR2 controller flow:
/// - Scans for Joy-Con L/R
/// - Seizes the device
/// - Enables IMU + sets input mode 0x30
/// - Streams raw input reports and decodes the newest IMU sample for convenience
final class JoyConHIDController {
    // MARK: - Types

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

    // MARK: - Callbacks

    var onReportData: ((_ report: InputReport) -> Void)?
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ controllerID: String?) -> Void)?
    var onControllersChanged: (() -> Void)?
    var onDebugMessage: ((_ message: String) -> Void)?

    // MARK: - State

    private var hidManager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var hidRunLoop: CFRunLoop?
    private var hidThread: Thread?
    private let hidRunLoopReady = DispatchSemaphore(value: 0)
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    private(set) var discoveredControllers: [DiscoveredJoyCon] = []
    private(set) var selectedControllerID: String?
    var preferredControllerID: String?
    private(set) var isConnected: Bool = false
    private(set) var controllerName: String?

    private var outputPacketCounter: UInt8 = 0

    /// Device timestamp support (used if available from IOHIDValue)
    private var lastDeviceTimestamp: TimeInterval?
    private var lastDeviceTicks: UInt64?
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(numer: 0, denom: 0)
        mach_timebase_info(&tb)
        return tb
    }()

    // MARK: - Init / lifecycle

    init() {}

    deinit { stop() }

    func start() {
        startHIDThreadIfNeeded()
    }

    func stop() {
        guard let runLoop = hidRunLoop else { return }

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

        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - HID thread

    private func startHIDThreadIfNeeded() {
        guard hidThread == nil else { return }

        let thread = Thread { [weak self] in
            autoreleasepool { self?.runHIDThread() }
        }
        thread.name = "PSVR2Gyro.JoyConHID"
        thread.qualityOfService = .userInteractive
        hidThread = thread
        thread.start()

        hidRunLoopReady.wait()
    }

    private func runHIDThread() {
        hidRunLoop = CFRunLoopGetCurrent()
        hidRunLoopReady.signal()

        configureHIDManager(on: hidRunLoop ?? CFRunLoopGetCurrent())
        CFRunLoopRun()

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

        if discoveredControllers.contains(where: { $0.id == uniqueID }) {
            return
        }

        let controller = DiscoveredJoyCon(id: uniqueID, name: name, productID: productID, device: device)
        discoveredControllers.append(controller)
        onControllersChanged?()
        log("Joy-Con discovered: \(name) (PID: 0x\(String(format: "%04X", productID)))")

        if selectedControllerID == uniqueID || (selectedControllerID == nil && preferredControllerID == uniqueID) {
            activateController(controller)
        } else if selectedControllerID == nil && preferredControllerID == nil {
            // Auto-select first discovered if nothing chosen yet
            activateController(controller)
        }
    }

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        if let index = discoveredControllers.firstIndex(where: { $0.device == device }) {
            let controller = discoveredControllers[index]
            log("Joy-Con disconnected: \(controller.name)")
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            discoveredControllers.remove(at: index)
            onControllersChanged?()

            if controller.id == selectedControllerID {
                deactivateCurrentController()
            }
        }
    }

    func selectController(id: String) {
        guard let controller = discoveredControllers.first(where: { $0.id == id }) else {
            log("Joy-Con \(id) not found")
            return
        }
        if selectedControllerID != id {
            deactivateCurrentController()
        }
        activateController(controller)
    }

    /// Deselect the current controller (stop receiving input)
    func deselectController() {
        selectedControllerID = nil
        preferredControllerID = nil
        deactivateCurrentController()
    }

    private func activateController(_ controller: DiscoveredJoyCon) {
        let device = controller.device
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess && result != -536870201 { // already open OK
            log("Failed to open Joy-Con: \(result)")
            return
        }

        activeDevice = device
        selectedControllerID = controller.id
        controllerName = controller.name
        isConnected = true

        // Register input report callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            &reportBuffer,
            reportBuffer.count,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let joyCon = Unmanaged<JoyConHIDController>.fromOpaque(context).takeUnretainedValue()
                joyCon.handleInputReport(report: report, length: length, reportID: reportID)
            },
            context
        )

        // Register value callback to capture device timestamps (if provided by stack)
        IOHIDDeviceRegisterInputValueCallback(
            device,
            { context, _, _, value in
                guard let context else { return }
                let joyCon = Unmanaged<JoyConHIDController>.fromOpaque(context).takeUnretainedValue()
                joyCon.handleInputValue(value)
            },
            context
        )

        // Enable IMU + set input mode
        sendSubcommand(.enableIMU, data: [0x01])
        sendSubcommand(.setInputMode, data: [UInt8(JoyCon.InputMode.standardFull.rawValue)])
        sendSubcommand(.enableVibration, data: [0x01]) // keep LEDs happy
        sendSubcommand(.setPlayerLights, data: [0x01])

        onConnectionChange?(true, controllerName, selectedControllerID)
        log("Joy-Con activated: \(controllerName ?? controller.side)")
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
        selectedControllerID = nil
        onConnectionChange?(false, name, controllerID)
    }

    // MARK: - Input reports

    private static var debugLogCounter = 0

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        guard reportID == JoyConHIDProtocol.inputReportID else { return }
        let timestamp = lastDeviceTimestamp ?? CACurrentMediaTime()

        let maxLength = min(length, reportBuffer.count)
        var bytes = [UInt8](repeating: 0, count: maxLength)
        for i in 0..<maxLength { bytes[i] = report[i] }

        // Debug: log first few reports to see structure
        Self.debugLogCounter += 1
        if Self.debugLogCounter <= 5 {
            let hexBytes = bytes.prefix(50).map { String(format: "%02X", $0) }.joined(separator: " ")
            log("Report[\(Self.debugLogCounter)] len=\(length) id=0x\(String(format: "%02X", reportID)): \(hexBytes)")
        }

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

    /// Capture device-provided timestamps (if available) to improve dt stability.
    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let reportID = IOHIDElementGetReportID(element)

        guard reportID == JoyConHIDProtocol.inputReportID else { return }

        let ts = IOHIDValueGetTimeStamp(value)
        // Avoid duplicate timestamps; fall back to host time if they repeat
        if let lastTicks = lastDeviceTicks, lastTicks == ts {
            lastDeviceTimestamp = nil
            return
        }

        lastDeviceTicks = ts
        lastDeviceTimestamp = ticksToSeconds(ts)
    }

    /// Convert mach ticks to seconds using cached timebase.
    private func ticksToSeconds(_ ticks: UInt64) -> TimeInterval {
        let nanos = (Double(ticks) * Double(timebase.numer)) / Double(timebase.denom)
        return nanos / 1_000_000_000.0
    }

    // MARK: - Subcommands

    private func sendSubcommand(_ command: Subcommand.CommandType, data: [UInt8]) {
        guard let device = activeDevice else { return }

        var report = [UInt8](repeating: 0, count: 10 + data.count + 1)
        report[0] = JoyCon.OutputType.subcommand.rawValue
        report[1] = outputPacketCounter
        outputPacketCounter = (outputPacketCounter &+ 1) & 0x0F

        // Default rumble data (silent)
        let rumble: [UInt8] = [0x00, 0x01, 0x00, 0x40, 0x00, 0x01, 0x00, 0x40]
        for i in 0..<rumble.count { report[2 + i] = rumble[i] }

        report[10] = command.rawValue
        for (idx, byte) in data.enumerated() {
            report[11 + idx] = byte
        }

        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(JoyCon.OutputType.subcommand.rawValue), &report, report.count)
        if result != kIOReturnSuccess {
            log("Joy-Con subcommand \(command) failed: \(result)")
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        print("[JoyCon] \(message)")
        onDebugMessage?(message)
    }
}
