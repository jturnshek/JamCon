import CoreFoundation
import XCTest
@testable import JamCon

final class JoyConControllerLifecycleTests: XCTestCase {
    func testUnmanagedDiscoveryDoesNotOpenOrConfigureDevice() {
        let device = FakeJoyConHIDDevice(label: "right")
        let transport = FakeJoyConHIDTransport(devices: [device: properties(serial: "joy-right")])
        let controller = JoyConHIDController(transport: transport)

        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.controllerInfosSnapshot().map(\.id), ["joy-right"])
        XCTAssertEqual(transport.count(of: .open("right")), 0)
        XCTAssertTrue(transport.outputReports.isEmpty)

        controller.stop()
        XCTAssertEqual(transport.count(of: .start), 1)
        XCTAssertEqual(transport.count(of: .stop), 1)
    }

    func testManageIsIdempotentConfiguresDeviceAndUnmanageClosesExactlyOnce() {
        let device = FakeJoyConHIDDevice(label: "right")
        let transport = FakeJoyConHIDTransport(devices: [device: properties(serial: "joy-right")])
        let controller = JoyConHIDController(transport: transport)
        let activated = expectation(description: "controller activated")
        let deactivated = expectation(description: "controller deactivated")
        controller.onConnectionChange = { connected, _, _ in
            (connected ? activated : deactivated).fulfill()
        }

        XCTAssertTrue(controller.start())
        controller.setControllerManaged(id: "joy-right", managed: true)
        wait(for: [activated], timeout: 1)

        controller.setControllerManaged(id: "joy-right", managed: true)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .open("right")), 1)

        let outputReports = transport.outputReports
        XCTAssertEqual(outputReports.count, 4)
        XCTAssertEqual(outputReports.map(\.reportID), [0x01, 0x01, 0x01, 0x01])
        XCTAssertEqual(outputReports.map { $0.data[0] }, [0x01, 0x01, 0x01, 0x01])
        XCTAssertEqual(outputReports.map { $0.data[1] }, [0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(outputReports.map { $0.data[10] }, [0x40, 0x03, 0x48, 0x30])
        XCTAssertEqual(outputReports.map { $0.data[11] }, [0x01, 0x30, 0x01, 0x01])

        controller.setControllerManaged(id: "joy-right", managed: false)
        wait(for: [deactivated], timeout: 1)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .close("right")), 1)

        controller.stop()
        XCTAssertEqual(transport.count(of: .close("right")), 1)
    }

    func testRemovalQueuedBeforeActivationCannotOpenStaleDevice() {
        let device = FakeJoyConHIDDevice(label: "right")
        let transport = FakeJoyConHIDTransport(devices: [device: properties(serial: "joy-right")])
        let controller = JoyConHIDController(transport: transport)
        let controllerListChanged = expectation(description: "discovery and removal")
        controllerListChanged.expectedFulfillmentCount = 2
        controller.onControllersChanged = {
            controllerListChanged.fulfill()
        }

        XCTAssertTrue(controller.start())
        transport.disconnect(device)
        controller.setControllerManaged(id: "joy-right", managed: true)

        wait(for: [controllerListChanged], timeout: 1)
        XCTAssertTrue(transport.flush())
        XCTAssertTrue(controller.controllerInfosSnapshot().isEmpty)
        XCTAssertEqual(transport.count(of: .open("right")), 0)
        XCTAssertTrue(transport.outputReports.isEmpty)
        controller.stop()
    }

    func testOpenFailureDoesNotConfigureOrPublishConnection() {
        let device = FakeJoyConHIDDevice(label: "right")
        let transport = FakeJoyConHIDTransport(
            devices: [device: properties(serial: "joy-right")],
            openResults: [.failure(.deviceOpenFailed(-1))]
        )
        let controller = JoyConHIDController(transport: transport)
        var connectionCallbackCount = 0
        controller.onConnectionChange = { _, _, _ in
            connectionCallbackCount += 1
        }

        XCTAssertTrue(controller.start())
        controller.setControllerManaged(id: "joy-right", managed: true)
        XCTAssertTrue(transport.flush())

        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(connectionCallbackCount, 0)
        XCTAssertEqual(transport.count(of: .open("right")), 1)
        XCTAssertEqual(transport.count(of: .close("right")), 0)
        XCTAssertTrue(transport.outputReports.isEmpty)
        controller.stop()
    }

    func testManagingOneOfTwoControllersDoesNotOpenTheOther() {
        let left = FakeJoyConHIDDevice(label: "left")
        let right = FakeJoyConHIDDevice(label: "right")
        let transport = FakeJoyConHIDTransport(devices: [
            left: properties(
                serial: "joy-left",
                productID: JoyConHIDProtocol.leftProductID,
                name: "Joy-Con (L)"
            ),
            right: properties(serial: "joy-right"),
        ])
        let controller = JoyConHIDController(transport: transport)

        XCTAssertTrue(controller.start())
        controller.setControllerManaged(id: "joy-right", managed: true)
        XCTAssertTrue(transport.flush())

        XCTAssertEqual(transport.count(of: .open("right")), 1)
        XCTAssertEqual(transport.count(of: .open("left")), 0)
        XCTAssertEqual(Set(transport.outputReports.map(\.deviceLabel)), ["right"])

        controller.setControllerManaged(id: "joy-left", managed: true)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .open("left")), 1)
        XCTAssertEqual(transport.outputReports.filter { $0.deviceLabel == "left" }.count, 4)

        controller.setControllerManaged(id: "joy-right", managed: false)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .close("right")), 1)
        XCTAssertEqual(transport.count(of: .close("left")), 0)

        controller.stop()
        XCTAssertEqual(transport.count(of: .close("right")), 1)
        XCTAssertEqual(transport.count(of: .close("left")), 1)
    }

    func testStartupFailureLeavesControllerStoppedAndRetryable() {
        let transport = FakeJoyConHIDTransport(
            devices: [:],
            startResults: [
                .failure(.managerOpenFailed(-1)),
                .success(()),
            ]
        )
        let controller = JoyConHIDController(transport: transport)

        XCTAssertFalse(controller.start())
        XCTAssertTrue(controller.start())
        controller.stop()

        XCTAssertEqual(transport.count(of: .start), 2)
        XCTAssertEqual(transport.count(of: .stop), 2)
    }

    func testManagedSelectionSurvivesStopStartCycle() {
        let device = FakeJoyConHIDDevice(label: "right")
        let transport = FakeJoyConHIDTransport(devices: [device: properties(serial: "joy-right")])
        let controller = JoyConHIDController(transport: transport)
        let activated = expectation(description: "activated across both starts")
        activated.expectedFulfillmentCount = 2
        controller.onConnectionChange = { connected, _, _ in
            if connected { activated.fulfill() }
        }

        XCTAssertTrue(controller.start())
        controller.setControllerManaged(id: "joy-right", managed: true)
        XCTAssertTrue(transport.flush())
        controller.stop()

        XCTAssertTrue(controller.start())
        wait(for: [activated], timeout: 1)
        controller.stop()

        XCTAssertEqual(transport.count(of: .start), 2)
        XCTAssertEqual(transport.count(of: .open("right")), 2)
        XCTAssertEqual(transport.count(of: .close("right")), 2)
        XCTAssertEqual(transport.count(of: .stop), 2)
        XCTAssertEqual(transport.outputReports.count, 8)
    }

    private func properties(
        serial: String?,
        productID: Int = JoyConHIDProtocol.rightProductID,
        name: String = "Joy-Con (R)"
    ) -> HIDDeviceProperties {
        HIDDeviceProperties(
            vendorID: JoyConHIDProtocol.nintendoVendorID,
            productID: productID,
            name: name,
            serialNumber: serial,
            physicalDeviceUniqueID: nil,
            locationID: 12,
            registryEntryID: 34
        )
    }
}

private final class FakeJoyConHIDDevice: HIDDeviceHandle, @unchecked Sendable, Hashable {
    let label: String

    init(label: String) {
        self.label = label
    }

    var transportIdentifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    static func == (lhs: FakeJoyConHIDDevice, rhs: FakeJoyConHIDDevice) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

private final class FakeJoyConHIDInputRegistration: HIDInputRegistration, @unchecked Sendable {
    let deviceLabel: String

    init(deviceLabel: String) {
        self.deviceLabel = deviceLabel
    }
}

private final class FakeJoyConHIDTransport: JoyConHIDTransport, @unchecked Sendable {
    enum Event: Equatable {
        case start
        case stop
        case open(String)
        case close(String)
    }

    struct OutputReport: Equatable {
        let deviceLabel: String
        let reportID: UInt8
        let data: [UInt8]
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var recordedOutputReports: [OutputReport] = []
    private var startResults: [Result<Void, HIDTransportError>]
    private var openResults: [Result<Void, HIDTransportError>]
    private var runLoop: CFRunLoop?
    private var connectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var disconnectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private let devices: [(device: FakeJoyConHIDDevice, properties: HIDDeviceProperties)]

    init(
        devices: [FakeJoyConHIDDevice: HIDDeviceProperties],
        startResults: [Result<Void, HIDTransportError>] = [.success(())],
        openResults: [Result<Void, HIDTransportError>] = []
    ) {
        self.devices = devices.map { (device: $0.key, properties: $0.value) }
        self.startResults = startResults
        self.openResults = openResults
    }

    var outputReports: [OutputReport] {
        locked { recordedOutputReports }
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
        guard let device = device as? FakeJoyConHIDDevice else { return nil }
        return devices.first(where: { $0.device === device })?.properties
    }

    func openInput(
        for device: any HIDDeviceHandle,
        on _: CFRunLoop,
        reportLength _: Int,
        handler _: @escaping HIDReportHandler
    ) -> Result<any HIDInputRegistration, HIDTransportError> {
        guard let device = device as? FakeJoyConHIDDevice else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        events.append(.open(device.label))
        let result = openResults.isEmpty ? .success(()) : openResults.removeFirst()
        lock.unlock()

        switch result {
        case .success:
            return .success(FakeJoyConHIDInputRegistration(deviceLabel: device.label))
        case let .failure(error):
            return .failure(error)
        }
    }

    func closeInput(
        _ registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError> {
        guard let registration = registration as? FakeJoyConHIDInputRegistration else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        events.append(.close(registration.deviceLabel))
        lock.unlock()
        return .success(())
    }

    func sendOutputReport(
        _ data: [UInt8],
        reportID: UInt8,
        using registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError> {
        guard let registration = registration as? FakeJoyConHIDInputRegistration else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        recordedOutputReports.append(OutputReport(
            deviceLabel: registration.deviceLabel,
            reportID: reportID,
            data: data
        ))
        lock.unlock()
        return .success(())
    }

    func disconnect(_ device: FakeJoyConHIDDevice) {
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
