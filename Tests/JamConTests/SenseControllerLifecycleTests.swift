import XCTest
import CoreFoundation
@testable import JamCon

final class SenseControllerLifecycleTests: XCTestCase {
    func testUnmanagedDiscoveryDoesNotOpenDevice() {
        let device = FakeSenseHIDDevice(label: "right")
        let transport = FakeSenseHIDTransport(devices: [device: properties(serial: "sense-right")])
        let controller = SenseController(transport: transport)

        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.controllerInfosSnapshot().map(\.id), ["sense-right"])
        XCTAssertEqual(controller.controllerInfosSnapshot().map(\.handedness), [.right])
        XCTAssertEqual(transport.count(of: .open("right")), 0)

        controller.stop()
        XCTAssertEqual(transport.count(of: .start), 1)
        XCTAssertEqual(transport.count(of: .stop), 1)
    }

    func testManageIsIdempotentAndDoesNotOpenRawInput() {
        let device = FakeSenseHIDDevice(label: "right")
        let transport = FakeSenseHIDTransport(devices: [device: properties(serial: "sense-right")])
        let controller = SenseController(transport: transport)
        let activated = expectation(description: "controller activated")
        let deactivated = expectation(description: "controller deactivated")
        controller.onConnectionChange = { connected, _, _ in
            (connected ? activated : deactivated).fulfill()
        }

        XCTAssertTrue(controller.start())
        controller.setControllerManaged(id: "sense-right", managed: true)
        wait(for: [activated], timeout: 1)

        controller.setControllerManaged(id: "sense-right", managed: true)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .open("right")), 0)

        controller.setControllerManaged(id: "sense-right", managed: false)
        wait(for: [deactivated], timeout: 1)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .close("right")), 0)

        controller.stop()
        XCTAssertEqual(transport.count(of: .close("right")), 0)
    }

    func testRemovalQueuedBeforeActivationCannotOpenStaleDevice() {
        let device = FakeSenseHIDDevice(label: "right")
        let transport = FakeSenseHIDTransport(devices: [device: properties(serial: "sense-right")])
        let controller = SenseController(transport: transport)
        let controllerListChanged = expectation(description: "discovery and removal")
        controllerListChanged.expectedFulfillmentCount = 2
        controller.onControllersChanged = {
            controllerListChanged.fulfill()
        }

        XCTAssertTrue(controller.start())
        transport.disconnect(device)
        controller.setControllerManaged(id: "sense-right", managed: true)

        wait(for: [controllerListChanged], timeout: 1)
        XCTAssertTrue(transport.flush())
        XCTAssertTrue(controller.controllerInfosSnapshot().isEmpty)
        XCTAssertEqual(transport.count(of: .open("right")), 0)
        controller.stop()
    }

    func testStartupFailureLeavesControllerStoppedAndRetryable() {
        let transport = FakeSenseHIDTransport(
            devices: [:],
            startResults: [
                .failure(.managerOpenFailed(-1)),
                .success(()),
            ]
        )
        let controller = SenseController(transport: transport)

        XCTAssertFalse(controller.start())
        XCTAssertTrue(controller.start())
        controller.stop()

        XCTAssertEqual(transport.count(of: .start), 2)
        XCTAssertEqual(transport.count(of: .stop), 2)
    }

    func testManagedSelectionSurvivesStopStartCycle() {
        let device = FakeSenseHIDDevice(label: "right")
        let transport = FakeSenseHIDTransport(devices: [device: properties(serial: "sense-right")])
        let controller = SenseController(transport: transport)
        let activated = expectation(description: "activated across both starts")
        activated.expectedFulfillmentCount = 2
        controller.onConnectionChange = { connected, _, _ in
            if connected { activated.fulfill() }
        }

        XCTAssertTrue(controller.start())
        controller.setControllerManaged(id: "sense-right", managed: true)
        XCTAssertTrue(transport.flush())
        controller.stop()

        XCTAssertTrue(controller.start())
        wait(for: [activated], timeout: 1)
        controller.stop()

        XCTAssertEqual(transport.count(of: .start), 2)
        XCTAssertEqual(transport.count(of: .open("right")), 0)
        XCTAssertEqual(transport.count(of: .close("right")), 0)
        XCTAssertEqual(transport.count(of: .stop), 2)
    }

    func testSenseBackendOwnsNativeSessionAndEmitsCommonFramesWithStableIdentity() {
        let device = FakeSenseHIDDevice(label: "right")
        let transport = FakeSenseHIDTransport(devices: [device: properties(serial: "sense-right")])
        let discovery = SenseController(transport: transport)
        let nativeSession = FakeSenseGameControllerSession()
        let backend = SenseInputDeviceBackend(
            discovery: discovery,
            gameControllerSession: nativeSession
        )
        let connected = expectation(description: "native input ready")
        let inputReceived = expectation(description: "common input frame")
        let receivedFrame = LockedSenseTestValue<InputDeviceFrame?>(nil)
        let harness = InputDeviceBackendContractHarness(
            backend: backend,
            connectionObserver: { event in
                if event.connected, event.deviceID == "sense-right" {
                    connected.fulfill()
                }
            },
            inputObserver: { frame in
                receivedFrame.set(frame)
                inputReceived.fulfill()
            }
        )

        XCTAssertTrue(harness.start())
        XCTAssertTrue(harness.setDeviceManaged(id: "sense-right", kind: .sense, managed: true))
        nativeSession.emitConnection(
            connected: true,
            device: SenseGameControllerDevice(
                name: "PlayStation VR2 Sense Controller (R)",
                isLeft: false
            )
        )
        wait(for: [connected], timeout: 1)
        XCTAssertTrue(backend.isConnected)

        var bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        bytes[0] = UInt8(SenseHIDProtocol.inputReportID)
        nativeSession.emitFrame(SenseGameControllerInputFrame(
            device: SenseGameControllerDevice(
                name: "PlayStation VR2 Sense Controller (R)",
                isLeft: false
            ),
            bytes: bytes,
            gyroX: 11,
            gyroY: 22,
            gyroZ: 33,
            accelX: 44,
            accelY: 55,
            accelZ: 66,
            timestamp: 100
        ))
        wait(for: [inputReceived], timeout: 1)

        let frame = receivedFrame.get()
        XCTAssertEqual(frame?.backend, backend.backendDescriptor)
        XCTAssertEqual(frame?.deviceID, "sense-right")
        XCTAssertEqual(frame?.reportID, SenseHIDProtocol.inputReportID)
        XCTAssertEqual(frame?.motion.latest, IMUSample(
            accelX: 44,
            accelY: 55,
            accelZ: 66,
            gyroX: 11,
            gyroY: 22,
            gyroZ: 33
        ))

        harness.stop()
        XCTAssertEqual(nativeSession.startCount, 1)
        XCTAssertEqual(nativeSession.stopCount, 1)
        XCTAssertFalse(backend.isConnected)
    }

    func testDeviceIdentityPrefersExistingSerialFormat() {
        let deviceProperties = properties(
            serial: " 88:03:4C:18:C4:E5 ",
            physicalID: "physical-id",
            locationID: 42,
            registryEntryID: 99
        )

        XCTAssertEqual(HIDDeviceIdentity.identifier(for: deviceProperties), "88:03:4C:18:C4:E5")
    }

    func testDeviceIdentityUsesPhysicalIDBeforeTransientLocation() {
        let deviceProperties = properties(
            serial: nil,
            physicalID: "Bluetooth:controller-1",
            locationID: 42,
            registryEntryID: 99
        )

        XCTAssertEqual(
            HIDDeviceIdentity.identifier(for: deviceProperties),
            "physical-Bluetooth:controller-1"
        )
    }

    func testDeviceIdentityAvoidsZeroLocationCollisionWithinSession() {
        let first = properties(serial: nil, locationID: 0, registryEntryID: 101)
        let second = properties(serial: nil, locationID: 0, registryEntryID: 202)

        XCTAssertNotEqual(
            HIDDeviceIdentity.identifier(for: first),
            HIDDeviceIdentity.identifier(for: second)
        )
    }

    private func properties(
        serial: String?,
        physicalID: String? = nil,
        locationID: Int = 12,
        registryEntryID: UInt64 = 34
    ) -> HIDDeviceProperties {
        HIDDeviceProperties(
            vendorID: SenseHIDProtocol.sonyVendorID,
            productID: SenseHIDProtocol.rightProductID,
            name: "PlayStation VR2 Sense Controller (R)",
            serialNumber: serial,
            physicalDeviceUniqueID: physicalID,
            locationID: locationID,
            registryEntryID: registryEntryID
        )
    }
}

private final class FakeSenseGameControllerSession: SenseGameControllerSessioning, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers = SenseGameControllerSessionHandlers.none
    private var starts = 0
    private var stops = 0

    var startCount: Int { locked { starts } }
    var stopCount: Int { locked { stops } }

    func setEventHandlers(_ handlers: SenseGameControllerSessionHandlers) {
        locked { self.handlers = handlers }
    }

    func start() {
        locked { starts += 1 }
    }

    func stop() {
        locked { stops += 1 }
    }

    func emitConnection(connected: Bool, device: SenseGameControllerDevice) {
        locked { handlers }.connectionChanged(connected, device)
    }

    func emitFrame(_ frame: SenseGameControllerInputFrame) {
        locked { handlers }.inputFrame(frame)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedSenseTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class FakeSenseHIDDevice: HIDDeviceHandle, @unchecked Sendable, Hashable {
    let label: String

    init(label: String) {
        self.label = label
    }

    var transportIdentifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    static func == (lhs: FakeSenseHIDDevice, rhs: FakeSenseHIDDevice) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

private final class FakeSenseHIDInputRegistration: HIDInputRegistration, @unchecked Sendable {
    let deviceLabel: String

    init(deviceLabel: String) {
        self.deviceLabel = deviceLabel
    }
}

private final class FakeSenseHIDTransport: SenseHIDTransport, @unchecked Sendable {
    enum Event: Equatable {
        case start
        case stop
        case open(String)
        case close(String)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var startResults: [Result<Void, HIDTransportError>]
    private var runLoop: CFRunLoop?
    private var connectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var disconnectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private let devices: [(device: FakeSenseHIDDevice, properties: HIDDeviceProperties)]

    init(
        devices: [FakeSenseHIDDevice: HIDDeviceProperties],
        startResults: [Result<Void, HIDTransportError>] = [.success(())]
    ) {
        self.devices = devices.map { (device: $0.key, properties: $0.value) }
        self.startResults = startResults
    }

    func startDiscovery(
        on runLoop: CFRunLoop,
        deviceConnected: @escaping @Sendable (any HIDDeviceHandle) -> Void,
        deviceDisconnected: @escaping @Sendable (any HIDDeviceHandle) -> Void
    ) -> Result<Void, HIDTransportError> {
        lock.lock()
        events.append(.start)
        self.runLoop = runLoop
        connectedHandler = deviceConnected
        disconnectedHandler = deviceDisconnected
        let result = startResults.isEmpty ? .success(()) : startResults.removeFirst()
        let initialDevices = devices.map(\.device)
        lock.unlock()

        if case .success = result {
            for device in initialDevices {
                deviceConnected(device)
            }
        }
        return result
    }

    func stopDiscovery(on _: CFRunLoop) {
        lock.lock()
        events.append(.stop)
        connectedHandler = nil
        disconnectedHandler = nil
        runLoop = nil
        lock.unlock()
    }

    func properties(for device: any HIDDeviceHandle) -> HIDDeviceProperties? {
        guard let device = device as? FakeSenseHIDDevice else { return nil }
        return devices.first(where: { $0.device === device })?.properties
    }

    func openInput(
        for device: any HIDDeviceHandle,
        on _: CFRunLoop,
        reportLength _: Int,
        handler _: @escaping HIDReportHandler
    ) -> Result<any HIDInputRegistration, HIDTransportError> {
        guard let device = device as? FakeSenseHIDDevice else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        events.append(.open(device.label))
        lock.unlock()
        return .success(FakeSenseHIDInputRegistration(deviceLabel: device.label))
    }

    func closeInput(
        _ registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError> {
        guard let registration = registration as? FakeSenseHIDInputRegistration else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        events.append(.close(registration.deviceLabel))
        lock.unlock()
        return .success(())
    }

    func disconnect(_ device: FakeSenseHIDDevice) {
        guard let targetRunLoop = locked({ runLoop }) else {
            XCTFail("Fake transport is not running")
            return
        }
        CFRunLoopPerformBlock(targetRunLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            let handler = self.locked { self.disconnectedHandler }
            handler?(device)
        }
        CFRunLoopWakeUp(targetRunLoop)
    }

    func flush(timeout: TimeInterval = 1) -> Bool {
        guard let targetRunLoop = locked({ runLoop }) else { return false }
        let completed = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(targetRunLoop, CFRunLoopMode.defaultMode.rawValue) {
            completed.signal()
        }
        CFRunLoopWakeUp(targetRunLoop)
        return completed.wait(timeout: .now() + timeout) == .success
    }

    func count(of event: Event) -> Int {
        locked { events.filter { $0 == event }.count }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
