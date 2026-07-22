import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

/// Low-level Joy-Con I/O. Lifecycle policy remains in JoyConHIDController;
/// this boundary owns all raw IOKit references and callback buffers.
protocol JoyConHIDTransport: HIDTransport {
    func sendOutputReport(
        _ data: [UInt8],
        reportID: UInt8,
        using registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError>
}

final class IOKitJoyConHIDTransport: JoyConHIDTransport, @unchecked Sendable {
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
            self.reportBuffer = .allocate(capacity: reportLength)
            self.reportBuffer.initialize(repeating: 0, count: reportLength)
        }

        deinit {
            reportBuffer.deinitialize(count: reportLength)
            reportBuffer.deallocate()
        }
    }

    /// Confined to the dedicated Joy-Con HID thread.
    private var manager: IOHIDManager?
    private var connectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var disconnectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var deviceHandles: [ObjectIdentifier: DeviceHandle] = [:]

    func startDiscovery(
        on runLoop: CFRunLoop,
        deviceConnected: @escaping @Sendable (any HIDDeviceHandle) -> Void,
        deviceDisconnected: @escaping @Sendable (any HIDDeviceHandle) -> Void
    ) -> Result<Void, HIDTransportError> {
        if manager != nil {
            return .success(())
        }

        // Independent-device mode keeps discovery from implicitly opening or
        // scheduling every enumerated Joy-Con. Only managed devices are seized.
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(IOHIDManagerOptions.independentDevices.rawValue)
        )
        self.manager = manager
        connectedHandler = deviceConnected
        disconnectedHandler = deviceDisconnected

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDictionaries() as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let transport = Unmanaged<IOKitJoyConHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleConnected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let transport = Unmanaged<IOKitJoyConHIDTransport>.fromOpaque(context).takeUnretainedValue()
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
        guard let handle = device as? DeviceHandle else { return nil }
        let rawDevice = handle.device

        var registryEntryID: UInt64 = 0
        let service = IOHIDDeviceGetService(rawDevice)
        if service != 0 {
            _ = IORegistryEntryGetRegistryEntryID(service, &registryEntryID)
        }

        return HIDDeviceProperties(
            vendorID: intProperty(kIOHIDVendorIDKey, from: rawDevice),
            productID: intProperty(kIOHIDProductIDKey, from: rawDevice),
            name: stringProperty(kIOHIDProductKey, from: rawDevice) ?? "Joy-Con",
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: rawDevice),
            physicalDeviceUniqueID: stringProperty(kIOHIDPhysicalDeviceUniqueIDKey, from: rawDevice),
            locationID: intProperty(kIOHIDLocationIDKey, from: rawDevice),
            registryEntryID: registryEntryID
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

    func sendOutputReport(
        _ data: [UInt8],
        reportID: UInt8,
        using registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError> {
        guard let registration = registration as? InputRegistration,
              !registration.isClosed else {
            return .failure(.unexpectedHandle)
        }
        guard !data.isEmpty else {
            return .failure(.outputReportFailed(kIOReturnBadArgument))
        }

        let result = data.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                registration.device,
                kIOHIDReportTypeOutput,
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

    private func matchingDictionaries() -> [[String: Any]] {
        let usages: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick,
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad,
            ],
        ]

        var dictionaries: [[String: Any]] = []
        for usage in usages {
            for productID in [JoyConHIDProtocol.leftProductID, JoyConHIDProtocol.rightProductID] {
                dictionaries.append(usage.merging([
                    kIOHIDVendorIDKey as String: JoyConHIDProtocol.nintendoVendorID,
                    kIOHIDProductIDKey as String: productID,
                ], uniquingKeysWith: { _, new in new }))
            }
        }
        for productID in [JoyConHIDProtocol.leftProductID, JoyConHIDProtocol.rightProductID] {
            dictionaries.append([
                kIOHIDVendorIDKey as String: JoyConHIDProtocol.nintendoVendorID,
                kIOHIDProductIDKey as String: productID,
            ])
        }
        return dictionaries
    }

    private func intProperty(_ key: String, from device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
