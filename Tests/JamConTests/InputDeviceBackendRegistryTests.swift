import XCTest
@testable import JamCon

final class InputDeviceBackendRegistryTests: XCTestCase {
    func testRegistryAggregatesDevicesAndRoutesManagementByKind() {
        let senseDevice = ControllerInfo(
            id: "sense-1",
            name: "Sense Right",
            productID: SenseHIDProtocol.rightProductID,
            kind: .sense
        )
        let joyConDevice = ControllerInfo(
            id: "joycon-1",
            name: "Joy-Con Right",
            productID: JoyConHIDProtocol.rightProductID,
            kind: .joyCon
        )
        let sense = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.sense", kind: .sense),
            devices: [senseDevice]
        )
        let joyCon = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon),
            devices: [joyConDevice]
        )
        let registry = InputDeviceBackendRegistry(backends: [sense, joyCon])

        XCTAssertEqual(registry.availableDevicesSnapshot(), [senseDevice, joyConDevice])
        XCTAssertTrue(registry.setDeviceManaged(id: "joycon-1", kind: .joyCon, managed: true))
        XCTAssertEqual(joyCon.managedCallsSnapshot(), [ManagedCall(id: "joycon-1", managed: true)])
        XCTAssertTrue(sense.managedCallsSnapshot().isEmpty)
        XCTAssertFalse(registry.setDeviceManaged(id: "missing", kind: .mouse, managed: true))
        XCTAssertTrue(registry.backend(id: sense.backendDescriptor.id) === sense)
        XCTAssertTrue(registry.backend(for: .joyCon) === joyCon)
    }

    func testRegistryStartsAndStopsBackendsInRegistrationOrder() {
        let events = LockedBackendValue<[String]>([])
        let sense = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.sense", kind: .sense),
            startResult: true,
            sharedEvents: events
        )
        let mouse = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.mouse", kind: .mouse),
            startResult: false,
            sharedEvents: events
        )
        let registry = InputDeviceBackendRegistry(backends: [sense, mouse])

        let results = registry.startAll()
        registry.stopAll()

        XCTAssertEqual(results, [
            InputDeviceBackendStartResult(backend: sense.backendDescriptor, started: true),
            InputDeviceBackendStartResult(backend: mouse.backendDescriptor, started: false),
        ])
        XCTAssertEqual(events.snapshot(), [
            "start:test.sense",
            "start:test.mouse",
            "stop:test.sense",
            "stop:test.mouse",
        ])
    }

    func testRegistryEnrichesLifecycleCallbacksWithBackendDescriptor() {
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon)
        )
        let registry = InputDeviceBackendRegistry(backends: [backend])
        let changedBackends = LockedBackendValue<[InputDeviceBackendDescriptor]>([])
        let connectionEvents = LockedBackendValue<[InputDeviceBackendConnectionEvent]>([])
        let inputFrames = LockedBackendValue<[InputDeviceFrame]>([])
        registry.setEventHandlers(
            devicesChanged: { descriptor in
                changedBackends.update { $0.append(descriptor) }
            },
            connectionChanged: { event in
                connectionEvents.update { $0.append(event) }
            },
            inputFrame: { frame in
                inputFrames.update { $0.append(frame) }
            }
        )

        backend.emitDevicesChanged()
        backend.emitConnection(connected: true, name: "Joy-Con", id: "joycon-1")
        let frame = InputDeviceFrame(
            backend: backend.backendDescriptor,
            deviceID: "joycon-1",
            reportID: JoyConHIDProtocol.inputReportID,
            bytes: [0x30],
            motion: .none,
            timestamp: 10,
            receivedTimestamp: 10,
            inputTimestamp: nil,
            timestampSource: .hostReceipt
        )
        backend.emitInputFrame(frame)

        XCTAssertEqual(changedBackends.snapshot(), [backend.backendDescriptor])
        XCTAssertEqual(connectionEvents.snapshot(), [
            InputDeviceBackendConnectionEvent(
                backend: backend.backendDescriptor,
                connected: true,
                deviceName: "Joy-Con",
                deviceID: "joycon-1"
            ),
        ])
        XCTAssertEqual(inputFrames.snapshot(), [frame])
    }

    func testRegistryConnectionStateIsAggregate() {
        let sense = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.sense", kind: .sense)
        )
        let mouse = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.mouse", kind: .mouse)
        )
        let registry = InputDeviceBackendRegistry(backends: [sense, mouse])

        XCTAssertFalse(registry.isConnected)
        mouse.setConnected(true)
        XCTAssertTrue(registry.isConnected)
        mouse.setConnected(false)
        XCTAssertFalse(registry.isConnected)
    }

    func testRegistryRejectsFrameWhoseDescriptorDoesNotMatchItsBackend() {
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon)
        )
        let registry = InputDeviceBackendRegistry(backends: [backend])
        let receivedFrames = LockedBackendValue<[InputDeviceFrame]>([])
        registry.setEventHandlers(
            devicesChanged: { _ in },
            connectionChanged: { _ in },
            inputFrame: { frame in receivedFrames.update { $0.append(frame) } }
        )

        backend.emitInputFrame(InputDeviceFrame(
            backend: descriptor(id: "other.joycon", kind: .joyCon),
            deviceID: "joycon-1",
            reportID: JoyConHIDProtocol.inputReportID,
            bytes: [0x30],
            motion: .none,
            timestamp: 10,
            receivedTimestamp: 10,
            inputTimestamp: nil,
            timestampSource: .hostReceipt
        ))

        XCTAssertTrue(receivedFrames.snapshot().isEmpty)
    }

    private func descriptor(
        id: String,
        kind: ControllerKind
    ) -> InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: InputDeviceBackendID(rawValue: id),
            kind: kind,
            displayName: id
        )
    }
}

private struct ManagedCall: Equatable, Sendable {
    let id: String
    let managed: Bool
}

private final class FakeInputDeviceBackend: InputDeviceBackend, @unchecked Sendable {
    let backendDescriptor: InputDeviceBackendDescriptor

    private let lock = NSLock()
    private let startResult: Bool
    private let sharedEvents: LockedBackendValue<[String]>?
    private var devices: [ControllerInfo]
    private var connected = false
    private var managedCalls: [ManagedCall] = []
    private var handlers = InputDeviceBackendEventHandlers.none

    init(
        descriptor: InputDeviceBackendDescriptor,
        devices: [ControllerInfo] = [],
        startResult: Bool = true,
        sharedEvents: LockedBackendValue<[String]>? = nil
    ) {
        backendDescriptor = descriptor
        self.devices = devices
        self.startResult = startResult
        self.sharedEvents = sharedEvents
    }

    func start() -> Bool {
        sharedEvents?.update { $0.append("start:\(backendDescriptor.id.rawValue)") }
        return startResult
    }

    func stop() {
        sharedEvents?.update { $0.append("stop:\(backendDescriptor.id.rawValue)") }
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        locked { devices }
    }

    var isConnected: Bool {
        locked { connected }
    }

    func setDeviceManaged(id: String, managed: Bool) {
        locked { managedCalls.append(ManagedCall(id: id, managed: managed)) }
    }

    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers) {
        locked { self.handlers = handlers }
    }

    func managedCallsSnapshot() -> [ManagedCall] {
        locked { managedCalls }
    }

    func setConnected(_ connected: Bool) {
        locked { self.connected = connected }
    }

    func emitDevicesChanged() {
        locked { handlers }.devicesChanged()
    }

    func emitConnection(connected: Bool, name: String?, id: String?) {
        locked { handlers }.connectionChanged(connected, name, id)
    }

    func emitInputFrame(_ frame: InputDeviceFrame) {
        locked { handlers }.inputFrame(frame)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedBackendValue<Value>: @unchecked Sendable {
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
