import Foundation
import os.lock

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
    static let joyCon2BluetoothLE = InputDeviceBackendID(rawValue: "joycon2.bluetooth-le")
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
            let count = Int64(samples.count)
            let sums = samples.reduce(into: (x: Int64(0), y: Int64(0), z: Int64(0))) { result, sample in
                result.x += Int64(sample.gyroX)
                result.y += Int64(sample.gyroY)
                result.z += Int64(sample.gyroZ)
            }
            return (
                Int16(sums.x / count),
                Int16(sums.y / count),
                Int16(sums.z / count)
            )
        }
    }
}

/// Hardware-provided analog-stick calibration normalized across transports.
/// Ranges are distances from the neutral point rather than absolute endpoints.
struct InputDeviceAnalogStickCalibration: Equatable, Sendable {
    let centerX: UInt16
    let centerY: UInt16
    let positiveRangeX: UInt16
    let positiveRangeY: UInt16
    let negativeRangeX: UInt16
    let negativeRangeY: UInt16
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
    /// Native raw-unit scale for one gyroscope LSB. nil uses the family default.
    let gyroScale: Double?
    /// Motion cadence currently delivered by the transport. This may differ
    /// from the rate requested from the device after BLE negotiation.
    let motionSampleRate: Double?
    /// Optional factory/user calibration supplied by the physical device.
    let analogStickCalibration: InputDeviceAnalogStickCalibration?

    var length: Int { bytes.count }

    init(
        backend: InputDeviceBackendDescriptor,
        deviceID: String,
        reportID: UInt32,
        bytes: [UInt8],
        motion: InputDeviceMotionSamples,
        timestamp: TimeInterval,
        receivedTimestamp: TimeInterval,
        inputTimestamp: TimeInterval?,
        timestampSource: InputTimestampSource,
        gyroScale: Double? = nil,
        motionSampleRate: Double? = nil,
        analogStickCalibration: InputDeviceAnalogStickCalibration? = nil
    ) {
        self.backend = backend
        self.deviceID = deviceID
        self.reportID = reportID
        self.bytes = bytes
        self.motion = motion
        self.timestamp = timestamp
        self.receivedTimestamp = receivedTimestamp
        self.inputTimestamp = inputTimestamp
        self.timestampSource = timestampSource
        self.gyroScale = gyroScale
        self.motionSampleRate = motionSampleRate
        self.analogStickCalibration = analogStickCalibration
    }
}

/// Structural failures that can be checked without understanding a device's
/// private report format. The registry rejects these before they reach the
/// latency-sensitive application policy in InputEngine.
enum InputDeviceFrameContractViolation: String, Equatable, Sendable {
    case backendMismatch
    case emptyDeviceID
    case nonFiniteTimestamp
    case nonFiniteReceivedTimestamp
    case nonFiniteInputTimestamp
    case invalidGyroScale
    case invalidMotionSampleRate
    case emptyMotionBatch
    case undeclaredMotion

    var message: String {
        switch self {
        case .backendMismatch:
            return "the frame descriptor does not match its emitting backend"
        case .emptyDeviceID:
            return "the frame has no stable device identity"
        case .nonFiniteTimestamp:
            return "the processing timestamp is not finite"
        case .nonFiniteReceivedTimestamp:
            return "the receipt timestamp is not finite"
        case .nonFiniteInputTimestamp:
            return "the optional input timestamp is not finite"
        case .invalidGyroScale:
            return "the optional gyroscope scale is not finite and positive"
        case .invalidMotionSampleRate:
            return "the optional motion sample rate is not finite and positive"
        case .emptyMotionBatch:
            return "the frame contains an empty motion batch"
        case .undeclaredMotion:
            return "the frame contains motion from a backend that does not declare motion capability"
        }
    }
}

private enum InputDeviceMetadataContractViolation: String {
    case emptyDeviceID
    case duplicateDeviceID
    case kindMismatch
    case missingHandedness
    case unexpectedHandedness

    var message: String {
        switch self {
        case .emptyDeviceID:
            return "discovered device has no stable identity"
        case .duplicateDeviceID:
            return "discovered device identity is duplicated within its backend"
        case .kindMismatch:
            return "discovered device kind does not match its backend"
        case .missingHandedness:
            return "a sided device has no backend-supplied handedness"
        case .unexpectedHandedness:
            return "a non-sided device declares handedness"
        }
    }
}

extension InputDeviceFrame {
    func contractViolation(
        expectedBackend: InputDeviceBackendDescriptor
    ) -> InputDeviceFrameContractViolation? {
        guard backend == expectedBackend else { return .backendMismatch }
        guard !deviceID.isEmpty else {
            return .emptyDeviceID
        }
        guard timestamp.isFinite else { return .nonFiniteTimestamp }
        guard receivedTimestamp.isFinite else { return .nonFiniteReceivedTimestamp }
        if let inputTimestamp, !inputTimestamp.isFinite {
            return .nonFiniteInputTimestamp
        }
        if let gyroScale,
           !gyroScale.isFinite || gyroScale <= 0 {
            return .invalidGyroScale
        }
        if let motionSampleRate,
           !motionSampleRate.isFinite || motionSampleRate <= 0 {
            return .invalidMotionSampleRate
        }

        switch motion {
        case .none:
            break
        case let .batch(samples) where samples.isEmpty:
            return .emptyMotionBatch
        case .single, .batch:
            guard expectedBackend.capabilities.contains(.motion) else {
                return .undeclaredMotion
            }
        }
        return nil
    }
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
    @discardableResult
    func restartDevice(id: String) -> Bool

    /// Replaces the backend's lifecycle observers. Configure before start.
    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers)
}

extension InputDeviceBackend {
    /// Default transport restart for backends without an in-place reset.
    /// Concrete backends can preserve their physical connection by overriding
    /// this requirement.
    @discardableResult
    func restartDevice(id: String) -> Bool {
        setDeviceManaged(id: id, managed: false)
        setDeviceManaged(id: id, managed: true)
        return true
    }
}

/// Owns the common lifecycle/discovery/management surface for all device
/// adapters. It is immutable after construction; concrete backends synchronize
/// their own state and callbacks.
final class InputDeviceBackendRegistry: @unchecked Sendable {
    private let orderedBackends: [any InputDeviceBackend]
    private let backendsByID: [InputDeviceBackendID: any InputDeviceBackend]
    private let backendsByKind: [ControllerKind: [any InputDeviceBackend]]
    private let eventStateLock = OSAllocatedUnfairLock(initialState: Set<InputDeviceBackendID>())
    private let ownershipLock = OSAllocatedUnfairLock(initialState: [String: InputDeviceBackendID]())

    init(backends: [any InputDeviceBackend]) {
        var byID: [InputDeviceBackendID: any InputDeviceBackend] = [:]
        var byKind: [ControllerKind: [any InputDeviceBackend]] = [:]

        for backend in backends {
            let descriptor = backend.backendDescriptor
            precondition(
                byID.updateValue(backend, forKey: descriptor.id) == nil,
                "Duplicate input device backend ID: \(descriptor.id)"
            )
            byKind[descriptor.kind, default: []].append(backend)
        }

        orderedBackends = backends
        backendsByID = byID
        backendsByKind = byKind
    }

    var descriptors: [InputDeviceBackendDescriptor] {
        orderedBackends.map(\.backendDescriptor)
    }

    func backend(id: InputDeviceBackendID) -> (any InputDeviceBackend)? {
        backendsByID[id]
    }

    func backend(for kind: ControllerKind) -> (any InputDeviceBackend)? {
        backendsByKind[kind]?.first
    }

    func setEventHandlers(
        devicesChanged: @escaping @Sendable (_ backend: InputDeviceBackendDescriptor) -> Void,
        connectionChanged: @escaping @Sendable (InputDeviceBackendConnectionEvent) -> Void,
        inputFrame: @escaping @Sendable (InputDeviceFrame) -> Void
    ) {
        for backend in orderedBackends {
            let descriptor = backend.backendDescriptor
            backend.setEventHandlers(InputDeviceBackendEventHandlers(
                devicesChanged: { [weak self] in
                    guard self?.isAcceptingEvents(from: descriptor.id) == true else { return }
                    devicesChanged(descriptor)
                },
                connectionChanged: { [weak self] connected, name, deviceID in
                    guard self?.isAcceptingEvents(from: descriptor.id) == true else { return }
                    connectionChanged(InputDeviceBackendConnectionEvent(
                        backend: descriptor,
                        connected: connected,
                        deviceName: name,
                        deviceID: deviceID
                    ))
                },
                inputFrame: { [weak self] frame in
                    guard self?.isAcceptingEvents(from: descriptor.id) == true else { return }
                    if let violation = frame.contractViolation(expectedBackend: descriptor) {
                        JamLog.errorThrottled(
                            .engine,
                            key: "input.contract.\(descriptor.id.rawValue).\(violation.rawValue)",
                            interval: 2,
                            "Dropping invalid input frame from \(descriptor.id.rawValue): \(violation.message)"
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
        eventStateLock.withLock { $0.removeAll(keepingCapacity: true) }
        return orderedBackends.map { backend in
            let backendID = backend.backendDescriptor.id
            setAcceptingEvents(true, from: backendID)
            let result = InputDeviceBackendStartResult(
                backend: backend.backendDescriptor,
                started: backend.start()
            )
            if !result.started {
                setAcceptingEvents(false, from: backendID)
            }
            return result
        }
    }

    func stopAll() {
        // Close the registry boundary before asking transports to stop so
        // callbacks arriving during transport teardown are ignored.
        eventStateLock.withLock { $0.removeAll(keepingCapacity: true) }
        for backend in orderedBackends {
            backend.stop()
        }
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        var owners: [String: InputDeviceBackendID] = [:]
        var seenFamilyDeviceIDs = Set<String>()
        let devices = orderedBackends.flatMap { backend in
            let descriptor = backend.backendDescriptor
            var seenDeviceIDs = Set<String>()
            return backend.availableDevicesSnapshot().filter { device in
                let violation: InputDeviceMetadataContractViolation?
                if device.id.isEmpty {
                    violation = .emptyDeviceID
                } else if !seenDeviceIDs.insert(device.id).inserted {
                    violation = .duplicateDeviceID
                } else if !seenFamilyDeviceIDs.insert("\(device.kind.rawValue):\(device.id)").inserted {
                    violation = .duplicateDeviceID
                } else if device.kind != descriptor.kind {
                    violation = .kindMismatch
                } else if device.kind.hasSides && device.handedness == .none {
                    violation = .missingHandedness
                } else if !device.kind.hasSides && device.handedness != .none {
                    violation = .unexpectedHandedness
                } else {
                    violation = nil
                }

                guard let violation else {
                    owners["\(device.kind.rawValue):\(device.id)"] = descriptor.id
                    return true
                }
                JamLog.errorThrottled(
                    .engine,
                    key: "input.metadata.\(descriptor.id.rawValue).\(violation.rawValue)",
                    interval: 2,
                    "Ignoring invalid device metadata from \(descriptor.id.rawValue): \(violation.message)"
                )
                return false
            }
        }
        let discoveredOwners = owners
        ownershipLock.withLock { knownOwners in
            // Preserve owners learned during management so a temporarily
            // disconnected device can still be routed for an explicit unmanage.
            knownOwners.merge(discoveredOwners) { _, current in current }
        }
        return devices
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
        let key = "\(kind.rawValue):\(id)"
        let backend = resolveBackend(id: id, kind: kind)
        guard let backend else { return false }
        backend.setDeviceManaged(id: id, managed: managed)
        ownershipLock.withLock { owners in
            if managed {
                owners[key] = backend.backendDescriptor.id
            } else {
                owners.removeValue(forKey: key)
            }
        }
        return true
    }

    /// Soft-restarts one device through its existing backend without removing
    /// Bluetooth pairing or changing the user's persisted managed selection.
    @discardableResult
    func restartDevice(id: String, kind: ControllerKind) -> Bool {
        let key = "\(kind.rawValue):\(id)"
        guard let backend = resolveBackend(id: id, kind: kind) else { return false }
        guard backend.restartDevice(id: id) else { return false }
        ownershipLock.withLock { $0[key] = backend.backendDescriptor.id }
        return true
    }

    private func resolveBackend(
        id: String,
        kind: ControllerKind
    ) -> (any InputDeviceBackend)? {
        let key = "\(kind.rawValue):\(id)"
        let candidates = backendsByKind[kind] ?? []
        let rememberedID = ownershipLock.withLock { $0[key] }
        return rememberedID.flatMap { backendsByID[$0] }
            ?? candidates.first(where: { candidate in
                candidate.availableDevicesSnapshot().contains(where: { $0.id == id })
            })
    }

    private func isAcceptingEvents(from backendID: InputDeviceBackendID) -> Bool {
        eventStateLock.withLock { $0.contains(backendID) }
    }

    private func setAcceptingEvents(_ acceptsEvents: Bool, from backendID: InputDeviceBackendID) {
        eventStateLock.withLock { backendIDs in
            if acceptsEvents {
                backendIDs.insert(backendID)
            } else {
                backendIDs.remove(backendID)
            }
        }
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
