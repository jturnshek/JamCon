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

/// Static feature set advertised by an input backend. This is intentionally a
/// bit set so capability checks stay allocation-free on the input path.
struct InputDeviceCapabilities: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8

    static let buttons = InputDeviceCapabilities(rawValue: 1 << 0)
    static let analogStick = InputDeviceCapabilities(rawValue: 1 << 1)
    static let motion = InputDeviceCapabilities(rawValue: 1 << 2)
    static let battery = InputDeviceCapabilities(rawValue: 1 << 3)
}

/// Low-frequency metadata used for registry routing and diagnostics. The
/// existing ControllerKind remains a compatibility field while profiles and
/// persistence still use that model.
struct InputDeviceBackendDescriptor: Hashable, Codable, Sendable {
    let id: InputDeviceBackendID
    let kind: ControllerKind
    let displayName: String
    let capabilities: InputDeviceCapabilities

    init(
        id: InputDeviceBackendID,
        kind: ControllerKind,
        displayName: String,
        capabilities: InputDeviceCapabilities = []
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// Motion storage that reuses the adapter's existing sample representation.
/// Sense supplies one sample, Joy-Con supplies its existing three-sample
/// array, and devices without an IMU use `.none`.
enum InputDeviceMotionSamples: Equatable, Sendable {
    case none
    case single(IMUSample)
    case batch([IMUSample])

    var latest: IMUSample? {
        switch self {
        case .none:
            return nil
        case let .single(sample):
            return sample
        case let .batch(samples):
            return samples.last
        }
    }

    var averagedGyro: (x: Int16, y: Int16, z: Int16)? {
        switch self {
        case .none:
            return nil
        case let .single(sample):
            return (sample.gyroX, sample.gyroY, sample.gyroZ)
        case let .batch(samples):
            guard !samples.isEmpty else { return nil }
            let count = Int32(samples.count)
            let sums = samples.reduce(into: (x: Int32(0), y: Int32(0), z: Int32(0))) { result, sample in
                result.x += Int32(sample.gyroX)
                result.y += Int32(sample.gyroY)
                result.z += Int32(sample.gyroZ)
            }
            return (
                Int16(sums.x / count),
                Int16(sums.y / count),
                Int16(sums.z / count)
            )
        }
    }
}

/// Common high-frequency handoff from every device adapter to the engine.
/// Raw bytes remain available for device-specific control mapping and bounded
/// diagnostics, while identity, timing, and motion have one shared contract.
struct InputDeviceFrame: Equatable, Sendable {
    let backend: InputDeviceBackendDescriptor
    let deviceID: String
    let reportID: UInt32
    let bytes: [UInt8]
    let motion: InputDeviceMotionSamples
    let timestamp: TimeInterval
    let receivedTimestamp: TimeInterval
    let inputTimestamp: TimeInterval?
    let timestampSource: InputTimestampSource

    var length: Int { bytes.count }
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
    let inputFrame: @Sendable (InputDeviceFrame) -> Void

    static let none = InputDeviceBackendEventHandlers(
        devicesChanged: {},
        connectionChanged: { _, _, _ in },
        inputFrame: { _ in }
    )
}

/// Common low-frequency contract for built-in device adapters.
///
/// Raw framework handles and transport-specific report types remain behind
/// each concrete adapter. All high-frequency input crosses this boundary as an
/// `InputDeviceFrame`.
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
        connectionChanged: @escaping @Sendable (InputDeviceBackendConnectionEvent) -> Void,
        inputFrame: @escaping @Sendable (InputDeviceFrame) -> Void
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
                },
                inputFrame: { frame in
                    guard frame.backend == descriptor else {
                        JamLog.errorThrottled(
                            .engine,
                            key: "input.backend-mismatch.\(descriptor.id.rawValue)",
                            interval: 2,
                            "Dropping input frame whose descriptor does not match backend \(descriptor.id.rawValue)"
                        )
                        return
                    }
                    inputFrame(frame)
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

extension JoyConHIDController: InputDeviceBackend {
    var backendDescriptor: InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: .joyConDirectHID,
            kind: .joyCon,
            displayName: "Joy-Con Direct HID",
            capabilities: [.buttons, .analogStick, .motion, .battery]
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
        onReportData = { [descriptor = backendDescriptor] report in
            handlers.inputFrame(InputDeviceFrame(
                backend: descriptor,
                deviceID: report.controllerID,
                reportID: JoyConHIDProtocol.inputReportID,
                bytes: report.bytes,
                motion: .batch(report.motionSamples),
                timestamp: report.timestamp,
                receivedTimestamp: report.receivedTimestamp,
                inputTimestamp: report.inputTimestamp,
                timestampSource: report.timestampSource
            ))
        }
    }
}

extension G502XHIDController: InputDeviceBackend {
    var backendDescriptor: InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: .g502DirectHID,
            kind: .mouse,
            displayName: "G502 X Direct HID",
            capabilities: [.buttons]
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
        onReportData = { [weak self, descriptor = backendDescriptor] report in
            guard let deviceID = self?.selectedMouseID else {
                JamLog.errorThrottled(
                    .g502x,
                    key: "input.missing-device-id",
                    interval: 2,
                    "Dropping mouse input without a selected device identity"
                )
                return
            }
            handlers.inputFrame(InputDeviceFrame(
                backend: descriptor,
                deviceID: deviceID,
                reportID: 0,
                bytes: report.bytes,
                motion: .none,
                timestamp: report.timestamp,
                receivedTimestamp: report.receivedTimestamp,
                inputTimestamp: report.inputTimestamp,
                timestampSource: report.timestampSource
            ))
        }
    }
}
