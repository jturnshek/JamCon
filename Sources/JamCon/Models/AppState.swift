import SwiftUI
import Combine
import os.lock
import ApplicationServices  // For AXIsProcessTrusted
import Foundation

// MARK: - Tuning Modes

enum AccelerationMode: String, Codable, Hashable, CaseIterable {
    case legacy

    var displayName: String {
        return "Legacy (Raw Gain)"
    }
}

enum AdaptiveSmoothingMode: String, Codable, Hashable, CaseIterable {
    case off
    case speed
    case speedAndJerk

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .speed: return "Speed-aware"
        case .speedAndJerk: return "Speed + Jerk"
        }
    }
}


/// Thread-safe settings cache for input processing
/// Avoids main thread dispatch for high-frequency gyro updates
final class InputSettings: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()

    private var _isEnabled: Bool = true
    private var _gyroSensitivity: Double = 30.0
    private var _scrollSensitivity: Double = 10.0
    private var _gyroDeadzone: Double = 1.0
    private var _stickDeadzone: Double = 0.15
    private var _smoothThreshold: Double = 20.0
    private var _controllerType: ControllerType = .none
    private var _primaryMapping: ButtonMappingProfile = .defaultPrimary
    private var _secondaryMapping: ButtonMappingProfile = .defaultSecondary
    private var _primaryControllerId: UUID? = nil
    private var _mirrorFaceButtons: Bool = true
    private var _holdThreshold: Double = 0.6
    private var _filterBeta: Double = 0.5
    private var _accelerationGain: Double = 80.0
    private var _precisionZoneEnabled: Bool = false
    private var _earlyRampEnabled: Bool = false
    private var _primaryClutchButtons: Set<LogicalButton> = []
    private var _secondaryClutchButtons: Set<LogicalButton> = []
    private var _primaryScrollButtons: Set<LogicalButton> = []
    private var _secondaryScrollButtons: Set<LogicalButton> = []
    private var _primaryZoomButtons: Set<LogicalButton> = []
    private var _secondaryZoomButtons: Set<LogicalButton> = []
    private var _accelerationMode: AccelerationMode = .legacy
    private var _adaptiveSmoothingMode: AdaptiveSmoothingMode = .speedAndJerk
    private var _autoNeutralRefresh: Bool = true
    private var _idleTimeoutMinutes: Double = 15.0
    private var _autoPowerOffEnabled: Bool = true
    private var _stickMode: StickMode = .scroll

    var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }

    var gyroSensitivity: Double {
        get { lock.withLock { _gyroSensitivity } }
        set { lock.withLock { _gyroSensitivity = newValue } }
    }

    var scrollSensitivity: Double {
        get { lock.withLock { _scrollSensitivity } }
        set { lock.withLock { _scrollSensitivity = newValue } }
    }

    var gyroDeadzone: Double {
        get { lock.withLock { _gyroDeadzone } }
        set { lock.withLock { _gyroDeadzone = newValue } }
    }

    var stickDeadzone: Double {
        get { lock.withLock { _stickDeadzone } }
        set { lock.withLock { _stickDeadzone = newValue } }
    }

    var smoothThreshold: Double {
        get { lock.withLock { _smoothThreshold } }
        set { lock.withLock { _smoothThreshold = newValue } }
    }

    var controllerType: ControllerType {
        get { lock.withLock { _controllerType } }
        set { lock.withLock { _controllerType = newValue } }
    }

    var primaryMapping: ButtonMappingProfile {
        get { lock.withLock { _primaryMapping } }
        set { lock.withLock { _primaryMapping = newValue } }
    }

    var secondaryMapping: ButtonMappingProfile {
        get { lock.withLock { _secondaryMapping } }
        set { lock.withLock { _secondaryMapping = newValue } }
    }

    var primaryControllerId: UUID? {
        get { lock.withLock { _primaryControllerId } }
        set { lock.withLock { _primaryControllerId = newValue } }
    }

    var mirrorFaceButtons: Bool {
        get { lock.withLock { _mirrorFaceButtons } }
        set { lock.withLock { _mirrorFaceButtons = newValue } }
    }

    var holdThreshold: Double {
        get { lock.withLock { _holdThreshold } }
        set { lock.withLock { _holdThreshold = newValue } }
    }

    var filterBeta: Double {
        get { lock.withLock { _filterBeta } }
        set { lock.withLock { _filterBeta = newValue } }
    }

    var accelerationGain: Double {
        get { lock.withLock { _accelerationGain } }
        set { lock.withLock { _accelerationGain = newValue } }
    }
    var precisionZoneEnabled: Bool {
        get { lock.withLock { _precisionZoneEnabled } }
        set { lock.withLock { _precisionZoneEnabled = newValue } }
    }
    var earlyRampEnabled: Bool {
        get { lock.withLock { _earlyRampEnabled } }
        set { lock.withLock { _earlyRampEnabled = newValue } }
    }

    var accelerationMode: AccelerationMode {
        get { lock.withLock { _accelerationMode } }
        set { lock.withLock { _accelerationMode = newValue } }
    }

    var adaptiveSmoothingMode: AdaptiveSmoothingMode {
        get { lock.withLock { _adaptiveSmoothingMode } }
        set { lock.withLock { _adaptiveSmoothingMode = newValue } }
    }

    var autoNeutralRefresh: Bool {
        get { lock.withLock { _autoNeutralRefresh } }
        set { lock.withLock { _autoNeutralRefresh = newValue } }
    }

    var primaryClutchButtons: Set<LogicalButton> {
        get { lock.withLock { _primaryClutchButtons } }
        set { lock.withLock { _primaryClutchButtons = newValue } }
    }

    var secondaryClutchButtons: Set<LogicalButton> {
        get { lock.withLock { _secondaryClutchButtons } }
        set { lock.withLock { _secondaryClutchButtons = newValue } }
    }

    var primaryScrollButtons: Set<LogicalButton> {
        get { lock.withLock { _primaryScrollButtons } }
        set { lock.withLock { _primaryScrollButtons = newValue } }
    }

    var secondaryScrollButtons: Set<LogicalButton> {
        get { lock.withLock { _secondaryScrollButtons } }
        set { lock.withLock { _secondaryScrollButtons = newValue } }
    }

    var primaryZoomButtons: Set<LogicalButton> {
        get { lock.withLock { _primaryZoomButtons } }
        set { lock.withLock { _primaryZoomButtons = newValue } }
    }

    var secondaryZoomButtons: Set<LogicalButton> {
        get { lock.withLock { _secondaryZoomButtons } }
        set { lock.withLock { _secondaryZoomButtons = newValue } }
    }

    var idleTimeoutMinutes: Double {
        get { lock.withLock { _idleTimeoutMinutes } }
        set { lock.withLock { _idleTimeoutMinutes = newValue } }
    }

    var autoPowerOffEnabled: Bool {
        get { lock.withLock { _autoPowerOffEnabled } }
        set { lock.withLock { _autoPowerOffEnabled = newValue } }
    }

    var stickMode: StickMode {
        get { lock.withLock { _stickMode } }
        set { lock.withLock { _stickMode = newValue } }
    }

    /// Atomically capture all settings needed for button press handling
    /// This prevents race conditions where settings could change between reads
    func buttonPressSnapshot(for controllerId: UUID?) -> (
        isEnabled: Bool,
        isPrimary: Bool,
        mapping: ButtonMappingProfile,
        clutchButtons: Set<LogicalButton>,
        scrollButtons: Set<LogicalButton>,
        zoomButtons: Set<LogicalButton>,
        holdThreshold: Double,
        mirrorFaceButtons: Bool
    ) {
        lock.withLock {
            let isPrimary = _primaryControllerId == controllerId
            return (
                isEnabled: _isEnabled,
                isPrimary: isPrimary,
                mapping: isPrimary ? _primaryMapping : _secondaryMapping,
                clutchButtons: isPrimary ? _primaryClutchButtons : _secondaryClutchButtons,
                scrollButtons: isPrimary ? _primaryScrollButtons : _secondaryScrollButtons,
                zoomButtons: isPrimary ? _primaryZoomButtons : _secondaryZoomButtons,
                holdThreshold: _holdThreshold,
                mirrorFaceButtons: _mirrorFaceButtons
            )
        }
    }
}

/// Shared application state
@MainActor
class AppState: ObservableObject {
    // MARK: - Connection State
    @Published var connectedControllers: [ConnectedController] = []

    /// Primary controller preference stored by type ("left", "right", or "" for auto)
    @AppStorage("preferredPrimaryType") var preferredPrimaryType: String = ""

    /// The primary controller (controls mouse + uses primary mapping)
    var primaryController: ConnectedController? {
        // If user has a type preference and that type is connected, use it
        if !preferredPrimaryType.isEmpty {
            let targetType: ControllerType = preferredPrimaryType == "left" ? .leftJoyCon : .rightJoyCon
            if let controller = connectedControllers.first(where: { $0.type == targetType }) {
                return controller
            }
        }
        // Otherwise use the first connected controller
        return connectedControllers.first
    }

    /// The secondary controller (uses secondary mapping, no gyro)
    var secondaryController: ConnectedController? {
        guard connectedControllers.count > 1 else { return nil }
        return connectedControllers.first { $0.id != primaryController?.id }
    }

    /// Convenience: is any controller connected
    var isConnected: Bool {
        !connectedControllers.isEmpty
    }

    /// Convenience: primary controller type (for UI backward compatibility)
    var controllerType: ControllerType {
        primaryController?.type ?? .none
    }

    /// Convenience: primary controller battery (for UI backward compatibility)
    var batteryLevel: BatteryLevel {
        primaryController?.batteryLevel ?? .unknown
    }

    // MARK: - Settings (persisted)
    @AppStorage("isEnabled") var isEnabled: Bool = true {
        didSet { inputSettings.isEnabled = isEnabled }
    }
    @AppStorage("gyroSensitivity") var gyroSensitivity: Double = 15.0 {
        didSet { inputSettings.gyroSensitivity = gyroSensitivity }
    }
    @AppStorage("scrollSensitivity") var scrollSensitivity: Double = 10.0 {
        didSet { inputSettings.scrollSensitivity = scrollSensitivity }
    }
    @AppStorage("gyroDeadzone") var gyroDeadzone: Double = 1.0 {
        didSet { inputSettings.gyroDeadzone = gyroDeadzone }
    }
    @AppStorage("stickDeadzone") var stickDeadzone: Double = 0.15 {
        didSet { inputSettings.stickDeadzone = stickDeadzone }
    }
    @AppStorage("smoothThreshold") var smoothThreshold: Double = 0.0 {
        didSet { inputSettings.smoothThreshold = smoothThreshold }
    }
    @AppStorage("mirrorFaceButtons") var mirrorFaceButtons: Bool = false {
        didSet { inputSettings.mirrorFaceButtons = mirrorFaceButtons }
    }
    @AppStorage("holdThreshold") var holdThreshold: Double = 0.6 {
        didSet { inputSettings.holdThreshold = holdThreshold }
    }
    @AppStorage("filterBeta") var filterBeta: Double = 0.0 {
        didSet { inputSettings.filterBeta = filterBeta }
    }
    @AppStorage("accelerationGain") var accelerationGain: Double = 175.0 {
        didSet { inputSettings.accelerationGain = accelerationGain }
    }
    @AppStorage("precisionZoneEnabled") var precisionZoneEnabled: Bool = true {
        didSet { inputSettings.precisionZoneEnabled = precisionZoneEnabled }
    }
    @AppStorage("earlyRampEnabled") var earlyRampEnabled: Bool = true {
        didSet { inputSettings.earlyRampEnabled = earlyRampEnabled }
    }
    @AppStorage("accelerationMode") var accelerationMode: AccelerationMode = .legacy {
        didSet { inputSettings.accelerationMode = accelerationMode }
    }
    @AppStorage("adaptiveSmoothingMode") var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speedAndJerk {
        didSet { inputSettings.adaptiveSmoothingMode = adaptiveSmoothingMode }
    }
    @AppStorage("autoNeutralRefresh") var autoNeutralRefresh: Bool = true {
        didSet { inputSettings.autoNeutralRefresh = autoNeutralRefresh }
    }
    // Primary override buttons (using legacy key "dragButtons" for migration)
    @AppStorage("dragButtons") private var primaryClutchButtonsRaw: String = "faceTop" {
        didSet { inputSettings.primaryClutchButtons = parseButtons(from: primaryClutchButtonsRaw) }
    }
    @AppStorage("scrollButtons") private var primaryScrollButtonsRaw: String = "faceBottom" {
        didSet { inputSettings.primaryScrollButtons = parseButtons(from: primaryScrollButtonsRaw) }
    }
    @AppStorage("zoomButtons") private var primaryZoomButtonsRaw: String = "" {
        didSet { inputSettings.primaryZoomButtons = parseButtons(from: primaryZoomButtonsRaw) }
    }
    // Secondary override buttons
    @AppStorage("secondaryClutchButtons") private var secondaryClutchButtonsRaw: String = "" {
        didSet { inputSettings.secondaryClutchButtons = parseButtons(from: secondaryClutchButtonsRaw) }
    }
    @AppStorage("secondaryScrollButtons") private var secondaryScrollButtonsRaw: String = "" {
        didSet { inputSettings.secondaryScrollButtons = parseButtons(from: secondaryScrollButtonsRaw) }
    }
    @AppStorage("secondaryZoomButtons") private var secondaryZoomButtonsRaw: String = "" {
        didSet { inputSettings.secondaryZoomButtons = parseButtons(from: secondaryZoomButtonsRaw) }
    }
    @AppStorage("idleTimeoutMinutes") var idleTimeoutMinutes: Double = 10.0 {
        didSet { inputSettings.idleTimeoutMinutes = idleTimeoutMinutes }
    }
    @AppStorage("autoPowerOffEnabled") var autoPowerOffEnabled: Bool = true {
        didSet { inputSettings.autoPowerOffEnabled = autoPowerOffEnabled }
    }
    @AppStorage("stickMode") var stickMode: StickMode = .scroll {
        didSet {
            inputSettings.stickMode = stickMode
            // Reset radial menu when mode changes
            radialMenuController?.reset()
        }
    }

    // MARK: - Radial Menu
    @Published var radialMenuState = RadialMenuState()
    @Published var radialMenuConfiguration: RadialMenuConfiguration {
        didSet {
            radialMenuConfiguration.save()
            radialMenuState.activeConfiguration = radialMenuConfiguration
        }
    }
    private(set) var radialMenuController: RadialMenuController?
    private var radialMenuWindowController: RadialMenuWindowController?

    // MARK: - Slot Assignments (new device-centric architecture)
    /// These track which device is assigned to each slot and what type it's configured as.
    /// Settings are stored per (slot, deviceType) combination in DeviceTypeSettings.
    @Published var primarySlotAssignment: SlotAssignment = SlotAssignment.load(slot: .primary)
    @Published var secondarySlotAssignment: SlotAssignment = SlotAssignment.load(slot: .secondary)

    // MARK: - Calibration State
    @Published var isGyroCalibrated: Bool = false
    @Published var debugIMUEnabled: Bool = false
    @Published var imuDtSamples: [Double] = []
    @Published var imuMotionSamples: [Double] = []
    @Published var imuGapFlags: [Bool] = []
    @Published var imuGapCount: Int = 0
    @Published var imuLastHz: Double = 0

    // MARK: - Accessibility Permission
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    /// Check if the app has Accessibility permission
    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    // MARK: - Button Mappings (persisted)
    @Published var primaryMapping: ButtonMappingProfile {
        didSet {
            inputSettings.primaryMapping = primaryMapping
            primaryMapping.save(to: "primaryButtonMapping")
        }
    }
    @Published var secondaryMapping: ButtonMappingProfile {
        didSet {
            inputSettings.secondaryMapping = secondaryMapping
            secondaryMapping.save(to: "secondaryButtonMapping")
        }
    }

    // MARK: - Controllers
    private var mouseController: MouseController?
    private(set) var inputProcessor: InputProcessor?

    /// Unified device manager (wraps Joy-Cons and air mice)
    @Published private(set) var deviceManager: DeviceManager?

    /// Available air mice (for UI), grouped by device
    var availableAirMice: [AvailableDevice] {
        deviceManager?.availableAirMice ?? []
    }

    /// Prevents recursive updates when keeping override button sets mutually exclusive
    private var overrideUpdateInProgress = false

    // Thread-safe settings cache for input callbacks
    private let inputSettings = InputSettings()

    private var cancellables = Set<AnyCancellable>()

    /// Timer for periodic accessibility permission checks
    private var accessibilityCheckTimer: Timer?
    /// Timer for controller idle power-off checks
    private var idleTimer: Timer?
    /// Last gyro timestamp for diagnostics
    private var lastGyroTimestamp: TimeInterval?
    private var imuDtSum: Double = 0
    private let imuWindowDuration: Double = 10.0
    /// Track override (drag/scroll/zoom) active state to suppress idle shutdowns mid-gesture
    private var overrideActive = false

    init() {
        // Load saved mappings or use defaults
        let loadedPrimary = ButtonMappingProfile.load(from: "primaryButtonMapping") ?? .defaultPrimary
        let loadedSecondary = ButtonMappingProfile.load(from: "secondaryButtonMapping") ?? .defaultSecondary
        _primaryMapping = Published(initialValue: loadedPrimary)
        _secondaryMapping = Published(initialValue: loadedSecondary)

        // Load radial menu configuration
        let loadedRadialConfig = RadialMenuConfiguration.load()
        _radialMenuConfiguration = Published(initialValue: loadedRadialConfig)
        radialMenuState.activeConfiguration = loadedRadialConfig

        // Initialize settings cache
        inputSettings.isEnabled = isEnabled
        inputSettings.gyroSensitivity = gyroSensitivity
        inputSettings.scrollSensitivity = scrollSensitivity
        inputSettings.gyroDeadzone = gyroDeadzone
        inputSettings.stickDeadzone = stickDeadzone
        inputSettings.smoothThreshold = smoothThreshold
        inputSettings.primaryMapping = loadedPrimary
        inputSettings.secondaryMapping = loadedSecondary
        inputSettings.primaryControllerId = nil  // Will be set when first controller connects
        inputSettings.mirrorFaceButtons = mirrorFaceButtons
        inputSettings.holdThreshold = holdThreshold
        inputSettings.filterBeta = filterBeta
        inputSettings.accelerationGain = accelerationGain
        inputSettings.precisionZoneEnabled = precisionZoneEnabled
        inputSettings.earlyRampEnabled = earlyRampEnabled
        inputSettings.accelerationMode = accelerationMode
        inputSettings.adaptiveSmoothingMode = adaptiveSmoothingMode
        inputSettings.autoNeutralRefresh = autoNeutralRefresh
        inputSettings.primaryClutchButtons = parseButtons(from: primaryClutchButtonsRaw)
        inputSettings.primaryScrollButtons = parseButtons(from: primaryScrollButtonsRaw)
        inputSettings.primaryZoomButtons = parseButtons(from: primaryZoomButtonsRaw)
        inputSettings.secondaryClutchButtons = parseButtons(from: secondaryClutchButtonsRaw)
        inputSettings.secondaryScrollButtons = parseButtons(from: secondaryScrollButtonsRaw)
        inputSettings.secondaryZoomButtons = parseButtons(from: secondaryZoomButtonsRaw)
        inputSettings.idleTimeoutMinutes = idleTimeoutMinutes
        inputSettings.autoPowerOffEnabled = autoPowerOffEnabled
        inputSettings.stickMode = stickMode

        // Check Accessibility permission on startup
        checkAccessibilityPermission()

        setupControllers()

        // Start periodic accessibility permission check
        startAccessibilityMonitoring()
        startIdleMonitoring()

        // Sync settings from new device-centric storage
        syncInputSettings()

        // Initialize diagnostic logger
        DiagnosticLogger.shared.log("AppState initialized")
    }

    deinit {
        accessibilityCheckTimer?.invalidate()
        idleTimer?.invalidate()
        // Note: deviceManager is MainActor-isolated; its deinit handles cleanup
    }

    /// Start periodic accessibility permission monitoring
    private func startAccessibilityMonitoring() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.hasAccessibilityPermission = AXIsProcessTrusted()
            }
        }
    }

    private func setupControllers() {
        mouseController = MouseController()
        inputProcessor = InputProcessor()

        let processor = inputProcessor
        let mouse = mouseController

        // Wire up mouse controller error handling
        mouseController?.onAccessibilityError = { [weak self] in
            Task { @MainActor in
                self?.hasAccessibilityPermission = AXIsProcessTrusted()
            }
        }

        // Wire up input processor to mouse controller (no main thread needed)
        processor?.onMouseMove = { dx, dy in
            mouse?.moveRelative(dx: dx, dy: dy)
        }

        processor?.onMouseClick = { button, isDown in
            if isDown {
                mouse?.mouseDown(button: button)
            } else {
                mouse?.mouseUp(button: button)
            }
        }

        processor?.onScroll = { dx, dy in
            mouse?.scroll(dx: dx, dy: dy)
        }

        processor?.onZoom = { magnification in
            mouse?.magnify(magnification)
        }

        processor?.onKeyDown = { keyCombo in
            mouse?.keyDown(keyCombo)
        }

        processor?.onKeyUp = { keyCombo in
            mouse?.keyUp(keyCombo)
        }

        processor?.onSystemAction = { action in
            mouse?.performSystemAction(action)
        }

        processor?.onCalibrationChange = { [weak self] isCalibrated in
            Task { @MainActor in
                if self?.isGyroCalibrated != isCalibrated {
                    self?.isGyroCalibrated = isCalibrated
                }
            }
        }

        // Set up radial menu
        setupRadialMenu()

        // Set up DeviceManager (single source of truth for all devices)
        setupDeviceManager()
    }

    // MARK: - Device Manager Setup (Air Mouse Support)

    private func setupDeviceManager() {
        deviceManager = DeviceManager()

        // Wire up air mouse motion events
        deviceManager?.onMotionUpdate = { [weak self] deviceId, motion, timestamp in
            guard let self = self else { return }
            let settings = self.inputSettings
            let processor = self.inputProcessor

            guard settings.isEnabled else { return }
            // Only process motion from primary device
            guard settings.primaryControllerId == deviceId else { return }

            switch motion {
            case .gyro(let gyroData):
                // Joy-Con gyro - already handled by JoyConController callbacks
                // This is a fallback if we fully migrate to DeviceManager later
                self.recordGyroDiagnostics(timestamp: timestamp, gyro: gyroData)
                processor?.processGyro(
                    gyroData,
                    timestamp: timestamp,
                    sensitivity: settings.gyroSensitivity,
                    deadzone: settings.gyroDeadzone,
                    smoothThreshold: settings.smoothThreshold,
                    filterBeta: settings.filterBeta,
                    accelerationMaxExtra: settings.accelerationGain,
                    accelerationMode: settings.accelerationMode,
                    precisionZoneEnabled: settings.precisionZoneEnabled,
                    earlyRampEnabled: settings.earlyRampEnabled,
                    adaptiveSmoothingMode: settings.adaptiveSmoothingMode,
                    autoNeutralRefresh: settings.autoNeutralRefresh
                )

            case .mouseDeltas(let dx, let dy):
                // Air mouse - use mouse delta processing
                // Sensitivity is scaled differently for direct deltas
                let airMouseSensitivity = settings.gyroSensitivity / 15.0
                processor?.processMouseDeltas(
                    dx: dx,
                    dy: dy,
                    timestamp: timestamp,
                    sensitivity: airMouseSensitivity
                )
            }
        }

        // Wire up button events (all devices - Joy-Cons and air mice)
        deviceManager?.onButtonPress = { [weak self] deviceId, deviceType, button in
            guard let self = self else { return }

            let snapshot = self.inputSettings.buttonPressSnapshot(for: deviceId)
            guard snapshot.isEnabled else { return }

            let processor = self.inputProcessor

            // Convert DeviceButton to LogicalButton
            guard let logicalButton = LogicalButton.from(
                button,
                deviceType: deviceType,
                mirrorFaceButtons: snapshot.mirrorFaceButtons
            ) else { return }

            // Check for radial menu confirmation
            if self.radialMenuController?.isActive == true {
                let actions = snapshot.mapping[logicalButton]
                if case .mouseClick(.left) = actions.press {
                    self.confirmRadialMenuSelection()
                    return
                }
            }

            // Handle override buttons (clutch/scroll/zoom)
            if snapshot.clutchButtons.contains(logicalButton) {
                processor?.beginOverride(.clutch)
                return
            }
            if snapshot.scrollButtons.contains(logicalButton) {
                processor?.beginOverride(.scroll)
                return
            }
            if snapshot.zoomButtons.contains(logicalButton) {
                processor?.beginOverride(.zoom)
                return
            }

            // Normal button handling
            let actions = snapshot.mapping[logicalButton]
            processor?.handleButtonDown(logicalButton, actions: actions, holdThreshold: snapshot.holdThreshold)
        }

        deviceManager?.onButtonRelease = { [weak self] deviceId, deviceType, button in
            guard let self = self else { return }

            let snapshot = self.inputSettings.buttonPressSnapshot(for: deviceId)
            guard snapshot.isEnabled else { return }

            let processor = self.inputProcessor

            guard let logicalButton = LogicalButton.from(
                button,
                deviceType: deviceType,
                mirrorFaceButtons: snapshot.mirrorFaceButtons
            ) else { return }

            // Handle override button releases
            if snapshot.clutchButtons.contains(logicalButton) {
                processor?.endOverride(.clutch)
                return
            }
            if snapshot.scrollButtons.contains(logicalButton) {
                processor?.endOverride(.scroll)
                return
            }
            if snapshot.zoomButtons.contains(logicalButton) {
                processor?.endOverride(.zoom)
                return
            }

            processor?.handleButtonUp(logicalButton)
        }

        // Wire up stick events (Joy-Cons only)
        deviceManager?.onStickUpdate = { [weak self] deviceId, position in
            guard let self = self else { return }
            let settings = self.inputSettings

            guard settings.isEnabled else { return }
            // Only process stick from primary device
            guard settings.primaryControllerId == deviceId else { return }

            switch settings.stickMode {
            case .scroll:
                let processor = self.inputProcessor
                processor?.processStick(position, sensitivity: settings.scrollSensitivity, deadzone: settings.stickDeadzone)
            case .radialMenu:
                let radialMenu = self.radialMenuController
                radialMenu?.processStick(x: position.x, y: position.y, deadzone: settings.stickDeadzone)
            }
        }

        // Connection changes - update connectedControllers and primary ID
        deviceManager?.onConnectionChange = { [weak self] devices in
            Task { @MainActor in
                guard let self = self else { return }

                // Update connectedControllers from DeviceManager's Joy-Con wrappers
                var controllers: [ConnectedController] = []
                for device in devices {
                    if let wrapper = device as? JoyConDeviceWrapper {
                        controllers.append(wrapper.connectedController)
                    }
                }
                self.connectedControllers = controllers

                // Update primary controller ID based on slot assignment
                self.inputSettings.primaryControllerId = self.primaryController?.id

                // Recheck Accessibility permission when devices connect
                self.checkAccessibilityPermission()
            }
        }

        // Battery updates
        deviceManager?.onBatteryUpdate = { [weak self] deviceId, level in
            Task { @MainActor in
                if let index = self?.connectedControllers.firstIndex(where: { $0.id == deviceId }) {
                    self?.connectedControllers[index].batteryLevel = level
                }
            }
        }

        // Activity tracking for idle timeout
        deviceManager?.onActivity = { [weak self] deviceId in
            // Mark activity for idle timeout tracking
            // (Activity from air mice counts the same as Joy-Con activity)
            _ = self  // Capture self but idle tracking uses Joy-Con's lastActivity
        }

        // Start scanning for air mice
        deviceManager?.startScanning()
    }

    // MARK: - Device-Centric Settings Sync

    /// Sync settings from the new per-(slot, deviceType) storage to InputSettings.
    /// Call this when slot assignments change or after settings are saved.
    func syncInputSettings() {
        // Load primary slot settings
        let primarySettings = DeviceTypeSettings.load(slot: .primary, deviceType: primarySlotAssignment.deviceType)
        inputSettings.gyroSensitivity = primarySettings.pointerSensitivity
        inputSettings.accelerationGain = primarySettings.accelerationGain
        inputSettings.smoothThreshold = primarySettings.smoothThreshold
        inputSettings.filterBeta = primarySettings.filterBeta
        inputSettings.adaptiveSmoothingMode = primarySettings.adaptiveSmoothingMode
        inputSettings.precisionZoneEnabled = primarySettings.precisionZoneEnabled
        inputSettings.earlyRampEnabled = primarySettings.earlyRampEnabled
        inputSettings.gyroDeadzone = primarySettings.gyroDeadzone
        inputSettings.stickMode = primarySettings.stickMode
        inputSettings.scrollSensitivity = primarySettings.scrollSensitivity
        inputSettings.stickDeadzone = primarySettings.stickDeadzone
        inputSettings.primaryMapping = primarySettings.buttonMappings
        inputSettings.primaryClutchButtons = primarySettings.clutchButtons
        inputSettings.primaryScrollButtons = primarySettings.scrollButtons
        inputSettings.primaryZoomButtons = primarySettings.zoomButtons
        inputSettings.holdThreshold = primarySettings.holdThreshold
        inputSettings.mirrorFaceButtons = primarySettings.mirrorFaceButtons

        // Update primary controller ID based on slot assignment
        inputSettings.primaryControllerId = primarySlotAssignment.deviceId

        // Load secondary slot settings (only button-related, secondary doesn't control pointer)
        let secondarySettings = DeviceTypeSettings.load(slot: .secondary, deviceType: secondarySlotAssignment.deviceType)
        inputSettings.secondaryMapping = secondarySettings.buttonMappings
        inputSettings.secondaryClutchButtons = secondarySettings.clutchButtons
        inputSettings.secondaryScrollButtons = secondarySettings.scrollButtons
        inputSettings.secondaryZoomButtons = secondarySettings.zoomButtons

        // Update radial menu configuration from primary settings
        radialMenuConfiguration = RadialMenuConfiguration(name: "Primary", items: primarySettings.radialMenuItems)
    }

    /// Update slot assignment and sync settings
    func updateSlotAssignment(_ assignment: SlotAssignment, for slot: DeviceSlot) {
        switch slot {
        case .primary:
            primarySlotAssignment = assignment
        case .secondary:
            secondarySlotAssignment = assignment
        }
        assignment.save(slot: slot)
        syncInputSettings()

        // Reset calibration when primary device changes
        if slot == .primary {
            resetGyroCalibration()
        }
    }

    // MARK: - Override Button Management (Clutch/Scroll/Zoom)

    private func parseButtons(from raw: String) -> Set<LogicalButton> {
        let parts = raw.split(separator: ",").map { String($0) }
        return Set(parts.compactMap { LogicalButton(rawValue: $0) })
    }

    private func storeButtons(_ buttons: Set<LogicalButton>) -> String {
        buttons.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    // MARK: Primary Override Buttons

    var primaryClutchButtons: Set<LogicalButton> {
        get { parseButtons(from: primaryClutchButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                primaryClutchButtonsRaw = storeButtons(newValue)
                inputSettings.primaryClutchButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            primaryClutchButtonsRaw = storeButtons(newValue)
            inputSettings.primaryClutchButtons = newValue
            newValue.forEach { button in
                primaryMapping[button] = ButtonActions()
            }
            // Remove from other primary modes
            primaryScrollButtons = primaryScrollButtons.subtracting(newValue)
            primaryZoomButtons = primaryZoomButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    var primaryScrollButtons: Set<LogicalButton> {
        get { parseButtons(from: primaryScrollButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                primaryScrollButtonsRaw = storeButtons(newValue)
                inputSettings.primaryScrollButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            primaryScrollButtonsRaw = storeButtons(newValue)
            inputSettings.primaryScrollButtons = newValue
            newValue.forEach { button in
                primaryMapping[button] = ButtonActions()
            }
            primaryClutchButtons = primaryClutchButtons.subtracting(newValue)
            primaryZoomButtons = primaryZoomButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    var primaryZoomButtons: Set<LogicalButton> {
        get { parseButtons(from: primaryZoomButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                primaryZoomButtonsRaw = storeButtons(newValue)
                inputSettings.primaryZoomButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            primaryZoomButtonsRaw = storeButtons(newValue)
            inputSettings.primaryZoomButtons = newValue
            newValue.forEach { button in
                primaryMapping[button] = ButtonActions()
            }
            primaryClutchButtons = primaryClutchButtons.subtracting(newValue)
            primaryScrollButtons = primaryScrollButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    // MARK: Secondary Override Buttons

    var secondaryClutchButtons: Set<LogicalButton> {
        get { parseButtons(from: secondaryClutchButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                secondaryClutchButtonsRaw = storeButtons(newValue)
                inputSettings.secondaryClutchButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            secondaryClutchButtonsRaw = storeButtons(newValue)
            inputSettings.secondaryClutchButtons = newValue
            newValue.forEach { button in
                secondaryMapping[button] = ButtonActions()
            }
            // Remove from other secondary modes
            secondaryScrollButtons = secondaryScrollButtons.subtracting(newValue)
            secondaryZoomButtons = secondaryZoomButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    var secondaryScrollButtons: Set<LogicalButton> {
        get { parseButtons(from: secondaryScrollButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                secondaryScrollButtonsRaw = storeButtons(newValue)
                inputSettings.secondaryScrollButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            secondaryScrollButtonsRaw = storeButtons(newValue)
            inputSettings.secondaryScrollButtons = newValue
            newValue.forEach { button in
                secondaryMapping[button] = ButtonActions()
            }
            secondaryClutchButtons = secondaryClutchButtons.subtracting(newValue)
            secondaryZoomButtons = secondaryZoomButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    var secondaryZoomButtons: Set<LogicalButton> {
        get { parseButtons(from: secondaryZoomButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                secondaryZoomButtonsRaw = storeButtons(newValue)
                inputSettings.secondaryZoomButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            secondaryZoomButtonsRaw = storeButtons(newValue)
            inputSettings.secondaryZoomButtons = newValue
            newValue.forEach { button in
                secondaryMapping[button] = ButtonActions()
            }
            secondaryClutchButtons = secondaryClutchButtons.subtracting(newValue)
            secondaryScrollButtons = secondaryScrollButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    func openAccessibilitySettings() {
        // Try to trigger the system Accessibility permission prompt
        // Note: This only works for truly first-time requests; otherwise user must add manually
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        hasAccessibilityPermission = trusted

        if !trusted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Reset gyro calibration - controller will recalibrate when held still
    func resetGyroCalibration() {
        inputProcessor?.resetFilters()
        isGyroCalibrated = false
    }

    // MARK: - Radial Menu Setup

    private func setupRadialMenu() {
        radialMenuController = RadialMenuController()
        radialMenuWindowController = RadialMenuWindowController(state: radialMenuState)

        let state = radialMenuState
        let windowController = radialMenuWindowController

        radialMenuController?.onShowMenu = { [weak state, weak windowController] position in
            Task { @MainActor in
                state?.show(at: position)
                windowController?.show(at: position)
            }
        }

        radialMenuController?.onHideMenu = { [weak state, weak windowController] in
            Task { @MainActor in
                state?.hide()
                windowController?.hide()
            }
        }

        radialMenuController?.onJoystickUpdate = { [weak state] angle, magnitude in
            Task { @MainActor in
                state?.updateJoystick(angle: angle, magnitude: magnitude)
            }
        }
    }

    private func confirmRadialMenuSelection() {
        Task { @MainActor in
            let item = radialMenuState.highlightedItem()

            // Hide menu immediately before executing action
            // This prevents the menu from lingering during screen transitions
            radialMenuState.hide()
            radialMenuWindowController?.hide()
            radialMenuController?.reset()

            // Execute the action after hiding
            guard let item = item else { return }

            switch item.action {
            case .none:
                break
            case .keyPress(let combo):
                mouseController?.keyDown(combo)
                mouseController?.keyUp(combo)
            case .mouseClick(let button):
                mouseController?.mouseDown(button: button)
                mouseController?.mouseUp(button: button)
            case .systemAction(let action):
                mouseController?.performSystemAction(action)
            }
        }
    }

    /// Capture gyro timing diagnostics for UI debugging
    func recordGyroDiagnostics(timestamp: TimeInterval, gyro: GyroData) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.lastGyroTimestamp = timestamp }
            guard self.debugIMUEnabled else {
                self.imuDtSamples.removeAll()
                self.imuMotionSamples.removeAll()
                self.imuGapFlags.removeAll()
                self.imuGapCount = 0
                self.imuDtSum = 0
                return
            }
            guard let last = self.lastGyroTimestamp else { return }
            let dt = timestamp - last
            guard dt > 0 else { return }

            // Maintain ~imuWindowDuration seconds of dt samples
            self.imuDtSamples.append(dt)
            let mag = sqrt(gyro.x * gyro.x + gyro.y * gyro.y + gyro.z * gyro.z)
            self.imuMotionSamples.append(mag)
            self.imuDtSum += dt
            let isGap = dt > 0.020
            self.imuGapFlags.append(isGap)
            if isGap { self.imuGapCount += 1 }
            self.imuLastHz = 1.0 / dt
            while self.imuDtSum > self.imuWindowDuration, let first = self.imuDtSamples.first {
                self.imuDtSum -= first
                if let firstGap = self.imuGapFlags.first, firstGap {
                    self.imuGapCount = max(0, self.imuGapCount - 1)
                }
                self.imuDtSamples.removeFirst()
                if !self.imuMotionSamples.isEmpty { self.imuMotionSamples.removeFirst() }
                if !self.imuGapFlags.isEmpty { self.imuGapFlags.removeFirst() }
            }
        }
    }

    // MARK: - Idle Power-Off

    private func startIdleMonitoring() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleControllers()
            }
        }
    }

    private func checkIdleControllers() {
        guard autoPowerOffEnabled else { return }
        let timeoutSeconds = idleTimeoutMinutes * 60.0
        let now = CACurrentMediaTime()
        let idleControllers = connectedControllers.filter {
            now - $0.lastActivity >= timeoutSeconds
        }

        idleControllers.forEach { controller in
            // Only power off if we still have a matching controller instance
            controller.controller.setHCIState(state: .disconnect)
        }
    }

    /// Set a controller type as the primary controller
    func setPrimaryControllerType(_ type: ControllerType) {
        switch type {
        case .leftJoyCon:
            preferredPrimaryType = "left"
        case .rightJoyCon, .proController:
            preferredPrimaryType = "right"
        case .none:
            preferredPrimaryType = ""
        }
        // Update inputSettings with current primary's ID
        inputSettings.primaryControllerId = primaryController?.id
        // Reset gyro calibration when switching primary
        resetGyroCalibration()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Supporting Types

enum ControllerType: String, Sendable {
    case none = "None"
    case rightJoyCon = "Joy-Con (R)"
    case leftJoyCon = "Joy-Con (L)"
    case proController = "Pro Controller"
}

enum BatteryLevel: String {
    case unknown = "Unknown"
    case empty = "Empty"
    case critical = "Critical"
    case low = "Low"
    case medium = "Medium"
    case full = "Full"
}
