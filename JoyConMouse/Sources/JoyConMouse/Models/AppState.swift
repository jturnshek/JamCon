import SwiftUI
import Combine
import os.lock

/// Thread-safe settings cache for input processing
/// Avoids main thread dispatch for high-frequency gyro updates
final class InputSettings: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()

    private var _isEnabled: Bool = true
    private var _gyroSensitivity: Double = 5.0
    private var _scrollSensitivity: Double = 10.0
    private var _gyroDeadzone: Double = 1.0
    private var _stickDeadzone: Double = 0.15
    private var _smoothThreshold: Double = 20.0
    private var _controllerType: ControllerType = .none
    private var _primaryMapping: ButtonMappingProfile = .defaultPrimary
    private var _secondaryMapping: ButtonMappingProfile = .defaultSecondary
    private var _primaryControllerId: UUID? = nil

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
}

/// Shared application state
@MainActor
class AppState: ObservableObject {
    // MARK: - Connection State
    @Published var connectedControllers: [ConnectedController] = []
    @Published var preferredPrimaryId: UUID? = nil {
        didSet { inputSettings.primaryControllerId = preferredPrimaryId ?? primaryController?.id }
    }

    /// The primary controller (controls mouse + uses primary mapping)
    var primaryController: ConnectedController? {
        // If user has a preference and that controller is connected, use it
        if let preferredId = preferredPrimaryId,
           let controller = connectedControllers.first(where: { $0.id == preferredId }) {
            return controller
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
    @AppStorage("gyroSensitivity") var gyroSensitivity: Double = 5.0 {
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

    // MARK: - Calibration State
    @Published var isGyroCalibrated: Bool = false

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

    // Thread-safe settings cache for input callbacks
    private let inputSettings = InputSettings()

    private var cancellables = Set<AnyCancellable>()

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

        setupControllers()
    }

    private func setupControllers() {
        mouseController = MouseController()
        inputProcessor = InputProcessor()
        joyConController = JoyConController()

        let settings = inputSettings
        let processor = inputProcessor
        let mouse = mouseController

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
        joyConController?.onGyroUpdate = { [weak self, settings, processor] controllerId, gyro in
            guard settings.isEnabled else { return }
            // Only process gyro from primary controller
            guard settings.primaryControllerId == controllerId else { return }

            processor?.processGyro(
                gyro,
                sensitivity: settings.gyroSensitivity,
                deadzone: settings.gyroDeadzone,
                smoothThreshold: settings.smoothThreshold
            )

            // Update calibration status on main thread (infrequently)
            if let processor = processor {
                let isCalibrated = processor.biasEstimator.isCalibrated
                Task { @MainActor in
                    if self?.isGyroCalibrated != isCalibrated {
                        self?.isGyroCalibrated = isCalibrated
                    }
                }
            }
        }

        // Buttons: use primary or secondary mapping based on controller
        joyConController?.onButtonPress = { [settings, processor] controllerId, button in
            guard settings.isEnabled else { return }
            let isPrimary = settings.primaryControllerId == controllerId
            let mapping = isPrimary ? settings.primaryMapping : settings.secondaryMapping
            processor?.processButtonPress(button, mapping: mapping)
        }

        joyConController?.onButtonRelease = { [settings, processor] controllerId, button in
            guard settings.isEnabled else { return }
            let isPrimary = settings.primaryControllerId == controllerId
            let mapping = isPrimary ? settings.primaryMapping : settings.secondaryMapping
            processor?.processButtonRelease(button, mapping: mapping)
        }

        // Stick: only process from primary controller
        joyConController?.onStickUpdate = { [settings, processor] controllerId, position in
            guard settings.isEnabled else { return }
            // Only process stick from primary controller
            guard settings.primaryControllerId == controllerId else { return }
            processor?.processStick(position, sensitivity: settings.scrollSensitivity, deadzone: settings.stickDeadzone)
        }

        // Connection state updates still need main thread (for UI)
        joyConController?.onConnectionChange = { [weak self, settings] controllers in
            Task { @MainActor in
                self?.connectedControllers = controllers

                // Auto-set primary if not set or if preferred is disconnected
                if settings.primaryControllerId == nil ||
                   !controllers.contains(where: { $0.id == settings.primaryControllerId }) {
                    settings.primaryControllerId = controllers.first?.id
                }
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

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reset gyro calibration - controller will recalibrate when held still
    func resetGyroCalibration() {
        inputProcessor?.biasEstimator.reset()
        inputProcessor?.smoother.reset()
        isGyroCalibrated = false
    }

    /// Set a controller as the primary controller
    func setPrimaryController(_ controller: ConnectedController) {
        preferredPrimaryId = controller.id
        inputSettings.primaryControllerId = controller.id
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
