import Foundation
import CoreGraphics
import AppKit
import os

/// The real-time input processing engine
/// This is WORLD 1 - has NO knowledge of SwiftUI, @Published, or ObservableObject
/// Processes HID input and drives mouse/keyboard output
final class InputEngine {

    // MARK: - Dependencies

    private let settings: SettingsStore
    private let debugBuffer: DebugBuffer

    // MARK: - Controllers

    let psvr2Controller: PSVR2Controller
    let joyConController: JoyConHIDController
    private let mouseController: MouseController
    private let gyroProcessor: GyroProcessor
    private let actionExecutor: ActionExecutor

    // MARK: - Button State (Internal - not observable)

    private var buttonStates: [Bool]
    private var previousButtonStates: [Bool]
    private var previousTriggerPressed: Bool = false

    // Hold detection
    private struct ButtonPressState {
        let pressTime: Date
        let actions: ButtonActions
        var holdFired: Bool = false
    }
    private var buttonPressStates: [ButtonPressState?]
    private var holdTimers: [DispatchWorkItem?]
    private let holdQueue = DispatchQueue(label: "PSVR2Gyro.holdQueue", qos: .userInitiated)

    // Gyro mode tracking
    private var dragButtonHeld: Bool = false
    private var scrollButtonHeld: Bool = false
    private var radialMenuButtonHeld: Bool = false

    // Cached button mappings (avoid allocation on hot path)
    private let leftMapping = PSVR2ButtonMapping(isLeft: true)
    private let rightMapping = PSVR2ButtonMapping(isLeft: false)

    // Joy-Con button state
    private var joyConButtonStates: [Bool]
    private var joyConPreviousButtonStates: [Bool]
    private var joyConButtonPressStates: [ButtonPressState?]
    private var joyConHoldTimers: [DispatchWorkItem?]
    private let joyConLeftMapping = JoyConButtonMapping(isLeft: true)
    private let joyConRightMapping = JoyConButtonMapping(isLeft: false)

    // MARK: - Radial Menu State (Internal)

    private var radialMenuPosition: CGPoint = .zero
    private var radialMenuAnchor: CGPoint = .zero
    private var radialMenuAccumulator: CGPoint = .zero

    // MARK: - Radial Menu UI Callback

    /// Called when radial menu should show/hide - UI can observe this
    /// This is the ONLY callback to UI, and it's for radial menu overlay
    var onRadialMenuShow: ((_ position: CGPoint, _ configuration: RadialMenuConfiguration) -> Void)?
    var onRadialMenuHide: ((_ selectedItem: RadialMenuItem?) -> Void)?
    var onRadialMenuUpdate: ((_ delta: CGPoint) -> Void)?

    // MARK: - Connection Callbacks (for UI to update controller list)

    var onControllerListChanged: (() -> Void)?
    var onConnectionChanged: ((_ connected: Bool, _ name: String?, _ kind: ControllerKind) -> Void)?

    // MARK: - Battery Level (thread-safe, polled by UI)

    private let batteryLock = OSAllocatedUnfairLock()
    private var _batteryLevel: Int = 0

    /// Current battery level (0-100), thread-safe for polling
    var batteryLevel: Int {
        batteryLock.withLock { _batteryLevel }
    }

    private func updateBatteryLevel(_ level: Int) {
        batteryLock.withLock { _batteryLevel = level }
    }

    // MARK: - Running State

    private var isRunning: Bool = false

    // MARK: - Initialization

    init(settings: SettingsStore, debugBuffer: DebugBuffer) {
        self.settings = settings
        self.debugBuffer = debugBuffer

        // Initialize controllers
        self.psvr2Controller = PSVR2Controller()
        self.joyConController = JoyConHIDController()
        self.mouseController = MouseController()
        self.gyroProcessor = GyroProcessor()
        self.actionExecutor = ActionExecutor(mouseController: mouseController)

        // Initialize PSVR2 button state arrays
        let buttonCount = LogicalButton.allCases.count
        self.buttonStates = Array(repeating: false, count: buttonCount)
        self.previousButtonStates = Array(repeating: false, count: buttonCount)
        self.buttonPressStates = Array(repeating: nil, count: buttonCount)
        self.holdTimers = Array(repeating: nil, count: buttonCount)

        // Initialize Joy-Con button state arrays
        let joyConButtonCount = JoyConLogicalButton.count
        self.joyConButtonStates = Array(repeating: false, count: joyConButtonCount)
        self.joyConPreviousButtonStates = Array(repeating: false, count: joyConButtonCount)
        self.joyConButtonPressStates = Array(repeating: nil, count: joyConButtonCount)
        self.joyConHoldTimers = Array(repeating: nil, count: joyConButtonCount)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        setupCallbacks()

        // Load preferred controller IDs from UserDefaults
        if let savedID = UserDefaults.standard.string(forKey: "lastSelectedControllerID") {
            psvr2Controller.preferredControllerID = savedID
        }
        if let savedJoyCon = UserDefaults.standard.string(forKey: "lastSelectedJoyConControllerID") {
            joyConController.preferredControllerID = savedJoyCon
        }

        psvr2Controller.start()
        joyConController.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        psvr2Controller.stop()
        joyConController.stop()

        // Cancel all hold timers
        for timer in holdTimers {
            timer?.cancel()
        }
        for timer in joyConHoldTimers {
            timer?.cancel()
        }
    }

    // MARK: - Controller Selection

    func selectController(id: String, kind: ControllerKind, isLeft: Bool) {
        settings.update {
            $0.activeControllerKind = kind
            $0.isLeftController = isLeft
            $0.isEnabled = true
        }

        switch kind {
        case .psvr2:
            UserDefaults.standard.set(id, forKey: "lastSelectedControllerID")
            psvr2Controller.selectController(id: id)
        case .joyCon:
            UserDefaults.standard.set(id, forKey: "lastSelectedJoyConControllerID")
            joyConController.selectController(id: id)
        }
    }

    func deselectController() {
        // Disable input processing
        settings.update {
            $0.isEnabled = false
        }

        // Clear saved preferences
        UserDefaults.standard.removeObject(forKey: "lastSelectedControllerID")
        UserDefaults.standard.removeObject(forKey: "lastSelectedJoyConControllerID")

        // Deselect in HID controllers
        psvr2Controller.deselectController()
        joyConController.deselectController()

        // Reset battery
        updateBatteryLevel(0)
    }

    /// Get list of available controllers
    var availableControllers: [ControllerInfo] {
        let psvr2Infos = psvr2Controller.discoveredControllers.map { $0.info }
        let joyInfos = joyConController.discoveredControllers.map { $0.info }
        return psvr2Infos + joyInfos
    }

    /// Current connection state
    var isConnected: Bool {
        psvr2Controller.isConnected || joyConController.isConnected
    }

    /// Current controller name
    var connectedControllerName: String? {
        if psvr2Controller.isConnected {
            return psvr2Controller.controllerName
        } else if joyConController.isConnected {
            return joyConController.controllerName
        }
        return nil
    }

    /// Current selected controller ID
    var selectedControllerID: String? {
        if psvr2Controller.isConnected {
            return psvr2Controller.selectedControllerID
        } else if joyConController.isConnected {
            return joyConController.selectedControllerID
        }
        return nil
    }

    /// Recalibrate the gyro
    func recalibrate() {
        gyroProcessor.reset()
    }

    // MARK: - Callbacks Setup

    private func setupCallbacks() {
        // PSVR2 Controller
        psvr2Controller.onReportData = { [weak self] report in
            self?.processPSVR2Report(report)
        }

        psvr2Controller.onConnectionChange = { [weak self] connected, name, _ in
            self?.onConnectionChanged?(connected, name, .psvr2)
        }

        psvr2Controller.onControllersChanged = { [weak self] in
            self?.onControllerListChanged?()
        }

        psvr2Controller.onDebugMessage = { [weak self] message in
            self?.debugBuffer.log("[PSVR2] \(message)")
        }

        // Joy-Con Controller
        joyConController.onReportData = { [weak self] report in
            self?.processJoyConReport(report)
        }

        joyConController.onConnectionChange = { [weak self] connected, name, _ in
            self?.onConnectionChanged?(connected, name, .joyCon)
        }

        joyConController.onControllersChanged = { [weak self] in
            self?.onControllerListChanged?()
        }

        joyConController.onDebugMessage = { [weak self] message in
            self?.debugBuffer.log("[JoyCon] \(message)")
        }
    }

    // MARK: - PSVR2 Report Processing

    private func processPSVR2Report(_ report: PSVR2Controller.InputReport) {
        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        // Only process if this controller type is active
        guard s.activeControllerKind == .psvr2 else { return }
        guard s.isEnabled else { return }

        let mapping = s.isLeftController ? leftMapping : rightMapping

        // 1. Process buttons (updates internal state, fires actions)
        processButtonActions(
            bytes: report.bytes,
            mapping: mapping,
            profile: s.buttonMappingProfile,
            triggerThreshold: s.triggerThreshold,
            holdThreshold: s.holdThreshold
        )

        // 2. Process joystick scroll if enabled
        if s.joystickScrollEnabled {
            processJoystickScroll(bytes: report.bytes, mapping: mapping, settings: s)
        }

        // 3. Process gyro through unified remap → process pipeline
        let pipeline = GyroRemapper.process(
            rawX: report.gyroX,
            rawY: report.gyroY,
            rawZ: report.gyroZ,
            controllerKind: .psvr2
        )
        var gyroSettings = s.toGyroSettingsState()
        gyroSettings.gyroScale = effectiveGyroScale(for: .psvr2, userScale: s.gyroScale)
        gyroSettings.expectedSampleRate = 60.0
        gyroSettings.biasMotionThreshold = 50.0
        if let (dx, dy) = gyroProcessor.process(
            rawX: pipeline.remapped.pitch,
            rawY: pipeline.remapped.yaw,
            rawZ: pipeline.remapped.roll,
            timestamp: report.timestamp,
            settings: gyroSettings
        ) {
            routeGyroMovement(dx: dx, dy: dy, profile: s.buttonMappingProfile, configuration: s.radialMenuConfiguration)
        }

        // 4. Update battery level (from byte 43)
        if report.bytes.count > PSVR2HIDProtocol.Offset.battery {
            let batteryByte = report.bytes[PSVR2HIDProtocol.Offset.battery]
            updateBatteryLevel(BatteryHelper.level(from: batteryByte))
        }

        // 5. Record to debug buffer with all pipeline stages
        debugBuffer.record(
            bytes: report.bytes,
            length: report.length,
            rawGyro: pipeline.raw,
            remappedGyro: pipeline.remapped,
            normalizedGyro: pipeline.normalized,
            accel: (report.accelX, report.accelY, report.accelZ),
            buttonStates: buttonStates,
            controllerKind: .psvr2
        )
    }

    // MARK: - Joy-Con Report Processing

    private func processJoyConReport(_ report: JoyConHIDController.InputReport) {
        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        // Only process if this controller type is active
        guard s.activeControllerKind == .joyCon else { return }
        guard s.isEnabled else { return }

        // Keep Joy-Con timing mode in sync with settings
        joyConController.useTimerFallback = s.joyConTimerFallbackEnabled
        joyConController.useTimerHybrid = s.joyConTimerHybridEnabled

        let joyConMapping = s.isLeftController ? joyConLeftMapping : joyConRightMapping

        // 1. Process Joy-Con buttons
        processJoyConButtonActions(
            bytes: report.bytes,
            mapping: joyConMapping,
            profile: s.joyConButtonMappingProfile,
            holdThreshold: s.joyConButtonMappingProfile.holdThreshold
        )

        // 2. Process gyro through unified pipeline
        // GyroRemapper handles the axis swapping for Joy-Con
        let pipeline = GyroRemapper.process(
            rawX: report.gyroX,
            rawY: report.gyroY,
            rawZ: report.gyroZ,
            controllerKind: .joyCon
        )

        // Pass remapped values to gyro processor (which expects pitch in X, yaw in Y)
        var gyroSettings = s.toGyroSettingsState()
        gyroSettings.gyroScale = effectiveGyroScale(for: .joyCon, userScale: s.gyroScale)
        gyroSettings.expectedSampleRate = 66.0  // ~66 Hz since we use only the newest sample per packet
        gyroSettings.biasMotionThreshold = 30.0 // Joy-Con has lower noise floor; tighten bias capture
        if let (dx, dy) = gyroProcessor.process(
            rawX: pipeline.remapped.pitch,
            rawY: pipeline.remapped.yaw,
            rawZ: pipeline.remapped.roll,
            timestamp: report.timestamp,
            settings: gyroSettings
        ) {
            routeJoyConGyroMovement(dx: dx, dy: dy, profile: s.joyConButtonMappingProfile, configuration: s.radialMenuConfiguration)
        }

        // 3. Process joystick scroll (if enabled)
        if s.joystickScrollEnabled {
            processJoyConJoystickScroll(bytes: report.bytes, mapping: joyConMapping, settings: s)
        }

        // 4. Update battery level (Joy-Con battery is in byte 2, upper nibble)
        if report.bytes.count > 2 {
            updateBatteryLevel(BatteryHelper.joyConLevel(from: report.bytes[2]))
        }

        // 4. Record to debug buffer with all pipeline stages
        debugBuffer.record(
            bytes: report.bytes,
            length: report.length,
            rawGyro: pipeline.raw,
            remappedGyro: pipeline.remapped,
            normalizedGyro: pipeline.normalized,
            accel: (report.accelX, report.accelY, report.accelZ),
            buttonStates: joyConButtonStates,
            controllerKind: .joyCon
        )
    }

    // MARK: - Shared gyro scaling

    /// Apply the user scale as a multiplier relative to the PSVR2 reference scale so both controllers share the same pipeline.
    private func effectiveGyroScale(for kind: ControllerKind, userScale: Double) -> Double {
        let reference = GyroRemapper.gyroScale(for: .psvr2)
        let deviceScale = GyroRemapper.gyroScale(for: kind)
        let rawMultiplier = reference != 0 ? (userScale / reference) : 1.0
        let userMultiplier = min(4.0, max(0.25, rawMultiplier))  // clamp to a sane range
        return deviceScale * userMultiplier
    }

    // MARK: - Gyro Mode Routing

    private enum GyroMode {
        case none       // No cursor movement (drag mapped but not held)
        case normal     // Normal cursor movement
        case drag       // Drag button held
        case scroll     // Scroll button held
        case radialMenu // Radial menu active
    }

    private func currentGyroMode(profile: PSVR2ButtonMappingProfile) -> GyroMode {
        if radialMenuButtonHeld { return .radialMenu }
        if scrollButtonHeld { return .scroll }
        if dragButtonHeld { return .drag }
        if profile.hasDragMapping { return .none }
        return .normal
    }

    private func routeGyroMovement(dx: CGFloat, dy: CGFloat, profile: PSVR2ButtonMappingProfile, configuration: RadialMenuConfiguration) {
        let mode = currentGyroMode(profile: profile)

        switch mode {
        case .none:
            break
        case .normal, .drag:
            mouseController.moveRelative(dx: dx, dy: dy)
        case .scroll:
            mouseController.scroll(dx: dx, dy: dy)
        case .radialMenu:
            radialMenuAccumulator.x += dx
            radialMenuAccumulator.y += dy
            onRadialMenuUpdate?(CGPoint(x: dx, y: dy))
        }
    }

    // Joy-Con gyro mode routing (uses JoyConButtonMappingProfile)
    private func currentJoyConGyroMode(profile: JoyConButtonMappingProfile) -> GyroMode {
        if radialMenuButtonHeld { return .radialMenu }
        if scrollButtonHeld { return .scroll }
        if dragButtonHeld { return .drag }
        if profile.hasDragMapping { return .none }
        return .normal
    }

    private func routeJoyConGyroMovement(dx: CGFloat, dy: CGFloat, profile: JoyConButtonMappingProfile, configuration: RadialMenuConfiguration) {
        let mode = currentJoyConGyroMode(profile: profile)

        switch mode {
        case .none:
            break
        case .normal, .drag:
            mouseController.moveRelative(dx: dx, dy: dy)
        case .scroll:
            mouseController.scroll(dx: dx, dy: dy)
        case .radialMenu:
            radialMenuAccumulator.x += dx
            radialMenuAccumulator.y += dy
            onRadialMenuUpdate?(CGPoint(x: dx, y: dy))
        }
    }

    // MARK: - Joystick Scroll

    private func processJoystickScroll(bytes: [UInt8], mapping: PSVR2ButtonMapping, settings: SettingsStore.InputSettings) {
        let joystickPos = mapping.joystickPosition(in: bytes)
        let deadzone: Double = 20.0
        let center: Double = 128.0
        let maxDelta: Double = 127.0

        let deltaX = Double(joystickPos.x) - center
        let deltaY = Double(joystickPos.y) - center

        if abs(deltaX) > deadzone || abs(deltaY) > deadzone {
            let speed = settings.joystickScrollSpeed

            func scaled(_ delta: Double) -> CGFloat {
                let sign = delta >= 0 ? 1.0 : -1.0
                let normalized = min(1.0, abs(delta) / maxDelta)
                let curved = normalized * normalized
                return CGFloat(sign * curved * speed * 2.0)
            }

            let scrollX = scaled(deltaX)
            let scrollY = scaled(deltaY)
            mouseController.scroll(dx: scrollX, dy: scrollY)
        }
    }

    private func processJoyConJoystickScroll(bytes: [UInt8], mapping: JoyConButtonMapping, settings: SettingsStore.InputSettings) {
        let joystickPos = mapping.joystickPosition(in: bytes)
        let deadzone: Double = 20.0
        let center: Double = 128.0
        let maxDelta: Double = 127.0

        let deltaX = Double(joystickPos.x) - center
        let deltaY = -(Double(joystickPos.y) - center)  // Invert Y for natural scroll direction

        if abs(deltaX) > deadzone || abs(deltaY) > deadzone {
            let speed = settings.joystickScrollSpeed

            func scaled(_ delta: Double) -> CGFloat {
                let sign = delta >= 0 ? 1.0 : -1.0
                let normalized = min(1.0, abs(delta) / maxDelta)
                let curved = normalized * normalized
                return CGFloat(sign * curved * speed * 2.0)
            }

            let scrollX = scaled(deltaX)
            let scrollY = scaled(deltaY)
            mouseController.scroll(dx: scrollX, dy: scrollY)
        }
    }

    // MARK: - Button Processing

    private func processButtonActions(
        bytes: [UInt8],
        mapping: PSVR2ButtonMapping,
        profile: PSVR2ButtonMappingProfile,
        triggerThreshold: UInt8,
        holdThreshold: Double
    ) {
        // Process all digital buttons
        for button in LogicalButton.allCases where button != .trigger {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = previousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = profile.actions(for: button)
                if isPressed {
                    handleButtonDown(button: button, actions: actions, holdThreshold: holdThreshold)
                } else {
                    handleButtonUp(button: button)
                }
            }

            previousButtonStates[idx] = isPressed
            buttonStates[idx] = isPressed
        }

        // Handle trigger with threshold
        let triggerValue = mapping.triggerValue(in: bytes)
        let triggerPressed = triggerValue >= triggerThreshold

        if triggerPressed != previousTriggerPressed {
            let actions = profile.actions(for: .trigger)
            if triggerPressed {
                handleButtonDown(button: .trigger, actions: actions, holdThreshold: holdThreshold)
            } else {
                handleButtonUp(button: .trigger)
            }
        }

        previousTriggerPressed = triggerPressed
        buttonStates[LogicalButton.trigger.index] = triggerPressed
    }

    private func handleButtonDown(button: LogicalButton, actions: ButtonActions, holdThreshold: Double) {
        let idx = button.index

        // Handle gyro mode actions immediately
        if actions.pressIsGyroMode {
            switch actions.press {
            case .drag:
                dragButtonHeld = true
            case .scroll:
                scrollButtonHeld = true
            case .radialMenu:
                radialMenuButtonHeld = true
                radialMenuAccumulator = .zero
                let position = NSEvent.mouseLocation
                let config = settings.snapshot().radialMenuConfiguration
                onRadialMenuShow?(position, config)
                mouseController.hideCursor()
            default:
                break
            }
            return
        }

        // Handle mouse clicks immediately
        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true)
            buttonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)
            return
        }

        // Record press state
        buttonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)

        // Schedule hold timer if there's a hold action
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard var state = self.buttonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                self.buttonPressStates[idx] = state
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            holdTimers[idx]?.cancel()
            holdTimers[idx] = timer
            holdQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    private func handleButtonUp(button: LogicalButton) {
        let idx = button.index

        // Cancel hold timer
        holdTimers[idx]?.cancel()
        holdTimers[idx] = nil

        // Check for gyro mode button release
        if let state = buttonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(action: state.actions.press)
            buttonPressStates[idx] = nil
            return
        }

        // Also check current mapping for gyro modes
        let profile = settings.snapshot().buttonMappingProfile
        let actions = profile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(action: actions.press)
            return
        }

        guard let state = buttonPressStates[idx] else { return }

        // Handle mouse click release
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false)
            buttonPressStates[idx] = nil
            return
        }

        if state.holdFired {
            // Hold action was executed, release it
            actionExecutor.execute(state.actions.hold, isPressed: false)
        } else {
            // Hold didn't fire, execute press action as tap
            if state.actions.press != .none {
                actionExecutor.execute(state.actions.press, isPressed: true)
                actionExecutor.execute(state.actions.press, isPressed: false)
            }
        }

        buttonPressStates[idx] = nil
    }

    private func handleGyroModeRelease(action: ButtonAction) {
        switch action {
        case .drag:
            dragButtonHeld = false
        case .scroll:
            scrollButtonHeld = false
        case .radialMenu:
            radialMenuButtonHeld = false
            mouseController.showCursor()

            // Determine selected item based on accumulated movement
            let selectedItem = calculateRadialMenuSelection()
            onRadialMenuHide?(selectedItem)

            // Execute the selected action
            if let item = selectedItem {
                executeRadialMenuAction(item.action)
            }
        default:
            break
        }
    }

    // MARK: - Joy-Con Button Processing

    private func processJoyConButtonActions(
        bytes: [UInt8],
        mapping: JoyConButtonMapping,
        profile: JoyConButtonMappingProfile,
        holdThreshold: Double
    ) {
        // Process all buttons available on this Joy-Con side
        let availableButtons = mapping.isLeftController ? JoyConLogicalButton.leftButtons : JoyConLogicalButton.rightButtons

        for button in availableButtons {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = joyConPreviousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = profile.actions(for: button)
                if isPressed {
                    handleJoyConButtonDown(button: button, actions: actions, holdThreshold: holdThreshold)
                } else {
                    handleJoyConButtonUp(button: button)
                }
            }

            joyConPreviousButtonStates[idx] = isPressed
            joyConButtonStates[idx] = isPressed
        }
    }

    private func handleJoyConButtonDown(button: JoyConLogicalButton, actions: ButtonActions, holdThreshold: Double) {
        let idx = button.index

        // Handle gyro mode actions immediately
        if actions.pressIsGyroMode {
            switch actions.press {
            case .drag:
                dragButtonHeld = true
            case .scroll:
                scrollButtonHeld = true
            case .radialMenu:
                radialMenuButtonHeld = true
                radialMenuAccumulator = .zero
                let position = NSEvent.mouseLocation
                let config = settings.snapshot().radialMenuConfiguration
                onRadialMenuShow?(position, config)
                mouseController.hideCursor()
            default:
                break
            }
            return
        }

        // Handle mouse clicks immediately
        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true)
            joyConButtonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)
            return
        }

        // Record press state
        joyConButtonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)

        // Schedule hold timer if there's a hold action
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard var state = self.joyConButtonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                self.joyConButtonPressStates[idx] = state
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            joyConHoldTimers[idx]?.cancel()
            joyConHoldTimers[idx] = timer
            holdQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    private func handleJoyConButtonUp(button: JoyConLogicalButton) {
        let idx = button.index

        // Cancel hold timer
        joyConHoldTimers[idx]?.cancel()
        joyConHoldTimers[idx] = nil

        // Check for gyro mode button release
        if let state = joyConButtonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(action: state.actions.press)
            joyConButtonPressStates[idx] = nil
            return
        }

        // Also check current mapping for gyro modes
        let profile = settings.snapshot().joyConButtonMappingProfile
        let actions = profile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(action: actions.press)
            return
        }

        guard let state = joyConButtonPressStates[idx] else { return }

        // Handle mouse click release
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false)
            joyConButtonPressStates[idx] = nil
            return
        }

        if state.holdFired {
            // Hold action was executed, release it
            actionExecutor.execute(state.actions.hold, isPressed: false)
        } else {
            // Hold didn't fire, execute press action as tap
            if state.actions.press != .none {
                actionExecutor.execute(state.actions.press, isPressed: true)
                actionExecutor.execute(state.actions.press, isPressed: false)
            }
        }

        joyConButtonPressStates[idx] = nil
    }

    // MARK: - Radial Menu

    private func calculateRadialMenuSelection() -> RadialMenuItem? {
        let config = settings.snapshot().radialMenuConfiguration
        let magnitude = sqrt(radialMenuAccumulator.x * radialMenuAccumulator.x + radialMenuAccumulator.y * radialMenuAccumulator.y)

        guard magnitude > config.deadzoneSize else { return nil }

        let angle = atan2(radialMenuAccumulator.y, radialMenuAccumulator.x)

        // Determine ring and item
        let outerRingEnabled = config.outerRingEnabled && !config.outerRingItems.isEmpty
        let outerRingStart = config.deadzoneSize + config.innerRingSize

        if outerRingEnabled && magnitude >= outerRingStart {
            // Outer ring
            let index = angleToIndex(angle, count: config.outerRingItems.count, rotation: config.outerRingRotation)
            return config.outerRingItems[safe: index]
        } else {
            // Inner ring
            let index = angleToIndex(angle, count: config.items.count, rotation: config.innerRingRotation)
            return config.items[safe: index]
        }
    }

    private func angleToIndex(_ angle: Double, count: Int, rotation: Double) -> Int {
        guard count > 0 else { return 0 }

        let rotationRadians = -rotation * Double.pi / 180.0
        var normalizedAngle = angle + Double.pi / 2 - rotationRadians

        let twoPi = Double.pi * 2.0
        normalizedAngle = fmod(normalizedAngle, twoPi)
        if normalizedAngle < 0 { normalizedAngle += twoPi }

        let sliceAngle = twoPi / Double(count)
        return min(Int(normalizedAngle / sliceAngle), count - 1)
    }

    private func executeRadialMenuAction(_ action: RadialMenuAction) {
        switch action {
        case .none:
            break
        case .keyPress(let combo):
            var flags = combo.eventFlags
            let arrowKeys: [UInt16] = [123, 124, 125, 126]
            if arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskNumericPad)
            }
            if flags.contains(.maskControl) && arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskSecondaryFn)
            }

            if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: true) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: false) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        case .mouseClick(let button):
            mouseController.click(button: button)
        case .systemAction(let action):
            actionExecutor.executeSystemAction(action)
        }
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
