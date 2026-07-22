import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

struct G502XHIDInterfaceProperties: Equatable, Sendable {
    let device: HIDDeviceProperties
    let usagePage: Int
    let usage: Int
    let maximumInputReportSize: Int
    let reportDescriptorSize: Int
}

enum HIDSetReportType: Sendable {
    case feature
    case output
}

protocol G502XHIDTransport: HIDTransport {
    func interfaceProperties(
        for device: any HIDDeviceHandle
    ) -> G502XHIDInterfaceProperties?

    func sendReport(
        _ data: [UInt8],
        reportID: UInt8,
        type: HIDSetReportType,
        to device: any HIDDeviceHandle
    ) -> Result<Void, HIDTransportError>
}

enum G502XDeviceIdentity {
    /// Preserve the established location-based ID for existing saved
    /// selections. The low byte identifies a USB interface and is masked out.
    static func identifier(for properties: HIDDeviceProperties) -> String {
        let physicalLocation = properties.locationID & 0xFFFF_FF00
        if physicalLocation != 0 {
            return "loc-\(String(format: "%08X", physicalLocation))-pid-\(properties.productID)"
        }
        return HIDDeviceIdentity.identifier(for: properties)
    }
}

/// Direct IOKit implementation for Logitech multi-interface devices. Raw
/// devices, run-loop scheduling, and callback buffers never escape this type.
final class IOKitG502XHIDTransport: G502XHIDTransport, @unchecked Sendable {
    private final class DeviceHandle: HIDDeviceHandle, @unchecked Sendable {
        let device: IOHIDDevice

        init(device: IOHIDDevice) {
            self.device = device
        }

        var transportIdentifier: ObjectIdentifier {
            ObjectIdentifier(device)
        }
    }

    private final class InputRegistration: HIDInputRegistration, @unchecked Sendable {
        let device: IOHIDDevice
        let runLoop: CFRunLoop
        let reportBuffer: UnsafeMutablePointer<UInt8>
        let reportLength: Int
        let handler: HIDReportHandler
        var isClosed = false

        init(
            device: IOHIDDevice,
            runLoop: CFRunLoop,
            reportLength: Int,
            handler: @escaping HIDReportHandler
        ) {
            self.device = device
            self.runLoop = runLoop
            self.reportLength = reportLength
            self.handler = handler
            reportBuffer = .allocate(capacity: reportLength)
            reportBuffer.initialize(repeating: 0, count: reportLength)
        }

        deinit {
            reportBuffer.deinitialize(count: reportLength)
            reportBuffer.deallocate()
        }
    }

    /// Confined to the dedicated G502 HID thread.
    private var manager: IOHIDManager?
    private var connectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var disconnectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var deviceHandles: [ObjectIdentifier: DeviceHandle] = [:]

    func startDiscovery(
        on runLoop: CFRunLoop,
        deviceConnected: @escaping @Sendable (any HIDDeviceHandle) -> Void,
        deviceDisconnected: @escaping @Sendable (any HIDDeviceHandle) -> Void
    ) -> Result<Void, HIDTransportError> {
        if manager != nil { return .success(()) }

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(IOHIDManagerOptions.independentDevices.rawValue)
        )
        self.manager = manager
        connectedHandler = deviceConnected
        disconnectedHandler = deviceDisconnected

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: G502XHIDProtocol.logitechVendorID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let transport = Unmanaged<IOKitG502XHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleConnected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let transport = Unmanaged<IOKitG502XHIDTransport>.fromOpaque(context).takeUnretainedValue()
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

    func properties(for device: any HIDDeviceHandle) -> HIDDeviceProperties? {
        interfaceProperties(for: device)?.device
    }

    func interfaceProperties(
        for device: any HIDDeviceHandle
    ) -> G502XHIDInterfaceProperties? {
        guard let handle = device as? DeviceHandle else { return nil }
        let rawDevice = handle.device

        var registryEntryID: UInt64 = 0
        let service = IOHIDDeviceGetService(rawDevice)
        if service != 0 {
            _ = IORegistryEntryGetRegistryEntryID(service, &registryEntryID)
        }

        let base = HIDDeviceProperties(
            vendorID: intProperty(kIOHIDVendorIDKey, from: rawDevice),
            productID: intProperty(kIOHIDProductIDKey, from: rawDevice),
            name: stringProperty(kIOHIDProductKey, from: rawDevice) ?? "Unknown",
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: rawDevice),
            physicalDeviceUniqueID: stringProperty(kIOHIDPhysicalDeviceUniqueIDKey, from: rawDevice),
            locationID: intProperty(kIOHIDLocationIDKey, from: rawDevice),
            registryEntryID: registryEntryID
        )
        let descriptor = IOHIDDeviceGetProperty(rawDevice, kIOHIDReportDescriptorKey as CFString) as? Data
        return G502XHIDInterfaceProperties(
            device: base,
            usagePage: intProperty(kIOHIDPrimaryUsagePageKey, from: rawDevice),
            usage: intProperty(kIOHIDPrimaryUsageKey, from: rawDevice),
            maximumInputReportSize: intProperty(kIOHIDMaxInputReportSizeKey, from: rawDevice),
            reportDescriptorSize: descriptor?.count ?? 0
        )
    }

    func openInput(
        for device: any HIDDeviceHandle,
        on runLoop: CFRunLoop,
        reportLength: Int,
        handler: @escaping HIDReportHandler
    ) -> Result<any HIDInputRegistration, HIDTransportError> {
        guard let handle = device as? DeviceHandle else {
            return .failure(.unexpectedHandle)
        }
        guard reportLength > 0 else {
            return .failure(.deviceOpenFailed(kIOReturnBadArgument))
        }

        let result = IOHIDDeviceOpen(handle.device, IOOptionBits(kIOHIDOptionsTypeNone))
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
        _ registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError> {
        guard let registration = registration as? InputRegistration else {
            return .failure(.unexpectedHandle)
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

    func sendReport(
        _ data: [UInt8],
        reportID: UInt8,
        type: HIDSetReportType,
        to device: any HIDDeviceHandle
    ) -> Result<Void, HIDTransportError> {
        guard let handle = device as? DeviceHandle else {
            return .failure(.unexpectedHandle)
        }
        guard !data.isEmpty else {
            return .failure(.outputReportFailed(kIOReturnBadArgument))
        }
        let ioType: IOHIDReportType = switch type {
        case .feature: kIOHIDReportTypeFeature
        case .output: kIOHIDReportTypeOutput
        }
        let result = data.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                handle.device,
                ioType,
                CFIndex(reportID),
                buffer.baseAddress!,
                buffer.count
            )
        }
        guard result == kIOReturnSuccess else {
            return .failure(.outputReportFailed(result))
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
