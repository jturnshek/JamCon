import Foundation
import SwiftUI
import ApplicationServices

/// UI-only app state for JamCon
/// This is WORLD 2 - purely for SwiftUI observation
/// Does NOT receive HID callbacks - only polls data when needed
@MainActor
final class AppState: ObservableObject {

    // MARK: - Engine Components (World 1)

    /// Thread-safe settings store - UI writes, Engine reads
    let settingsStore: SettingsStore

    /// Debug buffer - Engine writes, UI polls
    let debugBuffer: DebugBuffer

    /// Input engine - handles all real-time processing
    let engine: InputEngine

    // MARK: - UI State

    /// Currently active tab
    @Published var activeTab: ActiveTab = .controller

    /// Available controllers (refreshed on demand)
    @Published var availableControllers: [ControllerInfo] = []

    /// Selected controller ID
    @Published var selectedControllerID: String?

    /// Connection status
    @Published var isConnected: Bool = false
    @Published var controllerName: String = "Not connected"
    @Published var activeControllerKind: ControllerKind = .sense {
        didSet {
            if oldValue != activeControllerKind {
                reloadSettingsForCurrentProfile()
            }
        }
    }
    @Published var isLeftController: Bool = false {
        didSet {
            if oldValue != isLeftController {
                reloadButtonMappingForCurrentProfile()
            }
        }
    }

    /// Current active profile (derived from activeControllerKind and isLeftController)
    var activeProfile: ControllerProfile {
        ControllerProfile(kind: activeControllerKind, isLeft: isLeftController)
    }

    /// Status message for UI
    @Published var statusMessage: String = "Waiting for controller..."

    /// Accessibility permission
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    /// Battery level (polled periodically)
    @Published var batteryLevel: Int = 0

    // MARK: - Settings (UI bindings that write to SettingsStore)

    @Published var isEnabled: Bool = true {
        didSet { settingsStore.update { $0.isEnabled = isEnabled } }
    }

    // Gyro settings
    @Published var sensitivity: Double = 50.0 {
        didSet {
            settingsStore.update { $0.sensitivity = sensitivity }
            saveGyroSettings()
        }
    }

    @Published var gyroScale: Double = 1.0 / 16.0 {
        didSet {
            settingsStore.update { $0.gyroScale = gyroScale }
            saveGyroSettings()
        }
    }

    @Published var filterEnabled: Bool = true {
        didSet {
            settingsStore.update { $0.filterEnabled = filterEnabled }
            saveGyroSettings()
        }
    }

    @Published var minCutoff: Double = 0.5 {
        didSet {
            settingsStore.update { $0.minCutoff = minCutoff }
            saveGyroSettings()
        }
    }

    @Published var beta: Double = 1.0 {
        didSet {
            settingsStore.update { $0.beta = beta }
            saveGyroSettings()
        }
    }

    @Published var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speed {
        didSet {
            settingsStore.update { $0.adaptiveSmoothingMode = adaptiveSmoothingMode }
            saveGyroSettings()
        }
    }

    @Published var accelerationMode: AccelerationMode = .simple {
        didSet {
            settingsStore.update { $0.accelerationMode = accelerationMode }
            saveGyroSettings()
        }
    }

    @Published var simpleAcceleration: Double = 5.0 {
        didSet {
            settingsStore.update { $0.simpleAcceleration = simpleAcceleration }
            saveGyroSettings()
        }
    }

    @Published var accelerationCurve: AccelerationCurve = .power {
        didSet {
            settingsStore.update { $0.accelerationCurve = accelerationCurve }
            saveGyroSettings()
        }
    }

    @Published var accelerationStrength: Double = 10.0 {
        didSet {
            settingsStore.update { $0.accelerationStrength = accelerationStrength }
            saveGyroSettings()
        }
    }

    @Published var sensitivityCap: Double = 20.0 {
        didSet {
            settingsStore.update { $0.sensitivityCap = sensitivityCap }
            saveGyroSettings()
        }
    }

    @Published var curveExponent: Double = 1.0 {
        didSet {
            settingsStore.update { $0.curveExponent = curveExponent }
            saveGyroSettings()
        }
    }

    @Published var rampSpeed: Double = 150.0 {
        didSet {
            settingsStore.update { $0.rampSpeed = rampSpeed }
            saveGyroSettings()
        }
    }

    @Published var softCutoffThreshold: Double = 0.5 {
        didSet {
            settingsStore.update { $0.softCutoffThreshold = softCutoffThreshold }
            saveGyroSettings()
        }
    }

    @Published var recoveryThreshold: Double = 1.5 {
        didSet {
            settingsStore.update { $0.recoveryThreshold = recoveryThreshold }
            saveGyroSettings()
        }
    }

    // Button mapping (per-profile)
    @Published var buttonMappingProfile: SenseButtonMappingProfile = .load() {
        didSet {
            buttonMappingProfile.save(for: activeProfile)
            settingsStore.update { $0.buttonMappingProfile = buttonMappingProfile }
        }
    }

    @Published var triggerThreshold: UInt8 = 128 {
        didSet {
            buttonMappingProfile.triggerThreshold = triggerThreshold
            buttonMappingProfile.save(for: activeProfile)
            settingsStore.update { $0.triggerThreshold = triggerThreshold }
        }
    }

    @Published var holdThreshold: Double = 0.3 {
        didSet {
            buttonMappingProfile.holdThreshold = holdThreshold
            buttonMappingProfile.save(for: activeProfile)
            settingsStore.update { $0.holdThreshold = holdThreshold }
        }
    }

    // Joy-Con button mapping (per-profile)
    @Published var joyConButtonMappingProfile: JoyConButtonMappingProfile = .load() {
        didSet {
            joyConButtonMappingProfile.save(for: activeProfile)
            settingsStore.update { $0.joyConButtonMappingProfile = joyConButtonMappingProfile }
        }
    }

    // Joystick settings
    @Published var joystickScrollEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(joystickScrollEnabled, forKey: "joystick.scrollEnabled")
            settingsStore.update { $0.joystickScrollEnabled = joystickScrollEnabled }
        }
    }

    @Published var joystickScrollSpeed: Double = 5.0 {
        didSet {
            UserDefaults.standard.set(joystickScrollSpeed, forKey: "joystick.scrollSpeed")
            settingsStore.update { $0.joystickScrollSpeed = joystickScrollSpeed }
        }
    }

    @Published var joystickScrollAcceleration: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(joystickScrollAcceleration, forKey: "joystick.scrollAcceleration")
            settingsStore.update { $0.joystickScrollAcceleration = joystickScrollAcceleration }
        }
    }

    @Published var joyConTimerFallbackEnabled: Bool = true {
        didSet {
            settingsStore.update { $0.joyConTimerFallbackEnabled = joyConTimerFallbackEnabled }
            saveGyroSettings()
        }
    }

    @Published var joyConTimerHybridEnabled: Bool = false {
        didSet {
            settingsStore.update { $0.joyConTimerHybridEnabled = joyConTimerHybridEnabled }
            saveGyroSettings()
        }
    }

    @Published var autoTuneSampleRate: Bool = false {
        didSet {
            settingsStore.update { $0.autoTuneSampleRate = autoTuneSampleRate }
            saveGyroSettings()
        }
    }

    @Published var autoNeutralEnabled: Bool = true {
        didSet {
            settingsStore.update { $0.autoNeutralEnabled = autoNeutralEnabled }
            saveGyroSettings()
        }
    }

    // Radial menu
    @Published var radialMenuConfiguration: RadialMenuConfiguration = .load() {
        didSet {
            radialMenuConfiguration.save()
            settingsStore.update { $0.radialMenuConfiguration = radialMenuConfiguration }
        }
    }

    /// Radial menu state (for overlay UI)
    let radialMenuState = RadialMenuState()

    /// Radial menu window controller
    private var radialMenuWindowController: RadialMenuWindowController?

    // MARK: - Debug State (Polled, not pushed)

    /// Whether debug polling is active
    @Published var debugPollingEnabled: Bool = false

    /// Latest debug sample (updated by polling timer)
    @Published var debugSample: DebugBuffer.Sample?

    /// Debug statistics
    @Published var debugStats: DebugBuffer.Stats = .init()

    /// Byte change tracking for visualization
    @Published var byteLastChanged: [Date] = []
    @Published var bitLastChanged: [[Date]] = []

    /// Report bytes for byte inspector
    @Published var reportBytes: [UInt8] = []
    @Published var reportLength: Int = 0

    /// Button states for visualization
    @Published var buttonStates: [LogicalButton: Bool] = [:]

    /// Gyro Pipeline Stage 1: Raw (direct from HID)
    @Published var rawGyroX: Int16 = 0
    @Published var rawGyroY: Int16 = 0
    @Published var rawGyroZ: Int16 = 0

    /// Gyro Pipeline Stage 2: Remapped (semantic axes)
    @Published var remappedPitch: Int16 = 0
    @Published var remappedYaw: Int16 = 0
    @Published var remappedRoll: Int16 = 0

    /// Gyro Pipeline Stage 3: Normalized (degrees per second)
    @Published var normalizedPitch: Double = 0
    @Published var normalizedYaw: Double = 0
    @Published var normalizedRoll: Double = 0

    /// Accel values (raw)
    @Published var lastAccelX: Int16 = 0
    @Published var lastAccelY: Int16 = 0
    @Published var lastAccelZ: Int16 = 0

    // Legacy aliases for backwards compatibility
    var lastGyroX: Int16 { rawGyroX }
    var lastGyroY: Int16 { rawGyroY }
    var lastGyroZ: Int16 { rawGyroZ }

    /// Report count for stats
    @Published var reportCount: Int = 0

    /// Debug refresh trigger (for TimelineView)
    @Published var debugRefreshTrigger: Int = 0

    // MARK: - Log State

    @Published var debugLog: [String] = []

    // MARK: - Timers

    private var debugPollingTimer: Timer?
    private var logPollingTimer: Timer?
    private var accessibilityTimer: Timer?
    private var batteryPollingTimer: Timer?

    // MARK: - Tab Enum

    enum ActiveTab: String {
        case controller, mouse, buttons, joystick, radial, debug, log
    }

    // MARK: - Initialization

    init() {
        // Create the core components
        self.settingsStore = SettingsStore()
        self.debugBuffer = DebugBuffer()
        self.engine = InputEngine(settings: settingsStore, debugBuffer: debugBuffer)

        // Load settings from store into published properties
        loadSettingsFromStore()

        // Setup engine callbacks for UI updates
        setupEngineCallbacks()
    }

    // MARK: - Engine Lifecycle

    /// Start the input engine - call after UI is ready
    func startEngine() {
        engine.start()
        refreshControllerList()
        startBatteryPolling()
        startLogPolling()

        // Sync connection state after a short delay to let HID controllers discover devices
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            await MainActor.run {
                syncConnectionState()
            }
        }
    }

    /// Sync UI state with engine's current connection state
    private func syncConnectionState() {
        refreshControllerList()

        if engine.isConnected {
            isConnected = true
            selectedControllerID = engine.selectedControllerID

            // Find the controller info to get the kind, side, and name
            if let id = selectedControllerID,
               let info = availableControllers.first(where: { $0.id == id }) {
                activeControllerKind = info.kind
                isLeftController = info.isLeft
                controllerName = info.name  // Use the Bluetooth device name
            } else {
                controllerName = engine.connectedControllerName ?? "Controller"
            }

            // Update battery
            pollBatteryLevel()
        } else {
            // Try to restore saved controller (if available)
            tryRestoreSavedController()
        }
    }

    /// Stop the input engine
    func stopEngine() {
        engine.stop()
        stopBatteryPolling()
        stopLogPolling()
    }

    // MARK: - Battery Polling

    private func startBatteryPolling() {
        batteryPollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollBatteryLevel()
            }
        }
        // Poll immediately once
        pollBatteryLevel()
    }

    private func stopBatteryPolling() {
        batteryPollingTimer?.invalidate()
        batteryPollingTimer = nil
    }

    private func pollBatteryLevel() {
        batteryLevel = engine.batteryLevel
    }

    // MARK: - Settings Loading

    private func loadSettingsFromStore() {
        let s = settingsStore.snapshot()

        // Don't trigger didSet during init
        _isEnabled = Published(initialValue: s.isEnabled)
        _sensitivity = Published(initialValue: s.sensitivity)
        _gyroScale = Published(initialValue: s.gyroScale)
        _filterEnabled = Published(initialValue: s.filterEnabled)
        _minCutoff = Published(initialValue: s.minCutoff)
        _beta = Published(initialValue: s.beta)
        _adaptiveSmoothingMode = Published(initialValue: s.adaptiveSmoothingMode)
        _accelerationMode = Published(initialValue: s.accelerationMode)
        _simpleAcceleration = Published(initialValue: s.simpleAcceleration)
        _accelerationCurve = Published(initialValue: s.accelerationCurve)
        _accelerationStrength = Published(initialValue: s.accelerationStrength)
        _sensitivityCap = Published(initialValue: s.sensitivityCap)
        _curveExponent = Published(initialValue: s.curveExponent)
        _rampSpeed = Published(initialValue: s.rampSpeed)
        _softCutoffThreshold = Published(initialValue: s.softCutoffThreshold)
        _recoveryThreshold = Published(initialValue: s.recoveryThreshold)

        _buttonMappingProfile = Published(initialValue: s.buttonMappingProfile)
        _triggerThreshold = Published(initialValue: s.triggerThreshold)
        _holdThreshold = Published(initialValue: s.holdThreshold)
        _joyConButtonMappingProfile = Published(initialValue: s.joyConButtonMappingProfile)

        _joystickScrollEnabled = Published(initialValue: s.joystickScrollEnabled)
        _joystickScrollSpeed = Published(initialValue: s.joystickScrollSpeed)
        _joystickScrollAcceleration = Published(initialValue: s.joystickScrollAcceleration)
        _joyConTimerFallbackEnabled = Published(initialValue: s.joyConTimerFallbackEnabled)
        _joyConTimerHybridEnabled = Published(initialValue: s.joyConTimerHybridEnabled)
        _autoTuneSampleRate = Published(initialValue: s.autoTuneSampleRate)
        _autoNeutralEnabled = Published(initialValue: s.autoNeutralEnabled)

        _radialMenuConfiguration = Published(initialValue: s.radialMenuConfiguration)
    }

    private func saveGyroSettings() {
        // Save to per-type gyro settings for persistence
        var state = GyroSettingsState.load(for: activeControllerKind)
        state.sensitivity = sensitivity
        state.gyroScale = gyroScale
        state.filterEnabled = filterEnabled
        state.minCutoff = minCutoff
        state.beta = beta
        state.adaptiveSmoothingMode = adaptiveSmoothingMode
        state.accelerationMode = accelerationMode
        state.simpleAcceleration = simpleAcceleration
        state.accelerationCurve = accelerationCurve
        state.accelerationStrength = accelerationStrength
        state.sensitivityCap = sensitivityCap
        state.curveExponent = curveExponent
        state.rampSpeed = rampSpeed
        state.softCutoffThreshold = softCutoffThreshold
        state.recoveryThreshold = recoveryThreshold
        state.autoTuneSampleRate = autoTuneSampleRate
        state.autoNeutralEnabled = autoNeutralEnabled

        // Joy-Con specific
        if activeControllerKind == .joyCon {
            state.joyConTimerFallbackEnabled = joyConTimerFallbackEnabled
            state.joyConTimerHybridEnabled = joyConTimerHybridEnabled
        }

        state.save(for: activeControllerKind)
    }

    /// Reload all settings when controller type changes
    private func reloadSettingsForCurrentProfile() {
        let gyroState = GyroSettingsState.load(for: activeControllerKind)

        // Update published properties without triggering saves
        _sensitivity = Published(initialValue: gyroState.sensitivity)
        _gyroScale = Published(initialValue: gyroState.gyroScale)
        _filterEnabled = Published(initialValue: gyroState.filterEnabled)
        _minCutoff = Published(initialValue: gyroState.minCutoff)
        _beta = Published(initialValue: gyroState.beta)
        _adaptiveSmoothingMode = Published(initialValue: gyroState.adaptiveSmoothingMode)
        _accelerationMode = Published(initialValue: gyroState.accelerationMode)
        _simpleAcceleration = Published(initialValue: gyroState.simpleAcceleration)
        _accelerationCurve = Published(initialValue: gyroState.accelerationCurve)
        _accelerationStrength = Published(initialValue: gyroState.accelerationStrength)
        _sensitivityCap = Published(initialValue: gyroState.sensitivityCap)
        _curveExponent = Published(initialValue: gyroState.curveExponent)
        _rampSpeed = Published(initialValue: gyroState.rampSpeed)
        _softCutoffThreshold = Published(initialValue: gyroState.softCutoffThreshold)
        _recoveryThreshold = Published(initialValue: gyroState.recoveryThreshold)
        _autoTuneSampleRate = Published(initialValue: gyroState.autoTuneSampleRate)
        _autoNeutralEnabled = Published(initialValue: gyroState.autoNeutralEnabled)

        // Joy-Con specific
        if activeControllerKind == .joyCon {
            _joyConTimerFallbackEnabled = Published(initialValue: gyroState.joyConTimerFallbackEnabled)
            _joyConTimerHybridEnabled = Published(initialValue: gyroState.joyConTimerHybridEnabled)
        }

        // Update settings store
        settingsStore.update { s in
            s.activeProfile = activeProfile
            s.gyroSettings[activeControllerKind] = gyroState
        }

        // Also reload button mappings
        reloadButtonMappingForCurrentProfile()

        // Notify UI of refresh
        objectWillChange.send()
    }

    /// Reload button mappings when controller side changes
    private func reloadButtonMappingForCurrentProfile() {
        if activeControllerKind == .sense {
            let profile = SenseButtonMappingProfile.load(for: activeProfile)
            _buttonMappingProfile = Published(initialValue: profile)
            _triggerThreshold = Published(initialValue: profile.triggerThreshold)
            _holdThreshold = Published(initialValue: profile.holdThreshold)
            settingsStore.update { $0.senseButtonMappings[activeProfile] = profile }
        } else {
            let profile: JoyConButtonMappingProfile
            if JoyConButtonMappingProfile.hasPerProfileSettings(for: activeProfile) {
                profile = .load(for: activeProfile)
            } else {
                profile = .defaultProfile(for: activeProfile)
            }
            _joyConButtonMappingProfile = Published(initialValue: profile)
            _holdThreshold = Published(initialValue: profile.holdThreshold)
            settingsStore.update { $0.joyConButtonMappings[activeProfile] = profile }
        }

        // Update settings store with active profile
        settingsStore.update { $0.activeProfile = activeProfile }

        // Notify UI of refresh
        objectWillChange.send()
    }

    // MARK: - Engine Callbacks

    private func setupEngineCallbacks() {
        engine.onControllerListChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshControllerList()
                self?.tryRestoreSavedController()
            }
        }

        engine.onConnectionChanged = { [weak self] connected, name, kind in
            Task { @MainActor in
                self?.isConnected = connected
                self?.controllerName = name ?? (connected ? "Controller" : "Not connected")
                self?.activeControllerKind = kind
                self?.statusMessage = connected ? "Connected: \(name ?? "Controller")" : "Disconnected"
            }
        }

        engine.onRadialMenuShow = { [weak self] position, configuration in
            Task { @MainActor in
                guard let self else { return }
                if self.radialMenuWindowController == nil {
                    self.radialMenuWindowController = RadialMenuWindowController(state: self.radialMenuState)
                }
                self.radialMenuState.show(at: position, configuration: configuration)
                self.radialMenuWindowController?.show(at: position)
            }
        }

        engine.onRadialMenuHide = { [weak self] _ in
            Task { @MainActor in
                self?.radialMenuState.hide()
                self?.radialMenuWindowController?.hide()
            }
        }

        engine.onRadialMenuUpdate = { [weak self] delta in
            Task { @MainActor in
                self?.radialMenuState.updateFromDelta(dx: delta.x, dy: delta.y)
            }
        }
    }

    // MARK: - Controller Management

    func refreshControllerList() {
        availableControllers = engine.availableControllers
    }

    /// Try to restore a previously saved controller selection
    private func tryRestoreSavedController() {
        // Only restore if not already connected
        guard !isConnected else { return }

        // Check if we have a saved selection and the controller is available
        if let savedID = UserDefaults.standard.string(forKey: "selectedControllerID"),
           availableControllers.contains(where: { $0.id == savedID }) {
            selectController(id: savedID)
        }
    }

    func selectController(id: String) {
        guard let info = availableControllers.first(where: { $0.id == id }) else { return }

        selectedControllerID = id
        activeControllerKind = info.kind
        isLeftController = info.isLeft

        // Save selection for persistence across restarts
        UserDefaults.standard.set(id, forKey: "selectedControllerID")

        engine.selectController(id: id, kind: info.kind, isLeft: info.isLeft)

        // Update connection status - use the Bluetooth device name
        isConnected = true
        controllerName = info.name
    }

    func deselectController() {
        selectedControllerID = nil
        isConnected = false
        controllerName = "Not connected"
        batteryLevel = 0

        // Clear saved selection
        UserDefaults.standard.removeObject(forKey: "selectedControllerID")

        engine.deselectController()
    }

    func recalibrate() {
        engine.recalibrate()
        statusMessage = "Calibrating... keep still"

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                statusMessage = "Calibrated!"
            }
        }
    }

    // MARK: - Debug Polling

    func startDebugPolling() {
        guard !debugPollingEnabled else { return }
        debugPollingEnabled = true
        debugBuffer.startRecording()

        debugPollingTimer = Timer.scheduledTimer(withTimeInterval: 1/30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollDebugData()
            }
        }
    }

    func stopDebugPolling() {
        debugPollingEnabled = false
        debugBuffer.stopRecording()
        debugPollingTimer?.invalidate()
        debugPollingTimer = nil
    }

    private func pollDebugData() {
        guard debugPollingEnabled else { return }

        // Get latest sample
        if let sample = debugBuffer.latest() {
            debugSample = sample

            // Update visualization properties
            reportBytes = sample.reportBytes
            reportLength = sample.reportLength

            // Pipeline Stage 1: Raw
            rawGyroX = sample.rawGyro.x
            rawGyroY = sample.rawGyro.y
            rawGyroZ = sample.rawGyro.z

            // Pipeline Stage 2: Remapped
            remappedPitch = sample.remappedGyro.pitch
            remappedYaw = sample.remappedGyro.yaw
            remappedRoll = sample.remappedGyro.roll

            // Pipeline Stage 3: Normalized
            normalizedPitch = sample.normalizedGyro.pitch
            normalizedYaw = sample.normalizedGyro.yaw
            normalizedRoll = sample.normalizedGyro.roll

            // Accel (still raw)
            lastAccelX = sample.accel.x
            lastAccelY = sample.accel.y
            lastAccelZ = sample.accel.z

            // Update button states
            var states: [LogicalButton: Bool] = [:]
            for (index, button) in LogicalButton.allCases.enumerated() {
                if index < sample.buttonStates.count {
                    states[button] = sample.buttonStates[index]
                }
            }
            buttonStates = states
        }

        // Get stats
        debugStats = debugBuffer.stats()
        reportCount = debugStats.reportCount

        // Get byte/bit change tracking
        byteLastChanged = debugBuffer.getByteLastChanged()
        bitLastChanged = debugBuffer.getBitLastChanged()

        // Trigger refresh
        debugRefreshTrigger += 1
    }

    // MARK: - Log Polling

    func startLogPolling() {
        stopLogPolling()
        logPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollLogMessages()
            }
        }
        // Poll immediately once
        pollLogMessages()
    }

    func stopLogPolling() {
        logPollingTimer?.invalidate()
        logPollingTimer = nil
    }

    private func pollLogMessages() {
        debugLog = debugBuffer.getLogMessages()
    }

    func clearLogs() {
        debugLog.removeAll()
        debugBuffer.clearLog()
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        startAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibilityPermission()
                if self?.hasAccessibilityPermission == true {
                    self?.accessibilityTimer?.invalidate()
                    self?.accessibilityTimer = nil
                }
            }
        }
    }

    // MARK: - Gyro Settings Reset

    func resetGyroSettings() {
        let defaults = GyroSettingsState.defaultForKind(activeControllerKind)

        sensitivity = defaults.sensitivity
        gyroScale = defaults.gyroScale
        filterEnabled = defaults.filterEnabled
        minCutoff = defaults.minCutoff
        beta = defaults.beta
        adaptiveSmoothingMode = defaults.adaptiveSmoothingMode
        accelerationMode = defaults.accelerationMode
        simpleAcceleration = defaults.simpleAcceleration
        accelerationCurve = defaults.accelerationCurve
        accelerationStrength = defaults.accelerationStrength
        sensitivityCap = defaults.sensitivityCap
        curveExponent = defaults.curveExponent
        rampSpeed = defaults.rampSpeed
        softCutoffThreshold = defaults.softCutoffThreshold
        recoveryThreshold = defaults.recoveryThreshold
        autoTuneSampleRate = defaults.autoTuneSampleRate
        autoNeutralEnabled = defaults.autoNeutralEnabled

        if activeControllerKind == .joyCon {
            joyConTimerFallbackEnabled = defaults.joyConTimerFallbackEnabled
            joyConTimerHybridEnabled = defaults.joyConTimerHybridEnabled
        }
    }

    // MARK: - Convenience Accessors

    /// Safe accessor for report bytes
    func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }
}
