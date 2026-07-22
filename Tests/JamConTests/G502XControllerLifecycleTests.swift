import CoreFoundation
import XCTest
@testable import JamCon

final class G502XControllerLifecycleTests: XCTestCase {
    private let mouseID = "loc-12340000-pid-\(G502XHIDProtocol.lightspeedReceiverProductID)"

    func testUnselectedDiscoveryDoesNotOpenInterfaces() {
        let mouse = FakeG502XHIDDevice(label: "mouse")
        let transport = FakeG502XHIDTransport(devices: [mouse: properties(locationID: 0x1234_0001)])
        let controller = G502XHIDController(transport: transport)

        XCTAssertTrue(controller.start())
        XCTAssertEqual(controller.mouseInfosSnapshot().map(\.id), [mouseID])
        XCTAssertEqual(transport.count(of: .open("mouse")), 0)
        XCTAssertFalse(controller.isConnected)

        controller.stop()
        XCTAssertEqual(transport.count(of: .start), 1)
        XCTAssertEqual(transport.count(of: .stop), 1)
    }

    func testSelectionGroupsPhysicalInterfacesAndSkipsInterfacesWithoutInput() {
        let mouse = FakeG502XHIDDevice(label: "mouse")
        let keyboard = FakeG502XHIDDevice(label: "keyboard")
        let outputOnly = FakeG502XHIDDevice(label: "output-only")
        let transport = FakeG502XHIDTransport(devices: [
            mouse: properties(locationID: 0x1234_0001, usage: 0x02),
            keyboard: properties(locationID: 0x1234_0002, usage: 0x06),
            outputOnly: properties(locationID: 0x1234_0003, usage: 0x00, maximumInputReportSize: 0),
        ])
        let controller = G502XHIDController(transport: transport)
        controller.selectMouse(id: mouseID)

        XCTAssertTrue(controller.start())
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(controller.selectedMouseID, mouseID)
        XCTAssertEqual(controller.mouseInfosSnapshot().count, 1)
        XCTAssertEqual(transport.count(of: .open("mouse")), 1)
        XCTAssertEqual(transport.count(of: .open("keyboard")), 1)
        XCTAssertEqual(transport.count(of: .open("output-only")), 0)

        controller.selectMouse(id: mouseID)
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .open("mouse")), 1)
        XCTAssertEqual(transport.count(of: .open("keyboard")), 1)

        controller.deselectMouse()
        XCTAssertTrue(transport.flush())
        XCTAssertEqual(transport.count(of: .close("mouse")), 1)
        XCTAssertEqual(transport.count(of: .close("keyboard")), 1)
        XCTAssertNil(controller.selectedMouseID)

        controller.stop()
        XCTAssertEqual(transport.count(of: .close("mouse")), 1)
        XCTAssertEqual(transport.count(of: .close("keyboard")), 1)
    }

    func testSelectingOnePhysicalMouseDoesNotOpenAnother() {
        let first = FakeG502XHIDDevice(label: "first")
        let second = FakeG502XHIDDevice(label: "second")
        let transport = FakeG502XHIDTransport(devices: [
            first: properties(locationID: 0x1234_0001),
            second: properties(locationID: 0x5678_0001),
        ])
        let controller = G502XHIDController(transport: transport)
        controller.selectMouse(id: mouseID)

        XCTAssertTrue(controller.start())
        XCTAssertEqual(transport.count(of: .open("first")), 1)
        XCTAssertEqual(transport.count(of: .open("second")), 0)
        controller.stop()
    }

    func testSelectionSurvivesStopStartCycle() {
        let mouse = FakeG502XHIDDevice(label: "mouse")
        let transport = FakeG502XHIDTransport(devices: [mouse: properties(locationID: 0x1234_0001)])
        let controller = G502XHIDController(transport: transport)
        controller.selectMouse(id: mouseID)

        XCTAssertTrue(controller.start())
        controller.stop()
        XCTAssertEqual(controller.selectedMouseID, mouseID)

        XCTAssertTrue(controller.start())
        controller.stop()

        XCTAssertEqual(transport.count(of: .start), 2)
        XCTAssertEqual(transport.count(of: .open("mouse")), 2)
        XCTAssertEqual(transport.count(of: .close("mouse")), 2)
        XCTAssertEqual(transport.count(of: .stop), 2)
    }

    func testStartupFailureIsRetryable() {
        let transport = FakeG502XHIDTransport(
            devices: [:],
            startResults: [.failure(.managerOpenFailed(-1)), .success(())]
        )
        let controller = G502XHIDController(transport: transport)

        XCTAssertFalse(controller.start())
        XCTAssertTrue(controller.start())
        controller.stop()

        XCTAssertEqual(transport.count(of: .start), 2)
        XCTAssertEqual(transport.count(of: .stop), 2)
    }

    func testOpenFailureDoesNotPublishConnectedState() {
        let mouse = FakeG502XHIDDevice(label: "mouse")
        let transport = FakeG502XHIDTransport(
            devices: [mouse: properties(locationID: 0x1234_0001)],
            openResults: [.failure(.deviceOpenFailed(-1))]
        )
        let controller = G502XHIDController(transport: transport)
        controller.selectMouse(id: mouseID)
        let connection = expectation(description: "no connection callback")
        connection.isInverted = true
        controller.onConnectionChange = { _, _, _ in connection.fulfill() }

        XCTAssertTrue(controller.start())
        wait(for: [connection], timeout: 0.05)
        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(transport.count(of: .open("mouse")), 1)
        XCTAssertEqual(transport.count(of: .close("mouse")), 0)
        controller.stop()
    }

    func testSelectedMouseReconnectRestoresConnectionAndReopensInterface() {
        let first = FakeG502XHIDDevice(label: "first")
        let transport = FakeG502XHIDTransport(devices: [first: properties(locationID: 0x1234_0001)])
        let controller = G502XHIDController(transport: transport)
        controller.selectMouse(id: mouseID)
        let connectionChanges = expectation(description: "connected, disconnected, reconnected")
        connectionChanges.expectedFulfillmentCount = 3
        let states = LockedTestValue<[Bool]>([])
        controller.onConnectionChange = { connected, _, _ in
            states.update { $0.append(connected) }
            connectionChanges.fulfill()
        }

        XCTAssertTrue(controller.start())
        transport.disconnect(first)
        XCTAssertTrue(transport.flush())

        let replacement = FakeG502XHIDDevice(label: "replacement")
        transport.connect(replacement, properties: properties(locationID: 0x1234_0007))
        wait(for: [connectionChanges], timeout: 1)
        XCTAssertTrue(transport.flush())

        XCTAssertEqual(states.snapshot(), [true, false, true])
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(controller.selectedMouseID, mouseID)
        XCTAssertEqual(transport.count(of: .close("first")), 1)
        XCTAssertEqual(transport.count(of: .open("replacement")), 1)
        controller.stop()
    }

    func testStandardMouseReportIsCopiedAndForwarded() {
        let mouse = FakeG502XHIDDevice(label: "mouse")
        let transport = FakeG502XHIDTransport(devices: [mouse: properties(locationID: 0x1234_0001)])
        let controller = G502XHIDController(transport: transport)
        controller.selectMouse(id: mouseID)
        let received = expectation(description: "standard mouse report")
        let reports = LockedTestValue<[G502XHIDController.InputReport]>([])
        controller.onReportData = { report in
            reports.update { $0.append(report) }
            received.fulfill()
        }

        XCTAssertTrue(controller.start())
        transport.emitReport([0x05, 0x11, 0x22, 0x33], reportID: 0x01, from: mouse)
        wait(for: [received], timeout: 1)

        let report = reports.snapshot().first
        XCTAssertEqual(report?.bytes, [0x05, 0x11, 0x22, 0x33])
        XCTAssertEqual(report?.length, 4)
        XCTAssertEqual(report?.timestampSource, .hostReceipt)
        XCTAssertEqual(controller.reportCount, 1)
        controller.stop()
    }

    func testIdentityPreservesLegacyLocationFormatAndMasksInterfaceByte() {
        let first = properties(locationID: 0x12AB_CD01).device
        let second = properties(locationID: 0x12AB_CD7F).device

        XCTAssertEqual(G502XDeviceIdentity.identifier(for: first), "loc-12ABCD00-pid-50503")
        XCTAssertEqual(
            G502XDeviceIdentity.identifier(for: first),
            G502XDeviceIdentity.identifier(for: second)
        )
    }

    private func properties(
        locationID: Int,
        usage: Int = 0x02,
        maximumInputReportSize: Int = 64
    ) -> G502XHIDInterfaceProperties {
        G502XHIDInterfaceProperties(
            device: HIDDeviceProperties(
                vendorID: G502XHIDProtocol.logitechVendorID,
                productID: G502XHIDProtocol.lightspeedReceiverProductID,
                name: "G502 X LIGHTSPEED",
                serialNumber: nil,
                physicalDeviceUniqueID: nil,
                locationID: locationID,
                registryEntryID: UInt64(locationID)
            ),
            usagePage: 0x01,
            usage: usage,
            maximumInputReportSize: maximumInputReportSize,
            reportDescriptorSize: 48
        )
    }
}

private final class FakeG502XHIDDevice: HIDDeviceHandle, @unchecked Sendable, Hashable {
    let label: String

    init(label: String) {
        self.label = label
    }

    var transportIdentifier: ObjectIdentifier { ObjectIdentifier(self) }

    static func == (lhs: FakeG502XHIDDevice, rhs: FakeG502XHIDDevice) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

private final class FakeG502XInputRegistration: HIDInputRegistration, @unchecked Sendable {
    let deviceLabel: String

    init(deviceLabel: String) {
        self.deviceLabel = deviceLabel
    }
}

private final class FakeG502XHIDTransport: G502XHIDTransport, @unchecked Sendable {
    enum Event: Equatable {
        case start
        case stop
        case open(String)
        case close(String)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var interfacePropertiesByDevice: [FakeG502XHIDDevice: G502XHIDInterfaceProperties]
    private var startResults: [Result<Void, HIDTransportError>]
    private var openResults: [Result<Void, HIDTransportError>]
    private var runLoop: CFRunLoop?
    private var connectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var disconnectedHandler: (@Sendable (any HIDDeviceHandle) -> Void)?
    private var reportHandlers: [FakeG502XHIDDevice: HIDReportHandler] = [:]

    init(
        devices: [FakeG502XHIDDevice: G502XHIDInterfaceProperties],
        startResults: [Result<Void, HIDTransportError>] = [.success(())],
        openResults: [Result<Void, HIDTransportError>] = []
    ) {
        interfacePropertiesByDevice = devices
        self.startResults = startResults
        self.openResults = openResults
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
        let devices = Array(interfacePropertiesByDevice.keys)
        lock.unlock()
        if case .success = result {
            for device in devices { deviceConnected(device) }
        }
        return result
    }

    func stopDiscovery(on _: CFRunLoop) {
        lock.lock()
        events.append(.stop)
        runLoop = nil
        connectedHandler = nil
        disconnectedHandler = nil
        lock.unlock()
    }

    func properties(for device: any HIDDeviceHandle) -> HIDDeviceProperties? {
        interfaceProperties(for: device)?.device
    }

    func interfaceProperties(
        for device: any HIDDeviceHandle
    ) -> G502XHIDInterfaceProperties? {
        guard let device = device as? FakeG502XHIDDevice else { return nil }
        return locked { interfacePropertiesByDevice[device] }
    }

    func openInput(
        for device: any HIDDeviceHandle,
        on _: CFRunLoop,
        reportLength _: Int,
        handler: @escaping HIDReportHandler
    ) -> Result<any HIDInputRegistration, HIDTransportError> {
        guard let device = device as? FakeG502XHIDDevice else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        events.append(.open(device.label))
        let result = openResults.isEmpty ? .success(()) : openResults.removeFirst()
        lock.unlock()
        switch result {
        case .success:
            locked { reportHandlers[device] = handler }
            return .success(FakeG502XInputRegistration(deviceLabel: device.label))
        case let .failure(error):
            return .failure(error)
        }
    }

    func closeInput(
        _ registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError> {
        guard let registration = registration as? FakeG502XInputRegistration else {
            return .failure(.unexpectedHandle)
        }
        lock.lock()
        events.append(.close(registration.deviceLabel))
        reportHandlers = reportHandlers.filter { $0.key.label != registration.deviceLabel }
        lock.unlock()
        return .success(())
    }

    func sendReport(
        _: [UInt8],
        reportID _: UInt8,
        type _: HIDSetReportType,
        to _: any HIDDeviceHandle
    ) -> Result<Void, HIDTransportError> {
        .success(())
    }

    func disconnect(_ device: FakeG502XHIDDevice) {
        guard let targetRunLoop = locked({ runLoop }) else {
            XCTFail("Fake transport is not running")
            return
        }
        CFRunLoopPerformBlock(targetRunLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            self.locked { self.disconnectedHandler }?(device)
        }
        CFRunLoopWakeUp(targetRunLoop)
    }

    func connect(
        _ device: FakeG502XHIDDevice,
        properties: G502XHIDInterfaceProperties
    ) {
        guard let targetRunLoop = locked({ () -> CFRunLoop? in
            interfacePropertiesByDevice[device] = properties
            return runLoop
        }) else {
            XCTFail("Fake transport is not running")
            return
        }
        CFRunLoopPerformBlock(targetRunLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            self.locked { self.connectedHandler }?(device)
        }
        CFRunLoopWakeUp(targetRunLoop)
    }

    func emitReport(
        _ bytes: [UInt8],
        reportID: UInt32,
        from device: FakeG502XHIDDevice
    ) {
        guard let (targetRunLoop, handler) = locked({ () -> (CFRunLoop, HIDReportHandler)? in
            guard let runLoop, let handler = reportHandlers[device] else { return nil }
            return (runLoop, handler)
        }) else {
            XCTFail("Fake device does not have an active input registration")
            return
        }
        CFRunLoopPerformBlock(targetRunLoop, CFRunLoopMode.defaultMode.rawValue) {
            var report = bytes
            report.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                handler(reportID, baseAddress, buffer.count)
            }
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

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }

    func snapshot() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
