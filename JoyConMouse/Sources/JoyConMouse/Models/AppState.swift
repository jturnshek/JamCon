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
}

/// Shared application state
@MainActor
class AppState: ObservableObject {
    // MARK: - Connection State
    @Published var isConnected: Bool = false
    @Published var controllerType: ControllerType = .none {
        didSet { inputSettings.controllerType = controllerType }
    }
    @Published var batteryLevel: BatteryLevel = .unknown

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

    // MARK: - Controllers
    private var joyConController: JoyConController?
    private var mouseController: MouseController?
    private(set) var inputProcessor: InputProcessor?

    // Thread-safe settings cache for input callbacks
    private let inputSettings = InputSettings()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Initialize settings cache
        inputSettings.isEnabled = isEnabled
        inputSettings.gyroSensitivity = gyroSensitivity
        inputSettings.scrollSensitivity = scrollSensitivity
        inputSettings.gyroDeadzone = gyroDeadzone
        inputSettings.stickDeadzone = stickDeadzone
        inputSettings.smoothThreshold = smoothThreshold

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

        // Wire up Joy-Con events - NO main thread dispatch for input processing
        joyConController?.onGyroUpdate = { [weak self, settings, processor] gyro in
            guard settings.isEnabled else { return }
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

        joyConController?.onButtonPress = { [settings, processor] button in
            guard settings.isEnabled else { return }
            processor?.processButtonPress(button, controllerType: settings.controllerType)
        }

        joyConController?.onButtonRelease = { [settings, processor] button in
            guard settings.isEnabled else { return }
            processor?.processButtonRelease(button, controllerType: settings.controllerType)
        }

        joyConController?.onStickUpdate = { [settings, processor] position in
            guard settings.isEnabled else { return }
            processor?.processStick(position, sensitivity: settings.scrollSensitivity, deadzone: settings.stickDeadzone)
        }

        // Connection state updates still need main thread (for UI)
        joyConController?.onConnectionChange = { [weak self] connected, type in
            Task { @MainActor in
                self?.isConnected = connected
                self?.controllerType = type
            }
        }

        joyConController?.onBatteryUpdate = { [weak self] level in
            Task { @MainActor in
                self?.batteryLevel = level
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
