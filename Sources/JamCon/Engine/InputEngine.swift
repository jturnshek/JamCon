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

    let senseController: SenseController
    let joyConController: JoyConHIDController
    let g502xController: G502XHIDController
    private let mouseController: MouseController
    private let senseGyroProcessor: GyroProcessor
    private let joyConGyroProcessor: GyroProcessor
    private let actionExecutor: ActionExecutor

    // MARK: - Threading

    /// Serial queue that owns all engine state mutations and input processing.
    private let engineQueue = DispatchQueue(label: "JamCon.engineQueue", qos: .userInitiated)
    private let engineQueueKey = DispatchSpecificKey<Void>()

    private func engineQueueSync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: engineQueueKey) != nil {
            return work()
        }
        return engineQueue.sync(execute: work)
    }

    private func engineQueueAsync(_ work: @escaping () -> Void) {
        engineQueue.async(execute: work)
    }

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

    // MARK: - Device Selection (managed)

    private var selectedSenseID: String?
    private var selectedSenseProfile: ControllerProfile?
    private var selectedJoyConID: String?
    private var selectedJoyConProfile: ControllerProfile?
    private var selectedMouseID: String?

    // MARK: - Gyro Mode Tracking (per kind)

    private struct GyroModeState {
        var dragButtonHeld: Bool = false
        var scrollButtonHeld: Bool = false
        var radialMenuButtonHeld: Bool = false
    }

    private var senseMode = GyroModeState()
    private var joyConMode = GyroModeState()
    private var mouseMode = GyroModeState()

    private var radialMenuOwnerKind: ControllerKind?

    // Cached button mappings (avoid allocation on hot path)
    private let leftMapping = SenseButtonMapping(isLeft: true)
    private let rightMapping = SenseButtonMapping(isLeft: false)

    // Joy-Con button state
    private var joyConButtonStates: [Bool]
    private var joyConPreviousButtonStates: [Bool]
    private var joyConButtonPressStates: [ButtonPressState?]
    private var joyConHoldTimers: [DispatchWorkItem?]
    private var joyConLeftMapping = JoyConButtonMapping(isLeft: true)
    private var joyConRightMapping = JoyConButtonMapping(isLeft: false)

    // G502X button state
    private var g502xButtonStates: [Bool]
    private var g502xPreviousButtonStates: [Bool]
    private var g502xButtonPressStates: [ButtonPressState?]
    private var g502xHoldTimers: [DispatchWorkItem?]
    private let g502xMapping = G502XButtonMapping()
    private var g502xHasPrimedButtonState: Bool = false

    // Mouse movement capture for radial menu (when using G502X)
    private let radialMenuLock = OSAllocatedUnfairLock()
    private var radialMenuCursorAnchor: CGPoint?
    private var radialMenuCursorPollTimer: DispatchSourceTimer?

    // MARK: - Radial Menu State (Internal)

    private var radialMenuPosition: CGPoint = .zero
    private var radialMenuAnchor: CGPoint = .zero
    private var radialMenuAccumulator: CGPoint = .zero

    // MARK: - Radial Menu UI Callback

    /// Called when radial menu should show/hide - UI can observe this
    /// This is the ONLY callback to UI, and it's for radial menu overlay
    var onRadialMenuShow: ((_ position: CGPoint, _ configuration: RadialMenuConfiguration, _ pointerStyle: RadialMenuPointerStyle) -> Void)?
    var onRadialMenuHide: ((_ selectedItem: RadialMenuItem?) -> Void)?
    var onRadialMenuUpdate: ((_ delta: CGPoint) -> Void)?
    var onRadialMenuSetPosition: ((_ offset: CGPoint) -> Void)?  // For mouse: absolute position

    // MARK: - Connection Callbacks (for UI to update controller list)

    var onControllerListChanged: (() -> Void)?
    var onConnectionChanged: ((_ connected: Bool, _ name: String?, _ kind: ControllerKind) -> Void)?
    var onBatteryLevelChanged: ((_ level: Int) -> Void)?

    // MARK: - Battery Level (thread-safe, polled by UI)

    private let batteryLock = OSAllocatedUnfairLock()
    private var _batteryLevel: Int = 0

    /// Current battery level (0-100), thread-safe for polling
    var batteryLevel: Int {
        batteryLock.withLock { _batteryLevel }
    }

    private func updateBatteryLevel(_ level: Int) {
        let didChange = batteryLock.withLock {
            if _batteryLevel == level {
                return false
            }
            _batteryLevel = level
            return true
        }
        if didChange {
            onBatteryLevelChanged?(level)
        }
    }

    // MARK: - Running State

    private var isRunning: Bool = false

    // MARK: - Initialization

    init(settings: SettingsStore, debugBuffer: DebugBuffer) {
        self.settings = settings
        self.debugBuffer = debugBuffer
        engineQueue.setSpecific(key: engineQueueKey, value: ())

        // Initialize controllers
        self.senseController = SenseController()
        self.joyConController = JoyConHIDController()
        self.g502xController = G502XHIDController()
        self.mouseController = MouseController()
        self.senseGyroProcessor = GyroProcessor()
        self.joyConGyroProcessor = GyroProcessor()
        self.actionExecutor = ActionExecutor(mouseController: mouseController)

        // Initialize Sense button state arrays
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

        // Initialize G502X button state arrays
        let g502xButtonCount = G502XLogicalButton.count
        self.g502xButtonStates = Array(repeating: false, count: g502xButtonCount)
        self.g502xPreviousButtonStates = Array(repeating: false, count: g502xButtonCount)
        self.g502xButtonPressStates = Array(repeating: nil, count: g502xButtonCount)
        self.g502xHoldTimers = Array(repeating: nil, count: g502xButtonCount)
    }

    // MARK: - Lifecycle

    func start() {
        let shouldStart = engineQueueSync {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard shouldStart else { return }

        setupCallbacks()

        senseController.start()
        joyConController.start()
        g502xController.start()
    }

    func stop() {
        let shouldStop = engineQueueSync {
            guard isRunning else { return false }
            isRunning = false

            // Cancel all hold timers
            for timer in holdTimers {
                timer?.cancel()
            }
            for timer in joyConHoldTimers {
                timer?.cancel()
            }
            for timer in g502xHoldTimers {
                timer?.cancel()
            }
            return true
        }
        guard shouldStop else { return }

        senseController.stop()
        joyConController.stop()
        g502xController.stop()
    }

    // MARK: - Controller Selection

    /// Enable/disable processing for a specific physical device.
    /// Selection is per-kind (Sense, Joy-Con, G502X).
    func setDeviceManaged(id: String, kind: ControllerKind, isLeft: Bool, managed: Bool) {
        engineQueueSync {
            switch kind {
            case .sense:
                if managed {
                    let profile = ControllerProfile(kind: .sense, isLeft: isLeft)
                    if selectedSenseID == id,
                       selectedSenseProfile == profile,
                       senseController.selectedControllerID == id,
                       senseController.isConnected {
                        return
                    }
                    selectedSenseID = id
                    selectedSenseProfile = profile
                    senseController.selectController(id: id)
                } else if senseController.selectedControllerID == id {
                    selectedSenseID = nil
                    selectedSenseProfile = nil
                    senseController.deselectController()
                }

            case .joyCon:
                if managed {
                    let profile = ControllerProfile(kind: .joyCon, isLeft: isLeft)
                    if selectedJoyConID == id,
                       selectedJoyConProfile == profile,
                       joyConController.selectedControllerID == id,
                       joyConController.isConnected {
                        return
                    }
                    selectedJoyConID = id
                    selectedJoyConProfile = profile
                    joyConController.selectController(id: id)
                } else if joyConController.selectedControllerID == id {
                    selectedJoyConID = nil
                    selectedJoyConProfile = nil
                    joyConController.deselectController()
                }

            case .mouse:
                if managed {
                    if selectedMouseID == id,
                       g502xController.selectedMouseID == id,
                       g502xController.isConnected {
                        return
                    }
                    selectedMouseID = id
                    resetG502XButtonStateBaseline()
                    g502xController.selectMouse(id: id)
                } else if g502xController.selectedMouseID == id {
                    selectedMouseID = nil
                    resetG502XButtonStateBaseline()
                    g502xController.deselectMouse()
                }
            }
        }
    }

    func selectController(id: String, kind: ControllerKind, isLeft: Bool) {
        settings.update { $0.activeProfile = ControllerProfile(kind: kind, isLeft: isLeft) }
        setDeviceManaged(id: id, kind: kind, isLeft: isLeft, managed: true)
    }

    func deselectController() {
        engineQueueSync {
            // Deselect in HID controllers (stop receiving input)
            senseController.deselectController()
            joyConController.deselectController()
            g502xController.deselectMouse()

            selectedSenseID = nil
            selectedSenseProfile = nil
            selectedJoyConID = nil
            selectedJoyConProfile = nil
            selectedMouseID = nil

            // Reset battery
            updateBatteryLevel(0)
        }
    }

    /// Get list of available controllers
    var availableControllers: [ControllerInfo] {
        senseController.controllerInfosSnapshot()
            + joyConController.controllerInfosSnapshot()
            + g502xController.mouseInfosSnapshot()
    }

    /// Current connection state
    var isConnected: Bool {
        senseController.isConnected || joyConController.isConnected || g502xController.isConnected
    }

    /// Current controller name
    var connectedControllerName: String? {
        if senseController.isConnected {
            return senseController.controllerName
        } else if joyConController.isConnected {
            return joyConController.controllerName
        } else if g502xController.isConnected {
            return g502xController.mouseName
        }
        return nil
    }

    /// Current selected controller ID
    var selectedControllerID: String? {
        if senseController.isConnected {
            return senseController.selectedControllerID
        } else if joyConController.isConnected {
            return joyConController.selectedControllerID
        } else if g502xController.isConnected {
            return g502xController.selectedMouseID
        }
        return nil
    }

    /// Recalibrate the gyro
    func recalibrate() {
        engineQueueSync {
            senseGyroProcessor.reset()
            joyConGyroProcessor.reset()
        }
    }

    // MARK: - Callbacks Setup

    private func setupCallbacks() {
        // Sense Controller
        senseController.onReportData = { [weak self] report in
            self?.engineQueueAsync { [weak self] in
                self?.processSenseReport(report)
            }
        }

        senseController.onConnectionChange = { [weak self] connected, name, _ in
            self?.engineQueueAsync { [weak self] in
                self?.onConnectionChanged?(connected, name, .sense)
            }
        }

        senseController.onControllersChanged = { [weak self] in
            self?.engineQueueAsync { [weak self] in
                self?.onControllerListChanged?()
            }
        }

        senseController.onDebugMessage = { [weak self] message in
            self?.debugBuffer.log("[Sense] \(message)")
        }

        // Joy-Con Controller
        joyConController.onReportData = { [weak self] report in
            self?.engineQueueAsync { [weak self] in
                self?.processJoyConReport(report)
            }
        }

        joyConController.onConnectionChange = { [weak self] connected, name, controllerID in
            self?.engineQueueAsync { [weak self] in
                guard let self else { return }

                // Reset stick calibration on reconnect so we capture the new rest position
                if connected {
                    // Determine which side based on the controller that just connected
                    if let productID = self.joyConController.productID(forControllerID: controllerID) {
                        let isLeft = productID == JoyConHIDProtocol.leftProductID
                        if isLeft {
                            self.joyConLeftMapping.calibration.reset()
                        } else {
                            self.joyConRightMapping.calibration.reset()
                        }
                    }
                }

                self.onConnectionChanged?(connected, name, .joyCon)
            }
        }

        joyConController.onControllersChanged = { [weak self] in
            self?.engineQueueAsync { [weak self] in
                self?.onControllerListChanged?()
            }
        }

        joyConController.onDebugMessage = { [weak self] message in
            self?.debugBuffer.log("[JoyCon] \(message)")
        }

        // G502X Mouse Controller
        g502xController.onReportData = { [weak self] report in
            self?.engineQueueAsync { [weak self] in
                self?.processG502XReport(report)
            }
        }

        g502xController.onConnectionChange = { [weak self] connected, name, _ in
            self?.engineQueueAsync { [weak self] in
                guard let self else { return }
                self.resetG502XButtonStateBaseline()
                self.onConnectionChanged?(connected, name, .mouse)
            }
        }

        g502xController.onControllersChanged = { [weak self] in
            self?.engineQueueAsync { [weak self] in
                self?.onControllerListChanged?()
            }
        }

        g502xController.onDebugMessage = { [weak self] message in
            self?.debugBuffer.log("[G502X] \(message)")
        }
    }

    // MARK: - Sense Report Processing

    private func processSenseReport(_ report: SenseController.InputReport) {
        guard isRunning else { return }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        guard let profile = selectedSenseProfile else { return }

        let mapping = profile.isLeft ? leftMapping : rightMapping
        let buttonProfile = s.senseButtonMappings[profile] ?? .load(for: profile)
        let cursorEnabled = s.cursorControlEnabledByProfile[profile] ?? true

        // 1. Process buttons (updates internal state, fires actions)
        processButtonActions(
            bytes: report.bytes,
            mapping: mapping,
            profile: buttonProfile,
            triggerThreshold: buttonProfile.triggerThreshold,
            holdThreshold: buttonProfile.holdThreshold
        )

        // 2. Process joystick scroll if enabled
        if s.joystickScrollEnabled, cursorEnabled {
            processJoystickScroll(bytes: report.bytes, mapping: mapping, settings: s)
        }

        // 3. Process gyro through unified remap → process pipeline
        let pipeline = GyroRemapper.process(
            rawX: report.gyroX,
            rawY: report.gyroY,
            rawZ: report.gyroZ,
            controllerKind: .sense
        )
        var gyroSettings = s.gyroSettings[.sense] ?? .defaultForKind(.sense)
        let userScale = gyroSettings.gyroScale
        gyroSettings.gyroScale = effectiveGyroScale(for: .sense, userScale: userScale)
        gyroSettings.expectedSampleRate = 60.0
        gyroSettings.biasMotionThreshold = 50.0
        if let (dx, dy) = senseGyroProcessor.process(
            rawX: pipeline.remapped.pitch,
            rawY: pipeline.remapped.yaw,
            rawZ: pipeline.remapped.roll,
            timestamp: report.timestamp,
            settings: gyroSettings
        ) {
            routeGyroMovement(
                kind: .sense,
                dx: dx,
                dy: dy,
                cursorEnabled: cursorEnabled,
                hasDragMapping: buttonProfile.hasDragMapping,
                configuration: s.radialMenuConfiguration,
                modeState: senseMode
            )
        }

        // 4. Update battery level (from byte 43)
        if report.bytes.count > SenseHIDProtocol.Offset.battery {
            let batteryByte = report.bytes[SenseHIDProtocol.Offset.battery]
            updateBatteryLevel(BatteryHelper.level(from: batteryByte))
        }

        // 5. Record to debug buffer with all pipeline stages
        if s.debugRecordingEnabled && (s.debugRecordingTargetKind == nil || s.debugRecordingTargetKind == .sense) {
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: pipeline.raw,
                remappedGyro: pipeline.remapped,
                normalizedGyro: pipeline.normalized,
                accel: (report.accelX, report.accelY, report.accelZ),
                buttonStates: buttonStates,
                controllerKind: .sense,
                gyroDebug: mapGyroDebug(from: senseGyroProcessor.lastDebugState)
            )
        }
    }

    // MARK: - Joy-Con Report Processing

    private func processJoyConReport(_ report: JoyConHIDController.InputReport) {
        guard isRunning else { return }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        guard let profile = selectedJoyConProfile else { return }

        // Keep Joy-Con timing mode in sync with settings
        joyConController.useTimerFallback = s.joyConTimerFallbackEnabled
        joyConController.useTimerHybrid = s.joyConTimerHybridEnabled

        // Get the appropriate mapping (mutable reference for calibration)
        let isLeft = profile.isLeft
        let buttonProfile: JoyConButtonMappingProfile = s.joyConButtonMappings[profile] ?? .defaultProfile(for: profile)
        let cursorEnabled = s.cursorControlEnabledByProfile[profile] ?? true

        // Continuous auto-calibration: updates center when stick is stationary
        if isLeft {
            let raw = joyConLeftMapping.joystickPositionRaw(in: report.bytes)
            joyConLeftMapping.calibration.updateAutoCalibration(rawX: raw.x, rawY: raw.y, timestamp: report.timestamp)
        } else {
            let raw = joyConRightMapping.joystickPositionRaw(in: report.bytes)
            joyConRightMapping.calibration.updateAutoCalibration(rawX: raw.x, rawY: raw.y, timestamp: report.timestamp)
        }

        let joyConMapping = isLeft ? joyConLeftMapping : joyConRightMapping

        // 1. Process Joy-Con buttons
        processJoyConButtonActions(
            bytes: report.bytes,
            mapping: joyConMapping,
            profile: buttonProfile,
            holdThreshold: buttonProfile.holdThreshold
        )

        // 2. Process gyro through unified pipeline
        // GyroRemapper handles the axis swapping for Joy-Con (different for left vs right)
        let pipeline = GyroRemapper.process(
            rawX: report.gyroX,
            rawY: report.gyroY,
            rawZ: report.gyroZ,
            controllerKind: .joyCon,
            isLeft: isLeft
        )

        // Pass remapped values to gyro processor (which expects pitch in X, yaw in Y)
        var gyroSettings = s.gyroSettings[.joyCon] ?? .defaultForKind(.joyCon)
        let userScale = gyroSettings.gyroScale
        gyroSettings.gyroScale = effectiveGyroScale(for: .joyCon, userScale: userScale)
        gyroSettings.expectedSampleRate = 66.0  // ~66 Hz since we use only the newest sample per packet
        gyroSettings.biasMotionThreshold = 30.0 // Joy-Con has lower noise floor; tighten bias capture
        if let (dx, dy) = joyConGyroProcessor.process(
            rawX: pipeline.remapped.pitch,
            rawY: pipeline.remapped.yaw,
            rawZ: pipeline.remapped.roll,
            timestamp: report.timestamp,
            settings: gyroSettings
        ) {
            routeGyroMovement(
                kind: .joyCon,
                dx: dx,
                dy: dy,
                cursorEnabled: cursorEnabled,
                hasDragMapping: buttonProfile.hasDragMapping,
                configuration: s.radialMenuConfiguration,
                modeState: joyConMode
            )
        }

        // 3. Process joystick scroll (if enabled)
        if s.joystickScrollEnabled, cursorEnabled {
            processJoyConJoystickScroll(bytes: report.bytes, mapping: joyConMapping, settings: s)
        }

        // 4. Update battery level (Joy-Con battery is in byte 2, upper nibble)
        if report.bytes.count > 2 {
            updateBatteryLevel(BatteryHelper.joyConLevel(from: report.bytes[2]))
        }

        // 4. Record to debug buffer with all pipeline stages
        if s.debugRecordingEnabled && (s.debugRecordingTargetKind == nil || s.debugRecordingTargetKind == .joyCon) {
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: pipeline.raw,
                remappedGyro: pipeline.remapped,
                normalizedGyro: pipeline.normalized,
                accel: (report.accelX, report.accelY, report.accelZ),
                buttonStates: joyConButtonStates,
                controllerKind: .joyCon,
                gyroDebug: mapGyroDebug(from: joyConGyroProcessor.lastDebugState)
            )
        }
    }

    // MARK: - Shared gyro scaling

    /// Apply the user scale as a multiplier relative to the Sense reference scale so both controllers share the same pipeline.
    private func effectiveGyroScale(for kind: ControllerKind, userScale: Double) -> Double {
        let reference = GyroRemapper.gyroScale(for: .sense)
        let deviceScale = GyroRemapper.gyroScale(for: kind)
        let rawMultiplier = reference != 0 ? (userScale / reference) : 1.0
        let userMultiplier = min(4.0, max(0.25, rawMultiplier))  // clamp to a sane range
        return deviceScale * userMultiplier
    }

    private func mapGyroDebug(from state: GyroProcessor.DebugState?) -> DebugBuffer.GyroDebug? {
        guard let state else { return nil }
        return DebugBuffer.GyroDebug(
            biasX: state.biasX,
            biasY: state.biasY,
            biasZ: state.biasZ,
            calibrated: state.calibrated,
            observedSampleRate: state.observedSampleRate,
            lastNeutralUpdate: state.lastNeutralUpdate
        )
    }

    // MARK: - Gyro Mode Routing

    private func updateModeState(for kind: ControllerKind, _ update: (inout GyroModeState) -> Void) {
        switch kind {
        case .sense:
            update(&senseMode)
        case .joyCon:
            update(&joyConMode)
        case .mouse:
            update(&mouseMode)
        }
    }

    private func beginRadialMenu(kind: ControllerKind, pointerStyle: RadialMenuPointerStyle) {
        if radialMenuOwnerKind == nil {
            radialMenuOwnerKind = kind
        }
        guard radialMenuOwnerKind == kind else { return }

        updateModeState(for: kind) { $0.radialMenuButtonHeld = true }
        radialMenuLock.withLock { radialMenuAccumulator = .zero }

        let position = NSEvent.mouseLocation
        let config = settings.snapshot().radialMenuConfiguration

        if pointerStyle == .ghostCursor {
            mouseController.hideCursor()
        }
        onRadialMenuShow?(position, config, pointerStyle)

        if pointerStyle == .systemCursor {
            startRadialMenuCursorTracking(anchor: position)
        }
    }

    private enum GyroMode {
        case none       // No cursor movement (drag mapped but not held)
        case normal     // Normal cursor movement
        case drag       // Drag button held
        case scroll     // Scroll button held
        case radialMenu // Radial menu active
    }

    private func currentGyroMode(kind: ControllerKind, hasDragMapping: Bool, modeState: GyroModeState) -> GyroMode {
        if modeState.radialMenuButtonHeld, radialMenuOwnerKind == kind { return .radialMenu }
        if modeState.scrollButtonHeld { return .scroll }
        if modeState.dragButtonHeld { return .drag }
        if hasDragMapping { return .none }
        return .normal
    }

    private func routeGyroMovement(
        kind: ControllerKind,
        dx: CGFloat,
        dy: CGFloat,
        cursorEnabled: Bool,
        hasDragMapping: Bool,
        configuration: RadialMenuConfiguration,
        modeState: GyroModeState
    ) {
        let mode = currentGyroMode(kind: kind, hasDragMapping: hasDragMapping, modeState: modeState)

        switch mode {
        case .none:
            break
        case .normal, .drag:
            if cursorEnabled {
                mouseController.moveRelative(dx: dx, dy: dy)
            }
        case .scroll:
            if cursorEnabled {
                mouseController.scroll(dx: dx, dy: dy)
            }
        case .radialMenu:
            guard radialMenuOwnerKind == kind else { return }
            let scale = max(0.1, configuration.radialMovementScale)
            let scaledDx = dx * scale
            let scaledDy = dy * scale
            radialMenuLock.withLock {
                radialMenuAccumulator.x += scaledDx
                radialMenuAccumulator.y += scaledDy
            }
            onRadialMenuUpdate?(CGPoint(x: dx, y: dy))
        }
    }

    // MARK: - Joystick Scroll

    private func processJoystickScroll(bytes: [UInt8], mapping: SenseButtonMapping, settings: SettingsStore.InputSettings) {
        let joystickPos = mapping.joystickPosition(in: bytes)
        let deadzone: Double = 20.0
        let center: Double = 128.0
        let maxDelta: Double = 127.0

        let deltaX = Double(joystickPos.x) - center
        let deltaY = Double(joystickPos.y) - center

        if abs(deltaX) > deadzone || abs(deltaY) > deadzone {
            let speed = settings.joystickScrollSpeed
            let accel = settings.joystickScrollAcceleration

            func scaled(_ delta: Double) -> CGFloat {
                let sign = delta >= 0 ? 1.0 : -1.0
                let normalized = min(1.0, abs(delta) / maxDelta)
                // Quadratic base curve for smooth feel
                let curved = normalized * normalized
                // Acceleration multiplies the output: higher accel = faster at full deflection
                // Interpolate from 1x at low deflection to accel× at full deflection
                let accelGain = 1.0 + (accel - 1.0) * normalized
                return CGFloat(sign * curved * accelGain * speed * 2.0)
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
            let accel = settings.joystickScrollAcceleration

            func scaled(_ delta: Double) -> CGFloat {
                let sign = delta >= 0 ? 1.0 : -1.0
                let normalized = min(1.0, abs(delta) / maxDelta)
                // Quadratic base curve for smooth feel
                let curved = normalized * normalized
                // Acceleration multiplies the output: higher accel = faster at full deflection
                // At normalized=1.0: output = 1 * accel
                // Interpolate from 1x at low deflection to accel× at full deflection
                let accelGain = 1.0 + (accel - 1.0) * normalized
                return CGFloat(sign * curved * accelGain * speed * 2.0)
            }

            let scrollX = scaled(deltaX)
            let scrollY = scaled(deltaY)
            mouseController.scroll(dx: scrollX, dy: scrollY)
        }
    }

    // MARK: - Button Processing

    private func processButtonActions(
        bytes: [UInt8],
        mapping: SenseButtonMapping,
        profile: SenseButtonMappingProfile,
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
                    handleButtonUp(button: button, mappingProfile: profile)
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
                handleButtonUp(button: .trigger, mappingProfile: profile)
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
                senseMode.dragButtonHeld = true
            case .scroll:
                senseMode.scrollButtonHeld = true
            case .radialMenu:
                beginRadialMenu(kind: .sense, pointerStyle: .ghostCursor)
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
                guard self.isRunning else { return }
                guard var state = self.buttonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                self.buttonPressStates[idx] = state
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            holdTimers[idx]?.cancel()
            holdTimers[idx] = timer
            engineQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    private func handleButtonUp(button: LogicalButton, mappingProfile: SenseButtonMappingProfile) {
        let idx = button.index

        // Cancel hold timer
        holdTimers[idx]?.cancel()
        holdTimers[idx] = nil

        // Check for gyro mode button release
        if let state = buttonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(kind: .sense, action: state.actions.press)
            buttonPressStates[idx] = nil
            return
        }

        // Also check current mapping for gyro modes
        let actions = mappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(kind: .sense, action: actions.press)
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

    private func handleGyroModeRelease(kind: ControllerKind, action: ButtonAction) {
        switch action {
        case .drag:
            updateModeState(for: kind) { $0.dragButtonHeld = false }
        case .scroll:
            updateModeState(for: kind) { $0.scrollButtonHeld = false }
        case .radialMenu:
            guard radialMenuOwnerKind == kind else { return }
            if kind == .mouse {
                stopRadialMenuCursorTracking()
            }
            radialMenuOwnerKind = nil
            updateModeState(for: kind) { $0.radialMenuButtonHeld = false }

            // Determine selected item based on accumulated movement
            let selectedItem = calculateRadialMenuSelection()
            onRadialMenuHide?(selectedItem)

            // Execute the selected action
            if let item = selectedItem {
                executeRadialMenuAction(item.action)
            }
            if kind != .mouse {
                mouseController.showCursor()
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
                    handleJoyConButtonUp(button: button, mappingProfile: profile)
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
                joyConMode.dragButtonHeld = true
            case .scroll:
                joyConMode.scrollButtonHeld = true
            case .radialMenu:
                beginRadialMenu(kind: .joyCon, pointerStyle: .ghostCursor)
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
                guard self.isRunning else { return }
                guard var state = self.joyConButtonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                self.joyConButtonPressStates[idx] = state
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            joyConHoldTimers[idx]?.cancel()
            joyConHoldTimers[idx] = timer
            engineQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    private func handleJoyConButtonUp(button: JoyConLogicalButton, mappingProfile: JoyConButtonMappingProfile) {
        let idx = button.index

        // Cancel hold timer
        joyConHoldTimers[idx]?.cancel()
        joyConHoldTimers[idx] = nil

        // Check for gyro mode button release
        if let state = joyConButtonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(kind: .joyCon, action: state.actions.press)
            joyConButtonPressStates[idx] = nil
            return
        }

        // Also check current mapping for gyro modes
        let actions = mappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(kind: .joyCon, action: actions.press)
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

    // MARK: - G502X Report Processing

    private func processG502XReport(_ report: G502XHIDController.InputReport) {
        guard isRunning else { return }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        let profile = ControllerProfile.mouse
        let buttonProfile = s.g502xButtonMappings[profile] ?? .default

        // Prime initial button state to avoid false "pressed" edges on startup/connect.
        // The Lightspeed receiver can deliver a non-zero snapshot while we are still setting up HID++.
        if !g502xHasPrimedButtonState {
            primeG502XButtonStates(bytes: report.bytes, mapping: g502xMapping)
            g502xHasPrimedButtonState = true
            return
        }

        // 1. Process mouse buttons
        processG502XButtonActions(
            bytes: report.bytes,
            mapping: g502xMapping,
            profile: buttonProfile,
            holdThreshold: buttonProfile.holdThreshold
        )

        if s.debugRecordingEnabled && (s.debugRecordingTargetKind == nil || s.debugRecordingTargetKind == .mouse) {
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: (0, 0, 0),           // Mouse has no gyro
                remappedGyro: (0, 0, 0),
                normalizedGyro: (0, 0, 0),
                accel: (0, 0, 0),
                buttonStates: g502xPreviousButtonStates,
                controllerKind: .mouse
            )
        }
    }

    private func resetG502XButtonStateBaseline() {
        g502xHasPrimedButtonState = false
        for i in 0..<g502xPreviousButtonStates.count {
            g502xPreviousButtonStates[i] = false
            g502xButtonStates[i] = false
            g502xButtonPressStates[i] = nil
            g502xHoldTimers[i]?.cancel()
            g502xHoldTimers[i] = nil
        }
    }

    private func primeG502XButtonStates(bytes: [UInt8], mapping: G502XButtonMapping) {
        for button in G502XLogicalButton.allCases {
            let idx = button.index
            let pressed = mapping.isPressed(button, in: bytes)
            g502xPreviousButtonStates[idx] = pressed
            g502xButtonStates[idx] = pressed
            g502xButtonPressStates[idx] = nil
            g502xHoldTimers[idx]?.cancel()
            g502xHoldTimers[idx] = nil
        }
    }

    // MARK: - Radial Menu Cursor Tracking (Mouse)

    /// For real mice, the user expects to select using the system cursor.
    /// We poll cursor position relative to the menu anchor and update selection.
    private func startRadialMenuCursorTracking(anchor: CGPoint) {
        stopRadialMenuCursorTracking()
        radialMenuCursorAnchor = anchor

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))  // ~60Hz
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.radialMenuOwnerKind == .mouse, self.mouseMode.radialMenuButtonHeld, let anchor = self.radialMenuCursorAnchor else { return }

            let current = NSEvent.mouseLocation
            let dx = current.x - anchor.x
            let dy = -(current.y - anchor.y) // NSEvent Y+ up; radial menu uses Y+ down

            self.radialMenuLock.withLock {
                self.radialMenuAccumulator = CGPoint(x: dx, y: dy)
            }

            self.onRadialMenuSetPosition?(CGPoint(x: dx, y: dy))
        }
        timer.resume()
        radialMenuCursorPollTimer = timer
    }

    private func stopRadialMenuCursorTracking() {
        radialMenuCursorPollTimer?.cancel()
        radialMenuCursorPollTimer = nil
        radialMenuCursorAnchor = nil
    }

    // MARK: - G502X Button Processing

    private func processG502XButtonActions(
        bytes: [UInt8],
        mapping: G502XButtonMapping,
        profile: G502XButtonMappingProfile,
        holdThreshold: Double
    ) {
        // Log G9 state for debugging (byte 1, bit 0)
        let g9Pressed = bytes.count > 1 ? (bytes[1] & 0x01) != 0 : false
        let g9WasPrevious = g502xPreviousButtonStates[G502XLogicalButton.g9.index]
        if g9Pressed != g9WasPrevious {
            debugBuffer.log("[G502X] HID: G9 state change - byte1=0x\(String(format: "%02X", bytes.count > 1 ? bytes[1] : 0)) pressed=\(g9Pressed) was=\(g9WasPrevious)")
        }

        // Process all G502X buttons
        for button in G502XLogicalButton.allCases {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = g502xPreviousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = profile.actions(for: button)
                if isPressed {
                    handleG502XButtonDown(button: button, actions: actions, holdThreshold: holdThreshold)
                } else {
                    handleG502XButtonUp(button: button, mappingProfile: profile)
                }
            }

            g502xPreviousButtonStates[idx] = isPressed
            g502xButtonStates[idx] = isPressed
        }
    }

    private func handleG502XButtonDown(button: G502XLogicalButton, actions: ButtonActions, holdThreshold: Double) {
        let idx = button.index

        // Handle gyro mode actions (radial menu for mouse)
        if actions.pressIsGyroMode {
            switch actions.press {
            case .radialMenu:
                debugBuffer.log("[G502X] Opening radial menu (button=\(button))")
                beginRadialMenu(kind: .mouse, pointerStyle: .systemCursor)
            case .drag, .scroll:
                // These don't make sense for mouse (it already has native cursor/scroll)
                // but we handle them for consistency
                if actions.press == .drag {
                    mouseMode.dragButtonHeld = true
                } else {
                    mouseMode.scrollButtonHeld = true
                }
            default:
                break
            }
            return
        }

        // Handle mouse clicks immediately
        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true)
            g502xButtonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)
            return
        }

        // Record press state
        g502xButtonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)

        // Schedule hold timer if there's a hold action
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.isRunning else { return }
                guard var state = self.g502xButtonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                self.g502xButtonPressStates[idx] = state
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            g502xHoldTimers[idx]?.cancel()
            g502xHoldTimers[idx] = timer
            engineQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    private func handleG502XButtonUp(button: G502XLogicalButton, mappingProfile: G502XButtonMappingProfile) {
        let idx = button.index

        // Cancel hold timer
        g502xHoldTimers[idx]?.cancel()
        g502xHoldTimers[idx] = nil

        // Check for gyro mode button release
        if let state = g502xButtonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(kind: .mouse, action: state.actions.press)
            g502xButtonPressStates[idx] = nil
            return
        }

        // Also check current mapping for gyro modes
        let actions = mappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(kind: .mouse, action: actions.press)
            return
        }

        guard let state = g502xButtonPressStates[idx] else { return }

        // Handle mouse click release
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false)
            g502xButtonPressStates[idx] = nil
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

        g502xButtonPressStates[idx] = nil
    }

    // NOTE: We intentionally do not "passthrough" mouse buttons by re-posting CGEvents.
    // The G502X is opened non-exclusively, so the system already receives native mouse events.

    // MARK: - Radial Menu

    private func calculateRadialMenuSelection() -> RadialMenuItem? {
        let config = settings.snapshot().radialMenuConfiguration
        let accumulator = radialMenuLock.withLock { radialMenuAccumulator }
        let magnitude = sqrt(accumulator.x * accumulator.x + accumulator.y * accumulator.y)

        guard magnitude > config.deadzoneSize else { return nil }

        let angle = atan2(accumulator.y, accumulator.x)

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
