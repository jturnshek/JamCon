import Foundation

/// Stable identifier for one implementation of a device-family backend.
/// Multiple implementations for the same family (for example direct HID and
/// Game Controller) can coexist once registry arbitration is added.
struct InputDeviceBackendID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        precondition(!rawValue.isEmpty, "Input device backend IDs cannot be empty")
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    static let senseGameController = InputDeviceBackendID(rawValue: "sense.game-controller")
    static let joyConDirectHID = InputDeviceBackendID(rawValue: "joycon.direct-hid")
    static let g502DirectHID = InputDeviceBackendID(rawValue: "g502x.direct-hid")
}

/// Low-frequency metadata used for registry routing and diagnostics. The
/// existing ControllerKind remains a compatibility field while profiles and
/// persistence still use that model.
struct InputDeviceBackendDescriptor: Hashable, Codable, Sendable {
    let id: InputDeviceBackendID
    let kind: ControllerKind
    let displayName: String
}

struct InputDeviceBackendConnectionEvent: Equatable, Sendable {
    let backend: InputDeviceBackendDescriptor
    let connected: Bool
    let deviceName: String?
    let deviceID: String?
}

struct InputDeviceBackendStartResult: Equatable, Sendable {
    let backend: InputDeviceBackendDescriptor
    let started: Bool
}

struct InputDeviceBackendEventHandlers: Sendable {
    let devicesChanged: @Sendable () -> Void
    let connectionChanged: @Sendable (
        _ connected: Bool,
        _ deviceName: String?,
        _ deviceID: String?
    ) -> Void

    static let none = InputDeviceBackendEventHandlers(
        devicesChanged: {},
        connectionChanged: { _, _, _ in }
    )
}

/// Common low-frequency contract for built-in device adapters.
///
/// Raw framework handles and reports remain behind each concrete adapter. The
/// high-frequency report callback is deliberately not type-erased here; it is
/// migrated separately when the normalized input-frame contract is introduced.
protocol InputDeviceBackend: AnyObject, Sendable {
    var backendDescriptor: InputDeviceBackendDescriptor { get }

    @discardableResult
    func start() -> Bool
    func stop()

    func availableDevicesSnapshot() -> [ControllerInfo]
    var isConnected: Bool { get }
    func setDeviceManaged(id: String, managed: Bool)

    /// Replaces the backend's lifecycle observers. Configure before start.
    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers)
}

/// Owns the common lifecycle/discovery/management surface for all device
/// adapters. It is immutable after construction; concrete backends synchronize
/// their own state and callbacks.
final class InputDeviceBackendRegistry: @unchecked Sendable {
    private let orderedBackends: [any InputDeviceBackend]
    private let backendsByID: [InputDeviceBackendID: any InputDeviceBackend]
    private let primaryBackendByKind: [ControllerKind: any InputDeviceBackend]

    init(backends: [any InputDeviceBackend]) {
        var byID: [InputDeviceBackendID: any InputDeviceBackend] = [:]
        var byKind: [ControllerKind: any InputDeviceBackend] = [:]

        for backend in backends {
            let descriptor = backend.backendDescriptor
            precondition(
                byID.updateValue(backend, forKey: descriptor.id) == nil,
                "Duplicate input device backend ID: \(descriptor.id)"
            )
            precondition(
                byKind.updateValue(backend, forKey: descriptor.kind) == nil,
                "Backend arbitration is required before registering multiple backends for \(descriptor.kind)"
            )
        }

        orderedBackends = backends
        backendsByID = byID
        primaryBackendByKind = byKind
    }

    var descriptors: [InputDeviceBackendDescriptor] {
        orderedBackends.map(\.backendDescriptor)
    }

    func backend(id: InputDeviceBackendID) -> (any InputDeviceBackend)? {
        backendsByID[id]
    }

    func backend(for kind: ControllerKind) -> (any InputDeviceBackend)? {
        primaryBackendByKind[kind]
    }

    func setEventHandlers(
        devicesChanged: @escaping @Sendable (_ backend: InputDeviceBackendDescriptor) -> Void,
        connectionChanged: @escaping @Sendable (InputDeviceBackendConnectionEvent) -> Void
    ) {
        for backend in orderedBackends {
            let descriptor = backend.backendDescriptor
            backend.setEventHandlers(InputDeviceBackendEventHandlers(
                devicesChanged: {
                    devicesChanged(descriptor)
                },
                connectionChanged: { connected, name, deviceID in
                    connectionChanged(InputDeviceBackendConnectionEvent(
                        backend: descriptor,
                        connected: connected,
                        deviceName: name,
                        deviceID: deviceID
                    ))
                }
            ))
        }
    }

    @discardableResult
    func startAll() -> [InputDeviceBackendStartResult] {
        orderedBackends.map { backend in
            InputDeviceBackendStartResult(
                backend: backend.backendDescriptor,
                started: backend.start()
            )
        }
    }

    func stopAll() {
        for backend in orderedBackends {
            backend.stop()
        }
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        orderedBackends.flatMap { $0.availableDevicesSnapshot() }
    }

    var isConnected: Bool {
        orderedBackends.contains { $0.isConnected }
    }

    @discardableResult
    func setDeviceManaged(
        id: String,
        kind: ControllerKind,
        managed: Bool
    ) -> Bool {
        guard let backend = primaryBackendByKind[kind] else { return false }
        backend.setDeviceManaged(id: id, managed: managed)
        return true
    }
}

extension SenseController: InputDeviceBackend {
    var backendDescriptor: InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: .senseGameController,
            kind: .sense,
            displayName: "PlayStation Sense Game Controller"
        )
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        controllerInfosSnapshot()
    }

    func setDeviceManaged(id: String, managed: Bool) {
        setControllerManaged(id: id, managed: managed)
    }

    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers) {
        onControllersChanged = handlers.devicesChanged
        onConnectionChange = handlers.connectionChanged
    }
}

extension JoyConHIDController: InputDeviceBackend {
    var backendDescriptor: InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: .joyConDirectHID,
            kind: .joyCon,
            displayName: "Joy-Con Direct HID"
        )
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        controllerInfosSnapshot()
    }

    func setDeviceManaged(id: String, managed: Bool) {
        setControllerManaged(id: id, managed: managed)
    }

    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers) {
        onControllersChanged = handlers.devicesChanged
        onConnectionChange = handlers.connectionChanged
    }
}

extension G502XHIDController: InputDeviceBackend {
    var backendDescriptor: InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: .g502DirectHID,
            kind: .mouse,
            displayName: "G502 X Direct HID"
        )
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        mouseInfosSnapshot()
    }

    func setDeviceManaged(id: String, managed: Bool) {
        if managed {
            selectMouse(id: id)
        } else if selectedMouseID == id {
            deselectMouse()
        }
    }

    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers) {
        onControllersChanged = handlers.devicesChanged
        onConnectionChange = handlers.connectionChanged
    }
}
