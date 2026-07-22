import Foundation
import QuartzCore
@preconcurrency import GameController

struct SenseGameControllerDevice: Equatable, Sendable {
    let name: String
    let isLeft: Bool
}

struct SenseGameControllerInputFrame: Sendable {
    let device: SenseGameControllerDevice
    let bytes: [UInt8]
    let gyroX: Int16
    let gyroY: Int16
    let gyroZ: Int16
    let accelX: Int16
    let accelY: Int16
    let accelZ: Int16
    let timestamp: TimeInterval
}

struct SenseGameControllerSessionHandlers: Sendable {
    let connectionChanged: @Sendable (_ connected: Bool, _ device: SenseGameControllerDevice) -> Void
    let inputFrame: @Sendable (SenseGameControllerInputFrame) -> Void

    static let none = SenseGameControllerSessionHandlers(
        connectionChanged: { _, _ in },
        inputFrame: { _ in }
    )
}

/// Owns PS VR2 Sense input through Apple's Game Controller framework. IOKit is
/// retained only for stable physical-device discovery and identity; opening the
/// raw Sense HID device causes its Bluetooth session to terminate on macOS.
protocol SenseGameControllerSessioning: AnyObject, Sendable {
    func setEventHandlers(_ handlers: SenseGameControllerSessionHandlers)
    func start()
    func stop()
}

final class SenseGameControllerSession: SenseGameControllerSessioning, @unchecked Sendable {
    private struct ActivityWindow {
        var startedAt: TimeInterval
        var motionCallbacks = 0
        var elementChanges = 0
    }

    private let lock = NSLock()
    private var isStarted = false
    private var observerTokens: [NSObjectProtocol] = []
    private var controllers: [ObjectIdentifier: GCController] = [:]
    private var activity: [ObjectIdentifier: ActivityWindow] = [:]
    private var handlers = SenseGameControllerSessionHandlers.none

    func setEventHandlers(_ handlers: SenseGameControllerSessionHandlers) {
        lock.lock()
        self.handlers = handlers
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        // JamCon is a menu-bar utility, so it normally is not the frontmost
        // application. Without this, Game Controller suppresses callbacks.
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default
        let connectedToken = center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.handleConnected(controller)
        }
        let disconnectedToken = center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.handleDisconnected(controller)
        }

        lock.lock()
        if isStarted {
            observerTokens = [connectedToken, disconnectedToken]
            lock.unlock()
        } else {
            lock.unlock()
            center.removeObserver(connectedToken)
            center.removeObserver(disconnectedToken)
            return
        }

        // Querying the current set is one of the two initialization paths Apple
        // requires. Notifications cover controllers that connect afterward.
        let currentControllers = GCController.controllers()
        for controller in currentControllers {
            handleConnected(controller)
        }
        GCController.startWirelessControllerDiscovery { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldLog = self.isStarted
            self.lock.unlock()
            if shouldLog {
                JamLog.info(.sense, "Game Controller wireless discovery completed")
            }
        }
        JamLog.info(
            .sense,
            "Game Controller session started (currentControllers=\(currentControllers.count), "
                + "backgroundEvents=enabled, wirelessDiscovery=started)"
        )
    }

    func stop() {
        let retained: (tokens: [NSObjectProtocol], controllers: [GCController])
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        retained = (observerTokens, Array(controllers.values))
        observerTokens.removeAll(keepingCapacity: true)
        controllers.removeAll(keepingCapacity: true)
        activity.removeAll(keepingCapacity: true)
        lock.unlock()

        let center = NotificationCenter.default
        for token in retained.tokens {
            center.removeObserver(token)
        }
        GCController.stopWirelessControllerDiscovery()
        for controller in retained.controllers {
            controller.physicalInputProfile.valueDidChangeHandler = nil
            if let motion = controller.motion {
                motion.valueChangedHandler = nil
                if motion.sensorsRequireManualActivation {
                    motion.sensorsActive = false
                }
            }
        }
        JamLog.info(.sense, "Game Controller session stopped")
    }

    private func handleConnected(_ controller: GCController) {
        let vendorName = controller.vendorName ?? "Unknown"
        let category = controller.productCategory
        let identityText = "\(vendorName) \(category)".lowercased()
        guard identityText.contains("sense") || identityText.contains("psvr2") else {
            return
        }
        guard let isLeft = Self.controllerSide(from: identityText) else {
            JamLog.error(.sense, "Ignoring Game Controller Sense device with unknown side: \(vendorName)")
            return
        }
        let device = SenseGameControllerDevice(name: vendorName, isLeft: isLeft)

        let identifier = ObjectIdentifier(controller)
        let connectionHandler: @Sendable (Bool, SenseGameControllerDevice) -> Void
        lock.lock()
        guard isStarted, controllers[identifier] == nil else {
            lock.unlock()
            return
        }
        controllers[identifier] = controller
        activity[identifier] = ActivityWindow(startedAt: CACurrentMediaTime())
        connectionHandler = handlers.connectionChanged
        lock.unlock()

        controller.physicalInputProfile.valueDidChangeHandler = { [weak self] _, _ in
            self?.recordElementChange(for: identifier)
        }

        let motion = controller.motion
        if let motion {
            motion.valueChangedHandler = { [weak self] _ in
                self?.recordMotionCallback(for: identifier, controller: controller, device: device)
            }
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
        }

        let buttonNames = controller.physicalInputProfile.buttons.keys.sorted().joined(separator: ",")
        let dpadNames = controller.physicalInputProfile.dpads.keys.sorted().joined(separator: ",")
        JamLog.info(
            .sense,
            "Game Controller connected: \(vendorName) category=\(category) "
                + "motion=\(motion != nil) "
                + "manualSensorActivation=\(motion?.sensorsRequireManualActivation ?? false) "
                + "rotationRate=\(motion?.hasRotationRate ?? false) "
                + "buttons=[\(buttonNames)] dpads=[\(dpadNames)]"
        )
        connectionHandler(true, device)
    }

    private func handleDisconnected(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        let summary: ActivityWindow?
        let connectionHandler: @Sendable (Bool, SenseGameControllerDevice) -> Void
        lock.lock()
        let wasTracked = controllers.removeValue(forKey: identifier) != nil
        summary = activity.removeValue(forKey: identifier)
        connectionHandler = handlers.connectionChanged
        lock.unlock()
        guard wasTracked else { return }

        controller.physicalInputProfile.valueDidChangeHandler = nil
        controller.motion?.valueChangedHandler = nil

        let duration = summary.map { max(0, CACurrentMediaTime() - $0.startedAt) } ?? 0
        JamLog.info(
            .sense,
            "Game Controller disconnected: \(controller.vendorName ?? controller.productCategory) "
                + "duration=\(String(format: "%.2f", duration))s "
                + "motionCallbacks=\(summary?.motionCallbacks ?? 0) "
                + "elementChanges=\(summary?.elementChanges ?? 0)"
        )
        let identityText = "\(controller.vendorName ?? "") \(controller.productCategory)".lowercased()
        if let isLeft = Self.controllerSide(from: identityText) {
            connectionHandler(
                false,
                SenseGameControllerDevice(
                    name: controller.vendorName ?? controller.productCategory,
                    isLeft: isLeft
                )
            )
        }
    }

    private func recordElementChange(for identifier: ObjectIdentifier) {
        lock.lock()
        if activity[identifier] != nil {
            activity[identifier]?.elementChanges += 1
        }
        lock.unlock()
    }

    private func recordMotionCallback(
        for identifier: ObjectIdentifier,
        controller: GCController,
        device: SenseGameControllerDevice
    ) {
        let summary: ActivityWindow?
        let now = CACurrentMediaTime()
        let inputHandler: @Sendable (SenseGameControllerInputFrame) -> Void

        lock.lock()
        guard var window = activity[identifier] else {
            lock.unlock()
            return
        }
        window.motionCallbacks += 1
        let windowDuration = now - window.startedAt
        if windowDuration >= 5 {
            summary = window
            activity[identifier] = ActivityWindow(startedAt: now)
        } else {
            summary = nil
            activity[identifier] = window
        }
        inputHandler = handlers.inputFrame
        lock.unlock()

        if let frame = Self.makeInputFrame(controller: controller, device: device, timestamp: now) {
            inputHandler(frame)
        }

        guard let summary else { return }
        let sampleDuration = max(0.001, now - summary.startedAt)
        JamLog.info(
            .health,
            "device=sense.game-controller:\(device.name) window=\(String(format: "%.1f", sampleDuration))s "
                + "motionCallbacks=\(summary.motionCallbacks) "
                + "motionRate=\(String(format: "%.1f", Double(summary.motionCallbacks) / sampleDuration))/s "
                + "elementChanges=\(summary.elementChanges)"
        )
    }

    private static func controllerSide(from identity: String) -> Bool? {
        if identity.contains("(l)") || identity.contains(" left") { return true }
        if identity.contains("(r)") || identity.contains(" right") { return false }
        return nil
    }

    private static func makeInputFrame(
        controller: GCController,
        device: SenseGameControllerDevice,
        timestamp: TimeInterval
    ) -> SenseGameControllerInputFrame? {
        guard let motion = controller.motion, motion.hasRotationRate else { return nil }

        let profile = controller.physicalInputProfile
        let mapping = SenseButtonMapping(isLeft: device.isLeft)
        var bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        bytes[0] = UInt8(SenseHIDProtocol.inputReportID)

        func isPressed(_ name: String) -> Bool {
            profile.buttons[name]?.isPressed ?? false
        }
        func setPressed(_ pressed: Bool, at location: ButtonLocation) {
            guard pressed else { return }
            bytes[location.byte] |= location.mask
        }

        // Apple's spatial-controller profile uses A/B for the two face buttons
        // on either hand and exposes the physical grip as a normal button.
        setPressed(isPressed("Button B"), at: mapping.faceTopButton)
        setPressed(isPressed("Button A"), at: mapping.faceBottomButton)
        setPressed(isPressed("Grip"), at: mapping.bumperButton)
        setPressed(isPressed("Thumbstick Button"), at: mapping.stickClickButton)
        setPressed(isPressed("Button Menu"), at: mapping.menuButton)
        setPressed(isPressed("Button Home"), at: mapping.playstationButton)

        let trigger = profile.buttons["Trigger"]?.value ?? 0
        bytes[mapping.triggerByte] = normalizedByte(Double(trigger), center: 0, scale: 255)

        if let stick = profile.dpads["Thumbstick"] {
            bytes[mapping.joystickXByte] = normalizedByte(Double(stick.xAxis.value), center: 128, scale: 127)
            // Game Controller uses positive Y for up; the HID report uses the
            // conventional top-to-bottom byte axis.
            bytes[mapping.joystickYByte] = normalizedByte(-Double(stick.yAxis.value), center: 128, scale: 127)
        } else {
            bytes[mapping.joystickXByte] = 128
            bytes[mapping.joystickYByte] = 128
        }

        if let battery = controller.battery {
            bytes[SenseHIDProtocol.Offset.battery] = UInt8(
                clamping: Int((Double(battery.batteryLevel) * 10).rounded())
            )
        }

        let rotation = motion.rotationRate
        let acceleration = motion.acceleration
        return SenseGameControllerInputFrame(
            device: device,
            bytes: bytes,
            gyroX: gyroRawValue(radiansPerSecond: rotation.x),
            gyroY: gyroRawValue(radiansPerSecond: rotation.y),
            gyroZ: gyroRawValue(radiansPerSecond: rotation.z),
            accelX: accelerometerRawValue(g: acceleration.x),
            accelY: accelerometerRawValue(g: acceleration.y),
            accelZ: accelerometerRawValue(g: acceleration.z),
            timestamp: timestamp
        )
    }

    private static func normalizedByte(_ value: Double, center: Double, scale: Double) -> UInt8 {
        UInt8(clamping: Int((center + value * scale).rounded()))
    }

    private static func gyroRawValue(radiansPerSecond: Double) -> Int16 {
        let degreesPerSecond = radiansPerSecond * 180 / .pi
        let raw = degreesPerSecond / SenseHIDProtocol.defaultGyroScale
        return Int16(clamping: Int(raw.rounded()))
    }

    private static func accelerometerRawValue(g: Double) -> Int16 {
        Int16(clamping: Int((g * SenseHIDProtocol.accelerometerScale).rounded()))
    }
}
