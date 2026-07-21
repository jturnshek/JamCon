import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

/// Opaque, transport-owned reference to a Sense HID device. Keeping the raw
/// IOHIDDevice behind this boundary prevents IOKit references from leaking into
/// the engine and gives lifecycle policy deterministic test doubles.
protocol SenseHIDDeviceHandle: AnyObject, Sendable {
    var transportIdentifier: ObjectIdentifier { get }
}

struct SenseHIDDeviceProperties: Equatable, Sendable {
    let vendorID: Int
    let productID: Int
    let name: String
    let serialNumber: String?
    let physicalDeviceUniqueID: String?
    let locationID: Int
    let registryEntryID: UInt64
}

enum SenseHIDTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case managerCreationFailed
    case managerOpenFailed(Int32)
    case unexpectedDeviceHandle
    case deviceOpenFailed(Int32)
    case deviceCloseFailed(Int32)

    var description: String {
        switch self {
        case .managerCreationFailed:
            return "HID manager creation failed"
        case let .managerOpenFailed(result):
            return "HID manager open failed (IOReturn=\(result))"
        case .unexpectedDeviceHandle:
            return "HID transport received a device or registration from another transport"
        case let .deviceOpenFailed(result):
            return "managed device open failed (IOReturn=\(result))"
        case let .deviceCloseFailed(result):
            return "managed device close failed (IOReturn=\(result))"
        }
    }
}

protocol SenseHIDInputRegistration: AnyObject, Sendable {}

typealias SenseHIDReportHandler = @Sendable (
    _ reportID: UInt32,
    _ report: UnsafeMutablePointer<UInt8>,
    _ length: Int
) -> Void

/// All methods are called on the dedicated Sense HID thread. Implementations
/// must invoke discovery and report callbacks on that same thread.
protocol SenseHIDTransport: AnyObject, Sendable {
    func startDiscovery(
        on runLoop: CFRunLoop,
        deviceConnected: @escaping @Sendable (any SenseHIDDeviceHandle) -> Void,
        deviceDisconnected: @escaping @Sendable (any SenseHIDDeviceHandle) -> Void
    ) -> Result<Void, SenseHIDTransportError>

    func stopDiscovery(on runLoop: CFRunLoop)
    func properties(for device: any SenseHIDDeviceHandle) -> SenseHIDDeviceProperties?

    func openInput(
        for device: any SenseHIDDeviceHandle,
        on runLoop: CFRunLoop,
        reportLength: Int,
        handler: @escaping SenseHIDReportHandler
    ) -> Result<any SenseHIDInputRegistration, SenseHIDTransportError>

    func closeInput(
        _ registration: any SenseHIDInputRegistration
    ) -> Result<Void, SenseHIDTransportError>
}

enum SenseDeviceIdentity {
    /// Prefer identifiers documented as physical and persistent. The location
    /// fallback preserves compatibility with older saved JamCon selections;
    /// the registry entry prevents same-session collisions when location is 0.
    static func identifier(for properties: SenseHIDDeviceProperties) -> String {
        if let serial = normalized(properties.serialNumber) {
            return serial
        }
        if let physicalID = normalized(properties.physicalDeviceUniqueID) {
            return "physical-\(physicalID)"
        }
        if properties.locationID != 0 {
            return "loc-\(properties.locationID)-pid-\(properties.productID)"
        }
        if properties.registryEntryID != 0 {
            return "registry-\(properties.registryEntryID)-pid-\(properties.productID)"
        }
        return "unidentified-pid-\(properties.productID)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

final class IOKitSenseHIDTransport: SenseHIDTransport, @unchecked Sendable {
    private final class DeviceHandle: SenseHIDDeviceHandle, @unchecked Sendable {
        let device: IOHIDDevice

        init(device: IOHIDDevice) {
            self.device = device
        }

        var transportIdentifier: ObjectIdentifier {
            ObjectIdentifier(device)
        }
    }

    private final class InputRegistration: SenseHIDInputRegistration, @unchecked Sendable {
        let device: IOHIDDevice
        let runLoop: CFRunLoop
        let reportBuffer: UnsafeMutablePointer<UInt8>
        let reportLength: Int
        let handler: SenseHIDReportHandler
        var isClosed = false

        init(
            device: IOHIDDevice,
            runLoop: CFRunLoop,
            reportLength: Int,
            handler: @escaping SenseHIDReportHandler
        ) {
            self.device = device
            self.runLoop = runLoop
            self.reportLength = reportLength
            self.handler = handler
            self.reportBuffer = .allocate(capacity: reportLength)
            self.reportBuffer.initialize(repeating: 0, count: reportLength)
        }

        deinit {
            reportBuffer.deinitialize(count: reportLength)
            reportBuffer.deallocate()
        }
    }

    /// These values are confined to the Sense HID thread. The class is marked
    /// unchecked Sendable solely so the thread/run-loop boundary is explicit to
    /// Swift 6; no raw IOKit reference is exposed to another executor.
    private var manager: IOHIDManager?
    private var connectedHandler: (@Sendable (any SenseHIDDeviceHandle) -> Void)?
    private var disconnectedHandler: (@Sendable (any SenseHIDDeviceHandle) -> Void)?
    private var deviceHandles: [ObjectIdentifier: DeviceHandle] = [:]

    func startDiscovery(
        on runLoop: CFRunLoop,
        deviceConnected: @escaping @Sendable (any SenseHIDDeviceHandle) -> Void,
        deviceDisconnected: @escaping @Sendable (any SenseHIDDeviceHandle) -> Void
    ) -> Result<Void, SenseHIDTransportError> {
        if manager != nil {
            return .success(())
        }

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(IOHIDManagerOptions.independentDevices.rawValue)
        )

        self.manager = manager
        connectedHandler = deviceConnected
        disconnectedHandler = deviceDisconnected

        let matchDictionaries: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: SenseHIDProtocol.sonyVendorID,
                kIOHIDProductIDKey as String: SenseHIDProtocol.leftProductID,
            ],
            [
                kIOHIDVendorIDKey as String: SenseHIDProtocol.sonyVendorID,
                kIOHIDProductIDKey as String: SenseHIDProtocol.rightProductID,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchDictionaries as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let transport = Unmanaged<IOKitSenseHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleConnected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let transport = Unmanaged<IOKitSenseHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleDisconnected(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            tearDownDiscovery(manager: manager, runLoop: runLoop)
            return .failure(.managerOpenFailed(result))
        }
        return .success(())
    }

    func stopDiscovery(on runLoop: CFRunLoop) {
        guard let manager else {
            connectedHandler = nil
            disconnectedHandler = nil
            deviceHandles.removeAll(keepingCapacity: true)
            return
        }
        tearDownDiscovery(manager: manager, runLoop: runLoop)
    }

    func properties(for device: any SenseHIDDeviceHandle) -> SenseHIDDeviceProperties? {
        guard let handle = device as? DeviceHandle else { return nil }
        let rawDevice = handle.device

        var registryEntryID: UInt64 = 0
        let service = IOHIDDeviceGetService(rawDevice)
        if service != 0 {
            _ = IORegistryEntryGetRegistryEntryID(service, &registryEntryID)
        }

        return SenseHIDDeviceProperties(
            vendorID: intProperty(kIOHIDVendorIDKey, from: rawDevice),
            productID: intProperty(kIOHIDProductIDKey, from: rawDevice),
            name: stringProperty(kIOHIDProductKey, from: rawDevice) ?? "Unknown",
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: rawDevice),
            physicalDeviceUniqueID: stringProperty(kIOHIDPhysicalDeviceUniqueIDKey, from: rawDevice),
            locationID: intProperty(kIOHIDLocationIDKey, from: rawDevice),
            registryEntryID: registryEntryID
        )
    }

    func openInput(
        for device: any SenseHIDDeviceHandle,
        on runLoop: CFRunLoop,
        reportLength: Int,
        handler: @escaping SenseHIDReportHandler
    ) -> Result<any SenseHIDInputRegistration, SenseHIDTransportError> {
        guard let handle = device as? DeviceHandle else {
            return .failure(.unexpectedDeviceHandle)
        }

        let result = IOHIDDeviceOpen(handle.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            return .failure(.deviceOpenFailed(result))
        }

        let registration = InputRegistration(
            device: handle.device,
            runLoop: runLoop,
            reportLength: reportLength,
            handler: handler
        )
        let context = Unmanaged.passUnretained(registration).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            handle.device,
            registration.reportBuffer,
            registration.reportLength,
            { context, _, _, _, reportID, report, length in
                guard let context else { return }
                let registration = Unmanaged<InputRegistration>.fromOpaque(context).takeUnretainedValue()
                registration.handler(reportID, report, length)
            },
            context
        )
        IOHIDDeviceScheduleWithRunLoop(handle.device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        return .success(registration)
    }

    func closeInput(
        _ registration: any SenseHIDInputRegistration
    ) -> Result<Void, SenseHIDTransportError> {
        guard let registration = registration as? InputRegistration else {
            return .failure(.unexpectedDeviceHandle)
        }
        guard !registration.isClosed else { return .success(()) }
        registration.isClosed = true

        IOHIDDeviceRegisterInputReportCallback(
            registration.device,
            registration.reportBuffer,
            registration.reportLength,
            nil,
            nil
        )
        IOHIDDeviceUnscheduleFromRunLoop(
            registration.device,
            registration.runLoop,
            CFRunLoopMode.defaultMode.rawValue
        )
        let result = IOHIDDeviceClose(registration.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            return .failure(.deviceCloseFailed(result))
        }
        return .success(())
    }

    private func handleConnected(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        let handle: DeviceHandle
        if let existing = deviceHandles[key] {
            handle = existing
        } else {
            handle = DeviceHandle(device: device)
            deviceHandles[key] = handle
        }
        connectedHandler?(handle)
    }

    private func handleDisconnected(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard let handle = deviceHandles.removeValue(forKey: key) else { return }
        disconnectedHandler?(handle)
    }

    private func tearDownDiscovery(manager: IOHIDManager, runLoop: CFRunLoop) {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        connectedHandler = nil
        disconnectedHandler = nil
        deviceHandles.removeAll(keepingCapacity: true)
    }

    private func intProperty(_ key: String, from device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
