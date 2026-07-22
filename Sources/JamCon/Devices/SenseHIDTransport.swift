import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

/// All methods are called on the dedicated Sense HID thread. Implementations
/// must invoke discovery and report callbacks on that same thread.
protocol SenseHIDTransport: HIDTransport {}

final class IOKitSenseHIDTransport: SenseHIDTransport, @unchecked Sendable {
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

    /// These values are confined to the Sense HID thread. The class is marked
    /// unchecked Sendable solely so the thread/run-loop boundary is explicit to
    /// Swift 6; no raw IOKit reference is exposed to another executor.
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
            name: stringProperty(kIOHIDProductKey, from: rawDevice) ?? "Unknown",
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: rawDevice),
            physicalDeviceUniqueID: stringProperty(kIOHIDPhysicalDeviceUniqueIDKey, from: rawDevice),
            locationID: intProperty(kIOHIDLocationIDKey, from: rawDevice),
            registryEntryID: registryEntryID
        )
    }

    func openInput(
        for _: any HIDDeviceHandle,
        on _: CFRunLoop,
        reportLength _: Int,
        handler _: @escaping HIDReportHandler
    ) -> Result<any HIDInputRegistration, HIDTransportError> {
        .failure(
            .unsupportedOperation(
                "Raw Sense input is disabled because opening the HID device terminates its Bluetooth session"
            )
        )
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
