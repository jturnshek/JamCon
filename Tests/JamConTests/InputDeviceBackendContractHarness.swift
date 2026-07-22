import Foundation
@testable import JamCon

/// Reusable observer and lifecycle driver for every InputDeviceBackend test.
/// Adapter tests inject their fake transport/session, then use this harness to
/// exercise the same registry boundary that production InputEngine owns.
final class InputDeviceBackendContractHarness: @unchecked Sendable {
    let registry: InputDeviceBackendRegistry

    private let changedBackends = LockedBackendValue<[InputDeviceBackendDescriptor]>([])
    private let connectionEvents = LockedBackendValue<[InputDeviceBackendConnectionEvent]>([])
    private let inputFrames = LockedBackendValue<[InputDeviceFrame]>([])

    init(
        backend: any InputDeviceBackend,
        devicesChangedObserver: @escaping @Sendable (InputDeviceBackendDescriptor) -> Void = { _ in },
        connectionObserver: @escaping @Sendable (InputDeviceBackendConnectionEvent) -> Void = { _ in },
        inputObserver: @escaping @Sendable (InputDeviceFrame) -> Void = { _ in }
    ) {
        registry = InputDeviceBackendRegistry(backends: [backend])
        registry.setEventHandlers(
            devicesChanged: { [changedBackends] descriptor in
                changedBackends.update { $0.append(descriptor) }
                devicesChangedObserver(descriptor)
            },
            connectionChanged: { [connectionEvents] event in
                connectionEvents.update { $0.append(event) }
                connectionObserver(event)
            },
            inputFrame: { [inputFrames] frame in
                inputFrames.update { $0.append(frame) }
                inputObserver(frame)
            }
        )
    }

    @discardableResult
    func start() -> Bool {
        registry.startAll().first?.started == true
    }

    func stop() {
        registry.stopAll()
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        registry.availableDevicesSnapshot()
    }

    @discardableResult
    func setDeviceManaged(id: String, kind: ControllerKind, managed: Bool) -> Bool {
        registry.setDeviceManaged(id: id, kind: kind, managed: managed)
    }

    func changedBackendsSnapshot() -> [InputDeviceBackendDescriptor] {
        changedBackends.snapshot()
    }

    func connectionEventsSnapshot() -> [InputDeviceBackendConnectionEvent] {
        connectionEvents.snapshot()
    }

    func inputFramesSnapshot() -> [InputDeviceFrame] {
        inputFrames.snapshot()
    }
}

struct ManagedCall: Equatable, Sendable {
    let id: String
    let managed: Bool
}

/// Controllable backend for registry contract tests and as an example fixture
/// when scaffolding a new adapter's fake transport tests.
final class FakeInputDeviceBackend: InputDeviceBackend, @unchecked Sendable {
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

final class LockedBackendValue<Value>: @unchecked Sendable {
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
