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

    /// Devices the app should manage (persisted across restarts).
    @Published private(set) var managedDeviceKeys: Set<String> = [] {
        didSet {
            if oldValue != managedDeviceKeys {
                saveManagedDeviceKeys()
                applyManagedDevicesToEngine()
                syncConnectionState()
            }
        }
    }

    /// Connection status
    @Published var isConnected: Bool = false
    @Published var controllerName: String = "No devices managed"
    @Published var activeControllerKind: ControllerKind = .sense {
        didSet {
            if oldValue != activeControllerKind {
                updateG502XInterfaceDebugMode()
            }
        }
    }
    @Published var isLeftController: Bool = false

    /// Profile currently being edited in the settings UI (independent of the active device).
    @Published var configurationProfile: ControllerProfile = .senseRight {
        didSet {
            if oldValue != configurationProfile {
                saveConfigurationProfile()
                reloadSettingsForConfigurationProfile()
            }
        }
    }

    /// Currently active runtime profile (derived from activeControllerKind and isLeftController).
    var runtimeProfile: ControllerProfile {
        ControllerProfile(kind: activeControllerKind, isLeft: isLeftController)
    }

    private enum DefaultsKeys {
        static let configurationKind = "configurationProfile.kind"
        static let configurationIsLeft = "configurationProfile.isLeft"
        static let managedDeviceKeys = "managedDeviceKeys"
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

    /// Whether the current configuration profile is allowed to emit cursor/scroll output.
    /// (USB mice are never affected.)
    @Published var cursorControlEnabled: Bool = true {
        didSet {
            let profile = configurationProfile
            guard profile.kind != .mouse else { return }
            saveCursorControlEnabled(for: profile, enabled: cursorControlEnabled)
            settingsStore.update { $0.cursorControlEnabledByProfile[profile] = cursorControlEnabled }
        }
    }

    // Gyro settings
    @Published var sensitivity: Double = 50.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var gyroScale: Double = 1.0 / 16.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var filterEnabled: Bool = true {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var minCutoff: Double = 0.5 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var beta: Double = 1.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speed {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var accelerationMode: AccelerationMode = .simple {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var simpleAcceleration: Double = 5.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var accelerationCurve: AccelerationCurve = .power {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var accelerationStrength: Double = 10.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var sensitivityCap: Double = 20.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var curveExponent: Double = 1.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var rampSpeed: Double = 150.0 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var softCutoffThreshold: Double = 0.5 {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var recoveryThreshold: Double = 1.5 {
        didSet {
            saveGyroSettings()
        }
    }

    // Button mapping (per-profile)
    @Published var buttonMappingProfile: SenseButtonMappingProfile = .load() {
        didSet {
            guard configurationProfile.kind == .sense else { return }
            let profile = configurationProfile
            buttonMappingProfile.save(for: profile)
            settingsStore.update { $0.senseButtonMappings[profile] = buttonMappingProfile }
        }
    }

    // Joy-Con button mapping (per-profile)
    @Published var joyConButtonMappingProfile: JoyConButtonMappingProfile = .load() {
        didSet {
            guard configurationProfile.kind == .joyCon else { return }
            let profile = configurationProfile
            joyConButtonMappingProfile.save(for: profile)
            settingsStore.update { $0.joyConButtonMappings[profile] = joyConButtonMappingProfile }
        }
    }

    // G502X button mapping (per-profile)
    @Published var g502xButtonMappingProfile: G502XButtonMappingProfile = .load() {
        didSet {
            guard configurationProfile.kind == .mouse else { return }
            let profile = configurationProfile
            g502xButtonMappingProfile.save(for: profile)
            settingsStore.update { $0.g502xButtonMappings[profile] = g502xButtonMappingProfile }
        }
    }

    // Joystick settings
    @Published var joystickScrollEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(joystickScrollEnabled, forKey: "joystick.scrollEnabled")
            settingsStore.update { $0.joystickScrollEnabled = joystickScrollEnabled }
        }
    }

    @Published var joystickScrollSpeed: Double = 10.0 {
        didSet {
            UserDefaults.standard.set(joystickScrollSpeed, forKey: "joystick.scrollSpeed")
            settingsStore.update { $0.joystickScrollSpeed = joystickScrollSpeed }
        }
    }

    @Published var joystickScrollAcceleration: Double = 3.0 {
        didSet {
            UserDefaults.standard.set(joystickScrollAcceleration, forKey: "joystick.scrollAcceleration")
            settingsStore.update { $0.joystickScrollAcceleration = joystickScrollAcceleration }
        }
    }

    @Published var joyConTimerFallbackEnabled: Bool = true {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var joyConTimerHybridEnabled: Bool = false {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var autoTuneSampleRate: Bool = false {
        didSet {
            saveGyroSettings()
        }
    }

    @Published var autoNeutralEnabled: Bool = true {
        didSet {
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

    // MARK: - Polling Tasks

    private var debugPollingTask: Task<Void, Never>?
    private var logPollingTask: Task<Void, Never>?
    private var accessibilityPollingTask: Task<Void, Never>?

    // MARK: - Tab Enum

    enum ActiveTab: String {
        case controller, mouse, buttons, joystick, radial, debug, log
    }

    // MARK: - Initialization

    private var engineDidStart: Bool = false

    private static func loadSavedConfigurationProfile() -> ControllerProfile? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: DefaultsKeys.configurationKind),
              let kind = ControllerKind(rawValue: raw) else {
            return nil
        }

        let isLeft = defaults.bool(forKey: DefaultsKeys.configurationIsLeft)
        return ControllerProfile(kind: kind, isLeft: kind.hasSides ? isLeft : false)
    }

    private func saveConfigurationProfile() {
        let defaults = UserDefaults.standard
        defaults.set(configurationProfile.kind.rawValue, forKey: DefaultsKeys.configurationKind)
        defaults.set(configurationProfile.isLeft, forKey: DefaultsKeys.configurationIsLeft)
    }

    private static func cursorControlEnabledKey(for profile: ControllerProfile) -> String {
        "cursorControlEnabled.\(profile.persistenceKey)"
    }

    private func saveCursorControlEnabled(for profile: ControllerProfile, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.cursorControlEnabledKey(for: profile))
    }

    init() {
        // Create the core components
        self.settingsStore = SettingsStore()
        self.debugBuffer = DebugBuffer()
        self.engine = InputEngine(settings: settingsStore, debugBuffer: debugBuffer)

        _managedDeviceKeys = Published(initialValue: Self.loadManagedDeviceKeys())

        // Restore last configuration target (independent of which device is active).
        _configurationProfile = Published(initialValue: Self.loadSavedConfigurationProfile() ?? .senseRight)

        // Load settings from store into published properties
        loadSettingsFromStore()

        // Setup engine callbacks for UI updates
        setupEngineCallbacks()
    }

    deinit {
        debugPollingTask?.cancel()
        logPollingTask?.cancel()
        accessibilityPollingTask?.cancel()
    }

    // MARK: - Engine Lifecycle

    /// Start the input engine - call after UI is ready
    func startEngine() {
        if engineDidStart {
            refreshControllerList()
            syncConnectionState()
            return
        }
        engineDidStart = true

        engine.start()
        refreshControllerList()

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

        let managedAvailable = availableControllers.filter { managedDeviceKeys.contains($0.managementKey) }
        isConnected = engine.isConnected

        guard !managedAvailable.isEmpty else {
            activeControllerKind = .sense
            isLeftController = false
            if managedDeviceKeys.isEmpty {
                controllerName = "No devices managed"
            } else {
                controllerName = "Waiting for managed devices..."
            }
            if !isConnected {
                batteryLevel = 0
            }
            return
        }

        func kindSortIndex(_ kind: ControllerKind) -> Int {
            switch kind {
            case .sense: return 0
            case .joyCon: return 1
            case .mouse: return 2
            }
        }

        let primary = managedAvailable.sorted { a, b in
            if kindSortIndex(a.kind) != kindSortIndex(b.kind) {
                return kindSortIndex(a.kind) < kindSortIndex(b.kind)
            }
            if a.isLeft != b.isLeft {
                return a.isLeft && !b.isLeft
            }
            return a.name < b.name
        }.first!

        activeControllerKind = primary.kind
        isLeftController = primary.isLeft

        if managedAvailable.count == 1 {
            controllerName = primary.kind.hasSides ? "\(primary.name) (\(primary.side))" : primary.name
        } else {
            controllerName = "Managing \(managedAvailable.count) devices"
        }

        // On first run (no saved configuration target), default to configuring the primary managed device.
        if UserDefaults.standard.string(forKey: DefaultsKeys.configurationKind) == nil {
            configurationProfile = ControllerProfile(from: primary)
        }
    }

    /// Stop the input engine
    func stopEngine() {
        guard engineDidStart else { return }
        engineDidStart = false

        engine.stop()
        stopLogPolling()
        stopDebugPolling()
    }

    // MARK: - Settings Loading

    private func loadSettingsFromStore() {
        let s = settingsStore.snapshot()

        // Don't trigger didSet during init
        _isEnabled = Published(initialValue: s.isEnabled)

        _joystickScrollEnabled = Published(initialValue: s.joystickScrollEnabled)
        _joystickScrollSpeed = Published(initialValue: s.joystickScrollSpeed)
        _joystickScrollAcceleration = Published(initialValue: s.joystickScrollAcceleration)

        _radialMenuConfiguration = Published(initialValue: s.radialMenuConfiguration)

        // Load settings for the restored configuration target.
        reloadSettingsForConfigurationProfile()
    }

    private func saveGyroSettings() {
        // Save to per-type gyro settings for persistence
        let kind = configurationProfile.kind
        var state = GyroSettingsState.load(for: kind)
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
        if kind == .joyCon {
            state.joyConTimerFallbackEnabled = joyConTimerFallbackEnabled
            state.joyConTimerHybridEnabled = joyConTimerHybridEnabled
        }

        state.save(for: kind)
        settingsStore.update { $0.gyroSettings[kind] = state }
    }

    /// Reload all configurable settings for the current configuration target.
    private func reloadSettingsForConfigurationProfile() {
        let kind = configurationProfile.kind
        let profile = configurationProfile
        let gyroState = GyroSettingsState.load(for: kind)

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
        if kind == .joyCon {
            _joyConTimerFallbackEnabled = Published(initialValue: gyroState.joyConTimerFallbackEnabled)
            _joyConTimerHybridEnabled = Published(initialValue: gyroState.joyConTimerHybridEnabled)
        }

        // Update settings store
        settingsStore.update { s in
            s.gyroSettings[kind] = gyroState
        }

        // Cursor control enablement (per profile; default true).
        if profile.kind != .mouse {
            let enabled = settingsStore.snapshot().cursorControlEnabledByProfile[profile] ?? true
            _cursorControlEnabled = Published(initialValue: enabled)
            settingsStore.update { $0.cursorControlEnabledByProfile[profile] = enabled }
        } else {
            _cursorControlEnabled = Published(initialValue: true)
        }

        // Also reload button mappings
        reloadButtonMappingForConfigurationProfile()

        // Notify UI of refresh
        objectWillChange.send()
    }

    /// Reload per-profile button mappings for the current configuration target.
    private func reloadButtonMappingForConfigurationProfile() {
        let profile = configurationProfile
        switch profile.kind {
        case .sense:
            let mapping = SenseButtonMappingProfile.load(for: profile)
            _buttonMappingProfile = Published(initialValue: mapping)
            settingsStore.update { $0.senseButtonMappings[profile] = mapping }

        case .joyCon:
            let mapping: JoyConButtonMappingProfile
            if JoyConButtonMappingProfile.hasPerProfileSettings(for: profile) {
                mapping = .load(for: profile)
            } else {
                mapping = .defaultProfile(for: profile)
            }
            _joyConButtonMappingProfile = Published(initialValue: mapping)
            settingsStore.update { $0.joyConButtonMappings[profile] = mapping }

        case .mouse:
            let mapping: G502XButtonMappingProfile
            if G502XButtonMappingProfile.hasPerProfileSettings(for: profile) {
                mapping = .load(for: profile)
            } else {
                mapping = .default
            }
            _g502xButtonMappingProfile = Published(initialValue: mapping)
            settingsStore.update { $0.g502xButtonMappings[profile] = mapping }
        }

        // Notify UI of refresh
        objectWillChange.send()
    }

    // MARK: - Engine Callbacks

    private func setupEngineCallbacks() {
        engine.onControllerListChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshControllerList()
                self?.applyManagedDevicesToEngine()
                self?.syncConnectionState()
            }
        }

        engine.onConnectionChanged = { [weak self] connected, name, kind in
            Task { @MainActor in
                guard let self else { return }
                self.syncConnectionState()
                self.statusMessage = self.isConnected ? "Connected" : "Disconnected"
            }
        }

        engine.onBatteryLevelChanged = { [weak self] level in
            Task { @MainActor in
                self?.batteryLevel = level
            }
        }

        engine.onRadialMenuShow = { [weak self] position, configuration, pointerStyle in
            Task { @MainActor in
                guard let self else { return }
                if self.radialMenuWindowController == nil {
                    self.radialMenuWindowController = RadialMenuWindowController(state: self.radialMenuState)
                }
                self.radialMenuState.show(at: position, configuration: configuration, pointerStyle: pointerStyle)
                self.radialMenuWindowController?.show(at: position)
            }
        }

        engine.onRadialMenuHide = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.radialMenuState.hide()
                self.radialMenuWindowController?.hide()
            }
        }

        engine.onRadialMenuUpdate = { [weak self] delta in
            Task { @MainActor in
                self?.radialMenuState.updateFromDelta(dx: delta.x, dy: delta.y)
            }
        }

        engine.onRadialMenuSetPosition = { [weak self] offset in
            Task { @MainActor in
                self?.radialMenuState.setAbsolutePosition(dx: offset.x, dy: offset.y)
            }
        }
    }

    // MARK: - Controller Management

    func refreshControllerList() {
        availableControllers = engine.availableControllers
    }

    func isDeviceManaged(_ controller: ControllerInfo) -> Bool {
        managedDeviceKeys.contains(controller.managementKey)
    }

    func setDeviceManaged(_ controller: ControllerInfo, managed: Bool) {
        var updated = managedDeviceKeys
        if managed {
            // The G502X path currently supports one managed mouse at a time.
            if controller.kind == .mouse {
                let prefix = "\(controller.kind.rawValue):"
                updated = Set(updated.filter { !$0.hasPrefix(prefix) })
            }
            updated.insert(controller.managementKey)
        } else {
            updated.remove(controller.managementKey)
        }
        managedDeviceKeys = updated
    }

    private static func loadManagedDeviceKeys() -> Set<String> {
        let defaults = UserDefaults.standard
        if let raw = defaults.array(forKey: DefaultsKeys.managedDeviceKeys) as? [String] {
            return Set(raw)
        }

        // Migration: seed managed devices from legacy single-selection keys (if present).
        var migrated: Set<String> = []
        if let id = defaults.string(forKey: "lastSelectedControllerID") {
            migrated.insert("\(ControllerKind.sense.rawValue):\(id)")
        }
        if let id = defaults.string(forKey: "lastSelectedJoyConControllerID") {
            migrated.insert("\(ControllerKind.joyCon.rawValue):\(id)")
        }
        if let id = defaults.string(forKey: "lastSelectedMouseID") {
            migrated.insert("\(ControllerKind.mouse.rawValue):\(id)")
        }

        if !migrated.isEmpty {
            defaults.set(Array(migrated).sorted(), forKey: DefaultsKeys.managedDeviceKeys)
        }
        return migrated
    }

    private func saveManagedDeviceKeys() {
        let defaults = UserDefaults.standard
        defaults.set(Array(managedDeviceKeys).sorted(), forKey: DefaultsKeys.managedDeviceKeys)
    }

    private func applyManagedDevicesToEngine() {
        guard engineDidStart else { return }
        // Ensure engine selections track our persisted managed set.
        for controller in availableControllers {
            let managed = managedDeviceKeys.contains(controller.managementKey)
            engine.setDeviceManaged(id: controller.id, kind: controller.kind, isLeft: controller.isLeft, managed: managed)
        }
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
        startDebugPolling(targetKind: nil)
    }

    func startDebugPolling(targetKind: ControllerKind?) {
        guard !debugPollingEnabled else { return }
        debugPollingEnabled = true
        debugBuffer.startRecording()
        settingsStore.update {
            $0.debugRecordingEnabled = true
            $0.debugRecordingTargetKind = targetKind
        }
        updateG502XInterfaceDebugMode()

        debugPollingTask?.cancel()
        debugPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.debugPollingEnabled {
                self.pollDebugData()
                try? await Task.sleep(nanoseconds: 33_333_333) // ~30Hz
            }
        }
    }

    func stopDebugPolling() {
        debugPollingEnabled = false
        debugBuffer.stopRecording()
        settingsStore.update {
            $0.debugRecordingEnabled = false
            $0.debugRecordingTargetKind = nil
        }
        debugPollingTask?.cancel()
        debugPollingTask = nil
        updateG502XInterfaceDebugMode()
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

    private func updateG502XInterfaceDebugMode() {
        let target = settingsStore.snapshot().debugRecordingTargetKind
        engine.g502xController.setInterfaceDebugEnabled(debugPollingEnabled && (target == nil || target == .mouse))
    }

    // MARK: - Log Polling

    func startLogPolling() {
        guard logPollingTask == nil else { return }

        // Poll immediately once
        pollLogMessages()

        logPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                self.pollLogMessages()
            }
        }
    }

    func stopLogPolling() {
        logPollingTask?.cancel()
        logPollingTask = nil
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
        accessibilityPollingTask?.cancel()
        accessibilityPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<60 where !Task.isCancelled {
                self.checkAccessibilityPermission()
                if self.hasAccessibilityPermission {
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Gyro Settings Reset

    func resetGyroSettings() {
        let defaults = GyroSettingsState.defaultForKind(configurationProfile.kind)

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

        if configurationProfile.kind == .joyCon {
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

    /// Get G502X HID interface info for debug display
    func getG502XInterfaceInfo() -> [G502XInterfaceInfo] {
        engine.g502xController.getInterfaceInfo()
    }
}
