import SwiftUI
import Combine
import os.lock
import ApplicationServices  // For AXIsProcessTrusted

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
    private var _clutchButtons: Set<LogicalButton> = []
    private var _scrollButtons: Set<LogicalButton> = []
    private var _zoomButtons: Set<LogicalButton> = []

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

    var clutchButtons: Set<LogicalButton> {
        get { lock.withLock { _clutchButtons } }
        set { lock.withLock { _clutchButtons = newValue } }
    }

    var scrollButtons: Set<LogicalButton> {
        get { lock.withLock { _scrollButtons } }
        set { lock.withLock { _scrollButtons = newValue } }
    }

    var zoomButtons: Set<LogicalButton> {
        get { lock.withLock { _zoomButtons } }
        set { lock.withLock { _zoomButtons = newValue } }
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
    @AppStorage("gyroSensitivity") var gyroSensitivity: Double = 30.0 {
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
    @AppStorage("smoothThreshold") var smoothThreshold: Double = 20.0 {
        didSet { inputSettings.smoothThreshold = smoothThreshold }
    }
    @AppStorage("mirrorFaceButtons") var mirrorFaceButtons: Bool = true {
        didSet { inputSettings.mirrorFaceButtons = mirrorFaceButtons }
    }
    @AppStorage("holdThreshold") var holdThreshold: Double = 0.6 {
        didSet { inputSettings.holdThreshold = holdThreshold }
    }
    @AppStorage("filterBeta") var filterBeta: Double = 0.5 {
        didSet { inputSettings.filterBeta = filterBeta }
    }
    @AppStorage("accelerationGain") var accelerationGain: Double = 80.0 {
        didSet { inputSettings.accelerationGain = accelerationGain }
    }
    @AppStorage("dragButtons") private var clutchButtonsRaw: String = "" {
        didSet { inputSettings.clutchButtons = parseButtons(from: clutchButtonsRaw) }
    }
    @AppStorage("scrollButtons") private var scrollButtonsRaw: String = "" {
        didSet { inputSettings.scrollButtons = parseButtons(from: scrollButtonsRaw) }
    }
    @AppStorage("zoomButtons") private var zoomButtonsRaw: String = "" {
        didSet { inputSettings.zoomButtons = parseButtons(from: zoomButtonsRaw) }
    }

    // MARK: - Calibration State
    @Published var isGyroCalibrated: Bool = false

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
    private var joyConController: JoyConController?
    private var mouseController: MouseController?
    private(set) var inputProcessor: InputProcessor?

    /// Prevents recursive updates when keeping override button sets mutually exclusive
    private var overrideUpdateInProgress = false

    // Thread-safe settings cache for input callbacks
    private let inputSettings = InputSettings()

    private var cancellables = Set<AnyCancellable>()

    /// Timer for periodic accessibility permission checks
    private var accessibilityCheckTimer: Timer?

    init() {
        // Load saved mappings or use defaults
        let loadedPrimary = ButtonMappingProfile.load(from: "primaryButtonMapping") ?? .defaultPrimary
        let loadedSecondary = ButtonMappingProfile.load(from: "secondaryButtonMapping") ?? .defaultSecondary
        _primaryMapping = Published(initialValue: loadedPrimary)
        _secondaryMapping = Published(initialValue: loadedSecondary)

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
        inputSettings.clutchButtons = parseButtons(from: clutchButtonsRaw)
        inputSettings.scrollButtons = parseButtons(from: scrollButtonsRaw)
        inputSettings.zoomButtons = parseButtons(from: zoomButtonsRaw)

        // Check Accessibility permission on startup
        checkAccessibilityPermission()

        setupControllers()

        // Start periodic accessibility permission check
        startAccessibilityMonitoring()
    }

    deinit {
        accessibilityCheckTimer?.invalidate()
        joyConController?.stopScanning()
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
        joyConController = JoyConController()

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

        processor?.onKeyDown = { keyCombo in
            mouse?.keyDown(keyCombo)
        }

        processor?.onKeyUp = { keyCombo in
            mouse?.keyUp(keyCombo)
        }

        // Wire up Joy-Con events - NO main thread dispatch for input processing
        // Gyro: only process from primary controller
        joyConController?.onGyroUpdate = { [weak self] controllerId, gyro, timestamp in
            guard let self = self else { return }
            let settings = self.inputSettings
            let processor = self.inputProcessor

            guard settings.isEnabled else { return }

            // Only process gyro from primary controller
            guard settings.primaryControllerId == controllerId else { return }

            processor?.processGyro(
                gyro,
                timestamp: timestamp,
                sensitivity: settings.gyroSensitivity,
                deadzone: settings.gyroDeadzone,
                smoothThreshold: settings.smoothThreshold,
                filterBeta: settings.filterBeta,
                accelerationMaxExtra: settings.accelerationGain
            )
        }
        processor?.onCalibrationChange = { [weak self] isCalibrated in
            Task { @MainActor in
                if self?.isGyroCalibrated != isCalibrated {
                    self?.isGyroCalibrated = isCalibrated
                }
            }
        }

        // Buttons: use primary or secondary mapping based on controller
        joyConController?.onButtonPress = { [weak self] controllerId, controllerType, button in
            guard let self = self else { return }
            let settings = self.inputSettings
            let processor = self.inputProcessor
            guard settings.isEnabled else { return }
            let isPrimary = settings.primaryControllerId == controllerId
            let mapping = isPrimary ? settings.primaryMapping : settings.secondaryMapping

            // Get logical button for hold detection
            guard let logicalButton = LogicalButton.from(button, controllerType: controllerType, mirrorFaceButtons: settings.mirrorFaceButtons) else { return }
            if settings.clutchButtons.contains(logicalButton) {
                processor?.beginOverride(.clutch)
                return
            }
            if settings.scrollButtons.contains(logicalButton) {
                processor?.beginOverride(.scroll)
                return
            }
            if settings.zoomButtons.contains(logicalButton) {
                processor?.beginOverride(.zoom)
                return
            }
            let actions = mapping[logicalButton]

            processor?.handleButtonDown(logicalButton, actions: actions, holdThreshold: settings.holdThreshold)
        }

        joyConController?.onButtonRelease = { [weak self] controllerId, controllerType, button in
            guard let self = self else { return }
            let settings = self.inputSettings
            let processor = self.inputProcessor

            guard settings.isEnabled else { return }

            // Get logical button for hold detection
            guard let logicalButton = LogicalButton.from(button, controllerType: controllerType, mirrorFaceButtons: settings.mirrorFaceButtons) else { return }
            if settings.clutchButtons.contains(logicalButton) {
                processor?.endOverride(.clutch)
                return
            }
            if settings.scrollButtons.contains(logicalButton) {
                processor?.endOverride(.scroll)
                return
            }
            if settings.zoomButtons.contains(logicalButton) {
                processor?.endOverride(.zoom)
                return
            }

            processor?.handleButtonUp(logicalButton)
        }

        // Stick: only process from primary controller
        joyConController?.onStickUpdate = { [weak self] controllerId, position in
            guard let self = self else { return }
            let settings = self.inputSettings
            let processor = self.inputProcessor

            guard settings.isEnabled else { return }
            // Only process stick from primary controller
            guard settings.primaryControllerId == controllerId else { return }
            processor?.processStick(position, sensitivity: settings.scrollSensitivity, deadzone: settings.stickDeadzone)
        }

        // Connection state updates still need main thread (for UI)
        joyConController?.onConnectionChange = { [weak self] controllers in
            Task { @MainActor in
                self?.connectedControllers = controllers
                // Update primary controller ID based on type preference
                self?.inputSettings.primaryControllerId = self?.primaryController?.id
                // Recheck Accessibility permission when controllers connect
                self?.checkAccessibilityPermission()
            }
        }

        joyConController?.onBatteryUpdate = { [weak self] controllerId, level in
            Task { @MainActor in
                if let index = self?.connectedControllers.firstIndex(where: { $0.id == controllerId }) {
                    self?.connectedControllers[index].batteryLevel = level
                }
            }
        }

        // Start scanning for controllers
        joyConController?.startScanning()
    }

    // MARK: - Override Button Management (Clutch/Scroll/Zoom)

    private func parseButtons(from raw: String) -> Set<LogicalButton> {
        let parts = raw.split(separator: ",").map { String($0) }
        return Set(parts.compactMap { LogicalButton(rawValue: $0) })
    }

    private func storeButtons(_ buttons: Set<LogicalButton>) -> String {
        buttons.map { $0.rawValue }.sorted().joined(separator: ",")
    }

    var clutchButtons: Set<LogicalButton> {
        get { parseButtons(from: clutchButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                clutchButtonsRaw = storeButtons(newValue)
                inputSettings.clutchButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            clutchButtonsRaw = storeButtons(newValue)
            inputSettings.clutchButtons = newValue
            newValue.forEach { button in
                primaryMapping[button] = ButtonActions()
                secondaryMapping[button] = ButtonActions()
            }
            // Remove from other modes
            scrollButtons = scrollButtons.subtracting(newValue)
            zoomButtons = zoomButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    var scrollButtons: Set<LogicalButton> {
        get { parseButtons(from: scrollButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                scrollButtonsRaw = storeButtons(newValue)
                inputSettings.scrollButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            scrollButtonsRaw = storeButtons(newValue)
            inputSettings.scrollButtons = newValue
            newValue.forEach { button in
                primaryMapping[button] = ButtonActions()
                secondaryMapping[button] = ButtonActions()
            }
            clutchButtons = clutchButtons.subtracting(newValue)
            zoomButtons = zoomButtons.subtracting(newValue)
            overrideUpdateInProgress = false
        }
    }

    var zoomButtons: Set<LogicalButton> {
        get { parseButtons(from: zoomButtonsRaw) }
        set {
            if overrideUpdateInProgress {
                zoomButtonsRaw = storeButtons(newValue)
                inputSettings.zoomButtons = newValue
                return
            }
            overrideUpdateInProgress = true
            zoomButtonsRaw = storeButtons(newValue)
            inputSettings.zoomButtons = newValue
            newValue.forEach { button in
                primaryMapping[button] = ButtonActions()
                secondaryMapping[button] = ButtonActions()
            }
            clutchButtons = clutchButtons.subtracting(newValue)
            scrollButtons = scrollButtons.subtracting(newValue)
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
