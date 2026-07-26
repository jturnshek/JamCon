import Foundation

/// Complete Sense adapter. IOKit supplies stable Bluetooth identity and
/// discovery, while Game Controller supplies all live input. Neither transport
/// leaks into `InputEngine`.
final class SenseInputDeviceBackend: InputDeviceBackend, @unchecked Sendable {
    let backendDescriptor = InputDeviceBackendDescriptor(
        id: .senseGameController,
        kind: .sense,
        displayName: "PlayStation Sense Game Controller",
        capabilities: [.buttons, .analogStick, .motion, .battery]
    )

    private struct State {
        var isStarted = false
        var managedDeviceIDs: Set<String> = []
        var nativeDevicesBySide: [Bool: SenseGameControllerDevice] = [:]
        var readyDeviceIDsBySide: [Bool: String] = [:]
        var handlers = InputDeviceBackendEventHandlers.none
    }

    private let lock = NSLock()
    private var state = State()
    private let discovery: SenseController
    private let gameControllerSession: any SenseGameControllerSessioning

    init(
        discovery: SenseController = SenseController(),
        gameControllerSession: any SenseGameControllerSessioning = SenseGameControllerSession()
    ) {
        self.discovery = discovery
        self.gameControllerSession = gameControllerSession
    }

    @discardableResult
    func start() -> Bool {
        let shouldStart = locked { state -> Bool in
            guard !state.isStarted else { return false }
            state.isStarted = true
            return true
        }
        guard shouldStart else { return true }

        configureSources()
        gameControllerSession.start()
        guard discovery.start() else {
            gameControllerSession.stop()
            locked { state in
                state.isStarted = false
                state.nativeDevicesBySide.removeAll(keepingCapacity: true)
                state.readyDeviceIDsBySide.removeAll(keepingCapacity: true)
            }
            return false
        }

        reconcileSide(isLeft: true)
        reconcileSide(isLeft: false)
        return true
    }

    func stop() {
        let shouldStop = locked { state -> Bool in
            guard state.isStarted else { return false }
            state.isStarted = false
            return true
        }
        guard shouldStop else { return }

        discovery.stop()
        gameControllerSession.stop()
        locked { state in
            state.nativeDevicesBySide.removeAll(keepingCapacity: true)
            state.readyDeviceIDsBySide.removeAll(keepingCapacity: true)
        }
    }

    func availableDevicesSnapshot() -> [ControllerInfo] {
        discovery.controllerInfosSnapshot()
    }

    var isConnected: Bool {
        locked { !$0.readyDeviceIDsBySide.isEmpty }
    }

    func setDeviceManaged(id: String, managed: Bool) {
        let info = discovery.controllerInfosSnapshot().first(where: { $0.id == id })
        locked { state in
            if managed {
                state.managedDeviceIDs.insert(id)
            } else {
                state.managedDeviceIDs.remove(id)
            }
        }
        discovery.setControllerManaged(id: id, managed: managed)

        if let info {
            reconcileSide(isLeft: info.isLeft)
        } else if !managed {
            removeReadyDevice(id: id)
        }
    }

    func setEventHandlers(_ handlers: InputDeviceBackendEventHandlers) {
        locked { $0.handlers = handlers }
    }

    private func configureSources() {
        discovery.onControllersChanged = { [weak self] in
            self?.handleDevicesChanged()
        }
        discovery.onConnectionChange = { [weak self] connected, name, deviceID in
            self?.handleDiscoveryConnection(connected: connected, name: name, deviceID: deviceID)
        }
        // Raw Sense input is intentionally unavailable on macOS. Leave this
        // installed as a defensive diagnostic if a future transport enables it.
        discovery.onReportData = { report in
            JamLog.errorThrottled(
                .sense,
                key: "unexpected.raw-input.\(report.controllerID)",
                interval: 2,
                "Ignoring unexpected raw Sense input; Game Controller is the authoritative transport"
            )
        }

        gameControllerSession.setEventHandlers(SenseGameControllerSessionHandlers(
            connectionChanged: { [weak self] connected, device in
                self?.handleNativeConnection(connected: connected, device: device)
            },
            inputFrame: { [weak self] frame in
                self?.handleNativeFrame(frame)
            }
        ))
    }

    private func handleDevicesChanged() {
        let handler = locked { $0.handlers.devicesChanged }
        handler()
        reconcileSide(isLeft: true)
        reconcileSide(isLeft: false)
    }

    private func handleDiscoveryConnection(
        connected: Bool,
        name _: String?,
        deviceID: String?
    ) {
        guard let deviceID else { return }
        guard connected else {
            removeReadyDevice(id: deviceID)
            return
        }
        guard let info = discovery.controllerInfosSnapshot().first(where: { $0.id == deviceID }) else {
            return
        }
        reconcileSide(isLeft: info.isLeft)
    }

    private func handleNativeConnection(
        connected: Bool,
        device: SenseGameControllerDevice
    ) {
        locked { state in
            if connected {
                state.nativeDevicesBySide[device.isLeft] = device
            } else {
                state.nativeDevicesBySide.removeValue(forKey: device.isLeft)
            }
        }
        reconcileSide(isLeft: device.isLeft)
    }

    private func handleNativeFrame(_ frame: SenseGameControllerInputFrame) {
        var deviceID: String? = locked { state -> String? in
            guard state.isStarted else { return nil }
            return state.readyDeviceIDsBySide[frame.device.isLeft]
        }
        if deviceID == nil {
            reconcileSide(isLeft: frame.device.isLeft)
            deviceID = locked { $0.readyDeviceIDsBySide[frame.device.isLeft] }
        }
        guard let deviceID else { return }

        let handler = locked { $0.handlers.inputFrame }
        handler(InputDeviceFrame(
            backend: backendDescriptor,
            deviceID: deviceID,
            reportID: SenseHIDProtocol.inputReportID,
            bytes: frame.bytes,
            motion: .single(IMUSample(
                accelX: frame.accelX,
                accelY: frame.accelY,
                accelZ: frame.accelZ,
                gyroX: frame.gyroX,
                gyroY: frame.gyroY,
                gyroZ: frame.gyroZ
            )),
            timestamp: frame.timestamp,
            receivedTimestamp: frame.timestamp,
            inputTimestamp: nil,
            timestampSource: .hostReceipt,
            battery: frame.bytes.indices.contains(SenseHIDProtocol.Offset.battery)
                && frame.bytes[SenseHIDProtocol.Offset.battery] > 0
                ? InputDeviceBatteryState(
                    percentage: SenseHIDProtocol.batteryPercentage(
                        from: frame.bytes[SenseHIDProtocol.Offset.battery]
                    ),
                    isEstimated: false
                )
                : nil
        ))
    }

    private func reconcileSide(isLeft: Bool) {
        let snapshot = discovery.controllerInfosSnapshot()
        let input = locked { state in
            (
                isStarted: state.isStarted,
                managedIDs: state.managedDeviceIDs,
                nativeDevice: state.nativeDevicesBySide[isLeft]
            )
        }
        guard input.isStarted else { return }

        let matches = snapshot.filter { $0.isLeft == isLeft && input.managedIDs.contains($0.id) }
        let nextID = input.nativeDevice != nil && matches.count == 1 ? matches[0].id : nil
        let change = locked { state -> (old: String?, new: String?, handler: InputDeviceBackendEventHandlers)? in
            let oldID = state.readyDeviceIDsBySide[isLeft]
            guard oldID != nextID else { return nil }
            if let nextID {
                state.readyDeviceIDsBySide[isLeft] = nextID
            } else {
                state.readyDeviceIDsBySide.removeValue(forKey: isLeft)
            }
            return (oldID, nextID, state.handlers)
        }

        if input.nativeDevice != nil, matches.count > 1 {
            JamLog.errorThrottled(
                .sense,
                key: "native.connection.unmatched.\(isLeft)",
                interval: 2,
                "Game Controller \(input.nativeDevice?.name ?? "Sense") has no unique managed \(isLeft ? "left" : "right") Sense device"
            )
        }

        guard let change else { return }
        if let oldID = change.old {
            change.handler.connectionChanged(false, input.nativeDevice?.name, oldID)
            JamLog.info(.sense, "Game Controller input unavailable for managed device \(oldID)")
        }
        if let newID = change.new {
            change.handler.connectionChanged(true, input.nativeDevice?.name, newID)
            JamLog.info(.sense, "Game Controller input ready for managed device \(newID)")
        }
    }

    private func removeReadyDevice(id: String) {
        let removed = locked { state -> (name: String?, handler: InputDeviceBackendEventHandlers)? in
            guard let entry = state.readyDeviceIDsBySide.first(where: { $0.value == id }) else {
                return nil
            }
            state.readyDeviceIDsBySide.removeValue(forKey: entry.key)
            return (state.nativeDevicesBySide[entry.key]?.name, state.handlers)
        }
        guard let removed else { return }
        removed.handler.connectionChanged(false, removed.name, id)
        JamLog.info(.sense, "Game Controller input unavailable for managed device \(id)")
    }

    private func locked<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
