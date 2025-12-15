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

    /// True while programmatically loading persisted settings into published properties.
    /// Prevents `didSet` side effects (writes/persistence) during reload.
    private var isApplyingLoadedSettings: Bool = false

    private func withApplyingLoadedSettings<T>(_ body: () -> T) -> T {
        let wasApplyingLoadedSettings = isApplyingLoadedSettings
        isApplyingLoadedSettings = true
        defer { isApplyingLoadedSettings = wasApplyingLoadedSettings }
        return body()
    }

    @Published var isEnabled: Bool = true {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            settingsStore.update { $0.isEnabled = isEnabled }
        }
    }

    /// Whether the current configuration profile is allowed to emit cursor/scroll output.
    /// (USB mice are never affected.)
    @Published var cursorControlEnabled: Bool = true {
        didSet {
            guard !isApplyingLoadedSettings else { return }
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
            guard !isApplyingLoadedSettings else { return }
            guard configurationProfile.kind == .sense else { return }
            let profile = configurationProfile
            let mapping = buttonMappingProfile
            settingsStore.update { $0.senseButtonMappings[profile] = mapping }
            scheduleSenseButtonMappingPersistence(profile: profile, mapping: mapping)
        }
    }

    // Joy-Con button mapping (per-profile)
    @Published var joyConButtonMappingProfile: JoyConButtonMappingProfile = .load() {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            guard configurationProfile.kind == .joyCon else { return }
            let profile = configurationProfile
            let mapping = joyConButtonMappingProfile
            settingsStore.update { $0.joyConButtonMappings[profile] = mapping }
            scheduleJoyConButtonMappingPersistence(profile: profile, mapping: mapping)
        }
    }

    // G502X button mapping (per-profile)
    @Published var g502xButtonMappingProfile: G502XButtonMappingProfile = .load() {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            guard configurationProfile.kind == .mouse else { return }
            let profile = configurationProfile
            let mapping = g502xButtonMappingProfile
            settingsStore.update { $0.g502xButtonMappings[profile] = mapping }
            scheduleG502XButtonMappingPersistence(profile: profile, mapping: mapping)
        }
    }

    // Joystick settings
    @Published var joystickScrollEnabled: Bool = true {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            settingsStore.update { $0.joystickScrollEnabled = joystickScrollEnabled }
            scheduleJoystickSettingsPersistence(
                enabled: joystickScrollEnabled,
                speed: joystickScrollSpeed,
                acceleration: joystickScrollAcceleration
            )
        }
    }

    @Published var joystickScrollSpeed: Double = 10.0 {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            settingsStore.update { $0.joystickScrollSpeed = joystickScrollSpeed }
            scheduleJoystickSettingsPersistence(
                enabled: joystickScrollEnabled,
                speed: joystickScrollSpeed,
                acceleration: joystickScrollAcceleration
            )
        }
    }

    @Published var joystickScrollAcceleration: Double = 3.0 {
        didSet {
            guard !isApplyingLoadedSettings else { return }
            settingsStore.update { $0.joystickScrollAcceleration = joystickScrollAcceleration }
            scheduleJoystickSettingsPersistence(
                enabled: joystickScrollEnabled,
                speed: joystickScrollSpeed,
                acceleration: joystickScrollAcceleration
            )
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

    @Published var joyConUseAveragedGyroSamples: Bool = false {
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
            guard !isApplyingLoadedSettings else { return }
            let config = radialMenuConfiguration
            settingsStore.update { $0.radialMenuConfiguration = config }
            scheduleRadialMenuPersistence(configuration: config)
        }
    }

    /// Radial menu state (for overlay UI)
    let radialMenuState = RadialMenuState()

    /// Radial menu window controller
    private var radialMenuWindowController: RadialMenuWindowController?

    // MARK: - Debounced Persistence

    private var gyroSettingsSaveTasks: [ControllerKind: Task<Void, Never>] = [:]

    private var joystickSettingsSaveTask: Task<Void, Never>?

    private var radialMenuSaveTask: Task<Void, Never>?

    private var senseButtonMappingSaveTasks: [ControllerProfile: Task<Void, Never>] = [:]
    private var joyConButtonMappingSaveTasks: [ControllerProfile: Task<Void, Never>] = [:]
    private var g502xButtonMappingSaveTasks: [ControllerProfile: Task<Void, Never>] = [:]

    // MARK: - Debug State (Polled, not pushed)

    /// Whether debug polling is active
    @Published var debugPollingEnabled: Bool = false

    /// High-frequency debug telemetry (kept off AppState to avoid invalidating other UI).
    let debugTelemetry = DebugTelemetryState()

    // MARK: - Log State

    @Published var debugLog: [String] = []

    // MARK: - Polling Tasks

    var debugPollingTask: Task<Void, Never>?
    var logPollingTask: Task<Void, Never>?
    var accessibilityPollingTask: Task<Void, Never>?

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
        guard !isApplyingLoadedSettings else { return }
        let kind = configurationProfile.kind
        var state = settingsStore.snapshot().gyroSettings[kind] ?? GyroSettingsState.load(for: kind)
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
            state.joyConUseAveragedGyroSamples = joyConUseAveragedGyroSamples
        }

        let updatedState = state
        settingsStore.update { $0.gyroSettings[kind] = updatedState }
        scheduleGyroSettingsPersistence(kind: kind, state: updatedState)
    }

    private static let persistenceDebounceNanoseconds: UInt64 = 250_000_000

    private func scheduleGyroSettingsPersistence(kind: ControllerKind, state: GyroSettingsState) {
        gyroSettingsSaveTasks[kind]?.cancel()
        gyroSettingsSaveTasks[kind] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            state.save(for: kind)
        }
    }

    private func scheduleJoystickSettingsPersistence(enabled: Bool, speed: Double, acceleration: Double) {
        joystickSettingsSaveTask?.cancel()
        joystickSettingsSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let defaults = UserDefaults.standard
            defaults.set(enabled, forKey: "joystick.scrollEnabled")
            defaults.set(speed, forKey: "joystick.scrollSpeed")
            defaults.set(acceleration, forKey: "joystick.scrollAcceleration")
        }
    }

    private func scheduleRadialMenuPersistence(configuration: RadialMenuConfiguration) {
        radialMenuSaveTask?.cancel()
        radialMenuSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            configuration.save()
        }
    }

    private func scheduleSenseButtonMappingPersistence(profile: ControllerProfile, mapping: SenseButtonMappingProfile) {
        senseButtonMappingSaveTasks[profile]?.cancel()
        senseButtonMappingSaveTasks[profile] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            mapping.save(for: profile)
        }
    }

    private func scheduleJoyConButtonMappingPersistence(profile: ControllerProfile, mapping: JoyConButtonMappingProfile) {
        joyConButtonMappingSaveTasks[profile]?.cancel()
        joyConButtonMappingSaveTasks[profile] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            mapping.save(for: profile)
        }
    }

    private func scheduleG502XButtonMappingPersistence(profile: ControllerProfile, mapping: G502XButtonMappingProfile) {
        g502xButtonMappingSaveTasks[profile]?.cancel()
        g502xButtonMappingSaveTasks[profile] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            mapping.save(for: profile)
        }
    }

    /// Reload all configurable settings for the current configuration target.
    private func reloadSettingsForConfigurationProfile() {
        let kind = configurationProfile.kind
        let profile = configurationProfile
        let gyroState = GyroSettingsState.load(for: kind)

        // Update settings store
        settingsStore.update { s in
            s.gyroSettings[kind] = gyroState
        }

        withApplyingLoadedSettings {
            sensitivity = gyroState.sensitivity
            gyroScale = gyroState.gyroScale
            filterEnabled = gyroState.filterEnabled
            minCutoff = gyroState.minCutoff
            beta = gyroState.beta
            adaptiveSmoothingMode = gyroState.adaptiveSmoothingMode
            accelerationMode = gyroState.accelerationMode
            simpleAcceleration = gyroState.simpleAcceleration
            accelerationCurve = gyroState.accelerationCurve
            accelerationStrength = gyroState.accelerationStrength
            sensitivityCap = gyroState.sensitivityCap
            curveExponent = gyroState.curveExponent
            rampSpeed = gyroState.rampSpeed
            softCutoffThreshold = gyroState.softCutoffThreshold
            recoveryThreshold = gyroState.recoveryThreshold
            autoTuneSampleRate = gyroState.autoTuneSampleRate
            autoNeutralEnabled = gyroState.autoNeutralEnabled

            // Joy-Con specific
            if kind == .joyCon {
                joyConTimerFallbackEnabled = gyroState.joyConTimerFallbackEnabled
                joyConTimerHybridEnabled = gyroState.joyConTimerHybridEnabled
                joyConUseAveragedGyroSamples = gyroState.joyConUseAveragedGyroSamples
            }

            // Cursor control enablement (per profile; default true).
            if profile.kind != .mouse {
                let enabled = settingsStore.snapshot().cursorControlEnabledByProfile[profile] ?? true
                cursorControlEnabled = enabled
                settingsStore.update { $0.cursorControlEnabledByProfile[profile] = enabled }
            } else {
                cursorControlEnabled = true
            }

            // Also reload button mappings
            reloadButtonMappingForConfigurationProfile()
        }
    }

    /// Reload per-profile button mappings for the current configuration target.
    private func reloadButtonMappingForConfigurationProfile() {
        let profile = configurationProfile
        withApplyingLoadedSettings {
            switch profile.kind {
            case .sense:
                let mapping = SenseButtonMappingProfile.load(for: profile)
                buttonMappingProfile = mapping
                settingsStore.update { $0.senseButtonMappings[profile] = mapping }

            case .joyCon:
                let mapping: JoyConButtonMappingProfile
                if JoyConButtonMappingProfile.hasPerProfileSettings(for: profile) {
                    mapping = .load(for: profile)
                } else {
                    mapping = .defaultProfile(for: profile)
                }
                joyConButtonMappingProfile = mapping
                settingsStore.update { $0.joyConButtonMappings[profile] = mapping }

            case .mouse:
                let mapping: G502XButtonMappingProfile
                if G502XButtonMappingProfile.hasPerProfileSettings(for: profile) {
                    mapping = .load(for: profile)
                } else {
                    mapping = .default
                }
                g502xButtonMappingProfile = mapping
                settingsStore.update { $0.g502xButtonMappings[profile] = mapping }
            }
        }
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
}
