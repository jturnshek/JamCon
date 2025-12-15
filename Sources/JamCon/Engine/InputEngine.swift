import Foundation
import CoreGraphics
import os

/// The real-time input processing engine
/// This is WORLD 1 - has NO knowledge of SwiftUI, @Published, or ObservableObject
/// Processes HID input and drives mouse/keyboard output
final class InputEngine {

    // MARK: - Dependencies

    let settings: SettingsStore
    let debugBuffer: DebugBuffer

    // MARK: - Controllers

    let senseController: SenseController
    let joyConController: JoyConHIDController
    let g502xController: G502XHIDController
    let mouseController: MouseController
    let actionExecutor: ActionExecutor

    // MARK: - Threading

    /// Serial queue that owns all engine state mutations and input processing.
    let engineQueue = DispatchQueue(label: "JamCon.engineQueue", qos: .userInitiated)
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

    @inline(__always)
    func assertOnEngineQueue(file: StaticString = #fileID, line: UInt = #line) {
        assert(
            DispatchQueue.getSpecific(key: engineQueueKey) != nil,
            "InputEngine state must be accessed on engineQueue",
            file: file,
            line: line
        )
    }

    // MARK: - Managed Device State (Internal - not observable)

    struct ManagedDeviceKey: Hashable {
        let kind: ControllerKind
        let id: String
    }

    // Hold detection (per button, per device)
    struct ButtonPressState {
        let pressTime: Date
        let actions: ButtonActions
        var holdFired: Bool = false
    }

    struct GyroModeState {
        var dragButtonHeld: Bool = false
        var scrollButtonHeld: Bool = false
        var radialMenuButtonHeld: Bool = false
    }

    var mouseMode = GyroModeState()

    final class SenseDeviceState {
        let id: String
        let profile: ControllerProfile
        var mode = GyroModeState()
        let gyroProcessor = GyroProcessor()

        var buttonStates: [Bool]
        var previousButtonStates: [Bool]
        var previousTriggerPressed: Bool = false
        var buttonPressStates: [ButtonPressState?]
        var holdTimers: [DispatchWorkItem?]

        init(id: String, profile: ControllerProfile) {
            self.id = id
            self.profile = profile

            let count = LogicalButton.allCases.count
            self.buttonStates = Array(repeating: false, count: count)
            self.previousButtonStates = Array(repeating: false, count: count)
            self.buttonPressStates = Array(repeating: nil, count: count)
            self.holdTimers = Array(repeating: nil, count: count)
        }

        func cancelHoldTimers() {
            for timer in holdTimers {
                timer?.cancel()
            }
            for i in holdTimers.indices {
                holdTimers[i] = nil
            }
        }
    }

    final class JoyConDeviceState {
        let id: String
        let profile: ControllerProfile
        var mode = GyroModeState()
        let gyroProcessor = GyroProcessor()

        var mapping: JoyConButtonMapping
        var buttonStates: [Bool]
        var previousButtonStates: [Bool]
        var buttonPressStates: [ButtonPressState?]
        var holdTimers: [DispatchWorkItem?]

        init(id: String, profile: ControllerProfile) {
            self.id = id
            self.profile = profile
            self.mapping = JoyConButtonMapping(isLeft: profile.isLeft)

            let count = JoyConLogicalButton.count
            self.buttonStates = Array(repeating: false, count: count)
            self.previousButtonStates = Array(repeating: false, count: count)
            self.buttonPressStates = Array(repeating: nil, count: count)
            self.holdTimers = Array(repeating: nil, count: count)
        }

        func cancelHoldTimers() {
            for timer in holdTimers {
                timer?.cancel()
            }
            for i in holdTimers.indices {
                holdTimers[i] = nil
            }
        }
    }

    var senseDevices: [String: SenseDeviceState] = [:]      // controllerID -> state
    var joyConDevices: [String: JoyConDeviceState] = [:]    // controllerID -> state
    var selectedMouseID: String?

    private var batteryLevels: [ManagedDeviceKey: Int] = [:]
    var radialMenuOwner: ManagedDeviceKey?

    // Cached button mappings (avoid allocation on hot path)
    let leftMapping = SenseButtonMapping(isLeft: true)
    let rightMapping = SenseButtonMapping(isLeft: false)

    // G502X button state
    var g502xButtonStates: [Bool]
    var g502xPreviousButtonStates: [Bool]
    var g502xButtonPressStates: [ButtonPressState?]
    var g502xHoldTimers: [DispatchWorkItem?]
    let g502xMapping = G502XButtonMapping()
    var g502xHasPrimedButtonState: Bool = false

    // Mouse movement capture for radial menu (when using G502X)
    let radialMenuLock = OSAllocatedUnfairLock()
    var radialMenuCursorAnchor: CGPoint?
    var radialMenuCursorPollTimer: DispatchSourceTimer?

    // MARK: - Radial Menu State (Internal)

    var radialMenuPosition: CGPoint = .zero
    var radialMenuAnchor: CGPoint = .zero
    var radialMenuAccumulator: CGPoint = .zero

    // MARK: - Radial Menu UI Throttling

    /// Target UI update rate for the radial menu overlay (keeps up with 120Hz displays).
    static let radialMenuUIUpdateInterval = DispatchTimeInterval.nanoseconds(8_333_333)  // ~120Hz
    var radialMenuPendingDelta: CGPoint = .zero
    var radialMenuUIUpdateTimer: DispatchSourceTimer?

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

    func setBatteryLevel(_ level: Int, for device: ManagedDeviceKey) {
        batteryLevels[device] = level
        updateBatteryFromLevels()
    }

    private func clearBatteryLevel(for device: ManagedDeviceKey) {
        if batteryLevels.removeValue(forKey: device) != nil {
            updateBatteryFromLevels()
        }
    }

    private func updateBatteryFromLevels() {
        let aggregate = batteryLevels.values.min() ?? 0
        updateBatteryLevel(aggregate)
    }

    // MARK: - Running State

    var isRunning: Bool = false

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
        self.actionExecutor = ActionExecutor(mouseController: mouseController)

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

            if radialMenuOwner != nil || radialMenuCursorPollTimer != nil || radialMenuUIUpdateTimer != nil {
                let owner = radialMenuOwner
                stopRadialMenuUIUpdateTimer()
                stopRadialMenuCursorTracking()
                mouseMode.radialMenuButtonHeld = false
                if owner?.kind != .mouse {
                    mouseController.showCursor()
                }
                radialMenuOwner = nil
                onRadialMenuHide?(nil)
            }

            // Cancel all hold timers
            for device in senseDevices.values {
                device.cancelHoldTimers()
            }
            for device in joyConDevices.values {
                device.cancelHoldTimers()
            }
            for timer in g502xHoldTimers {
                timer?.cancel()
            }

            senseDevices.removeAll(keepingCapacity: true)
            joyConDevices.removeAll(keepingCapacity: true)
            batteryLevels.removeAll(keepingCapacity: true)

            return true
        }
        guard shouldStop else { return }

        senseController.stop()
        joyConController.stop()
        g502xController.stop()
    }

    // MARK: - Controller Selection

    /// Enable/disable processing for a specific physical device.
    func setDeviceManaged(id: String, kind: ControllerKind, isLeft: Bool, managed: Bool) {
        engineQueueSync {
            switch kind {
            case .sense:
                let profile = ControllerProfile(kind: .sense, isLeft: isLeft)
                if managed {
                    if senseDevices[id]?.profile != profile {
                        senseDevices[id]?.cancelHoldTimers()
                        senseDevices[id] = SenseDeviceState(id: id, profile: profile)
                    }
                    senseController.setControllerManaged(id: id, managed: true)
                } else {
                    senseController.setControllerManaged(id: id, managed: false)
                    removeSenseDevice(id: id)
                }

            case .joyCon:
                let profile = ControllerProfile(kind: .joyCon, isLeft: isLeft)
                if managed {
                    if joyConDevices[id]?.profile != profile {
                        joyConDevices[id]?.cancelHoldTimers()
                        joyConDevices[id] = JoyConDeviceState(id: id, profile: profile)
                    }
                    joyConController.setControllerManaged(id: id, managed: true)
                } else {
                    joyConController.setControllerManaged(id: id, managed: false)
                    removeJoyConDevice(id: id)
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

    private func removeSenseDevice(id: String) {
        let key = ManagedDeviceKey(kind: .sense, id: id)
        if let device = senseDevices.removeValue(forKey: id) {
            device.cancelHoldTimers()
        }
        clearBatteryLevel(for: key)
        cancelRadialMenuIfOwned(by: key)
    }

    private func removeJoyConDevice(id: String) {
        let key = ManagedDeviceKey(kind: .joyCon, id: id)
        if let device = joyConDevices.removeValue(forKey: id) {
            device.cancelHoldTimers()
        }
        clearBatteryLevel(for: key)
        cancelRadialMenuIfOwned(by: key)
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

            if radialMenuOwner != nil || radialMenuCursorPollTimer != nil || radialMenuUIUpdateTimer != nil {
                let owner = radialMenuOwner
                stopRadialMenuUIUpdateTimer()
                stopRadialMenuCursorTracking()
                mouseMode.radialMenuButtonHeld = false
                if owner?.kind != .mouse {
                    mouseController.showCursor()
                }
                radialMenuOwner = nil
                onRadialMenuHide?(nil)
            }

            selectedMouseID = nil
            senseDevices.values.forEach { $0.cancelHoldTimers() }
            joyConDevices.values.forEach { $0.cancelHoldTimers() }
            senseDevices.removeAll(keepingCapacity: true)
            joyConDevices.removeAll(keepingCapacity: true)
            batteryLevels.removeAll(keepingCapacity: true)

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

    /// Recalibrate the gyro
    func recalibrate() {
        engineQueueSync {
            for device in senseDevices.values {
                device.gyroProcessor.reset()
            }
            for device in joyConDevices.values {
                device.gyroProcessor.reset()
            }
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

        senseController.onConnectionChange = { [weak self] connected, name, controllerID in
            self?.engineQueueAsync { [weak self] in
                guard let self else { return }
                if let id = controllerID {
                    let key = ManagedDeviceKey(kind: .sense, id: id)
                    if let device = self.senseDevices[id] {
                        self.resetSenseTransientState(device)
                    }
                    if !connected {
                        self.clearBatteryLevel(for: key)
                        self.cancelRadialMenuIfOwned(by: key)
                    }
                }
                self.onConnectionChanged?(connected, name, .sense)
            }
        }

        senseController.onControllersChanged = { [weak self] in
            self?.engineQueueAsync { [weak self] in
                self?.onControllerListChanged?()
            }
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

                if let id = controllerID {
                    let key = ManagedDeviceKey(kind: .joyCon, id: id)
                    if let device = self.joyConDevices[id] {
                        self.resetJoyConTransientState(device)
                        if connected {
                            device.mapping.calibration.reset()
                        }
                    }
                    if !connected {
                        self.clearBatteryLevel(for: key)
                        self.cancelRadialMenuIfOwned(by: key)
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

    }

    private func resetSenseTransientState(_ device: SenseDeviceState) {
        for idx in device.holdTimers.indices {
            device.holdTimers[idx]?.cancel()
            device.holdTimers[idx] = nil

            guard let pressState = device.buttonPressStates[idx] else { continue }

            if case .mouseClick = pressState.actions.press {
                actionExecutor.execute(pressState.actions.press, isPressed: false)
            }
            if pressState.holdFired {
                actionExecutor.execute(pressState.actions.hold, isPressed: false)
            }

            device.buttonPressStates[idx] = nil
        }

        device.previousTriggerPressed = false
        for idx in device.buttonStates.indices {
            device.buttonStates[idx] = false
            device.previousButtonStates[idx] = false
        }
        device.mode = GyroModeState()
        device.gyroProcessor.reset()
    }

    private func resetJoyConTransientState(_ device: JoyConDeviceState) {
        for idx in device.holdTimers.indices {
            device.holdTimers[idx]?.cancel()
            device.holdTimers[idx] = nil

            guard let pressState = device.buttonPressStates[idx] else { continue }

            if case .mouseClick = pressState.actions.press {
                actionExecutor.execute(pressState.actions.press, isPressed: false)
            }
            if pressState.holdFired {
                actionExecutor.execute(pressState.actions.hold, isPressed: false)
            }

            device.buttonPressStates[idx] = nil
        }

        for idx in device.buttonStates.indices {
            device.buttonStates[idx] = false
            device.previousButtonStates[idx] = false
        }
        device.mode = GyroModeState()
        device.gyroProcessor.reset()
    }

}
