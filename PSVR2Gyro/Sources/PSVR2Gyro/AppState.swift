import Foundation
import SwiftUI
import ApplicationServices  // For AXIsProcessTrusted

/// Central app state for PSVR2Gyro
@MainActor
class AppState: ObservableObject {

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var controllerName: String = "Not connected"
    @Published var isEnabled: Bool = true
    @Published var statusMessage: String = "Waiting for controller..."

    // MARK: - Accessibility Permission
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    // Debug display
    @Published var lastGyroX: Int16 = 0
    @Published var lastGyroY: Int16 = 0
    @Published var lastGyroZ: Int16 = 0
    @Published var lastAccelX: Int16 = 0
    @Published var lastAccelY: Int16 = 0
    @Published var lastAccelZ: Int16 = 0
    @Published var reportCount: Int = 0
    @Published var debugLog: [String] = []

    // Available controllers
    @Published var availableControllers: [DiscoveredController] = []
    @Published var selectedControllerID: String?
    @Published var isLeftController: Bool = false

    // Button states (logical buttons, mirrored between L/R)
    @Published var buttonStates: [LogicalButton: Bool] = [:]

    // Button mapping
    @Published var buttonMappingProfile: PSVR2ButtonMappingProfile = .load() {
        didSet { buttonMappingProfile.save() }
    }
    @Published var triggerThreshold: UInt8 = 128 {
        didSet {
            buttonMappingProfile.triggerThreshold = triggerThreshold
            buttonMappingProfile.save()
        }
    }
    @Published var holdThreshold: Double = 0.3 {
        didSet {
            buttonMappingProfile.holdThreshold = holdThreshold
            buttonMappingProfile.save()
        }
    }

    // Previous button states for edge detection (non-UI, used for action execution)
    private var previousButtonStates: [LogicalButton: Bool] = [:]
    private var previousTriggerPressed: Bool = false

    // Hold detection state
    private struct ButtonPressState {
        let pressTime: Date
        let actions: ButtonActions
        var holdFired: Bool = false
    }
    private var buttonPressStates: [LogicalButton: ButtonPressState] = [:]
    private var holdTimers: [LogicalButton: DispatchWorkItem] = [:]
    private let holdQueue = DispatchQueue(label: "PSVR2Gyro.holdQueue", qos: .userInitiated)

    // Gyro override mode tracking
    private var dragButtonHeld: Bool = false
    private var scrollButtonHeld: Bool = false

    /// Current gyro processing mode based on button states and mappings
    enum GyroMode {
        case none      // No cursor movement (drag mapped but not held)
        case normal    // Normal cursor movement
        case drag      // Drag button held - move cursor
        case scroll    // Scroll button held - scroll instead of move
    }

    var currentGyroMode: GyroMode {
        // Scroll takes priority if held
        if scrollButtonHeld { return .scroll }
        // Drag mode active if held
        if dragButtonHeld { return .drag }
        // If drag is mapped but not held, don't move cursor
        if buttonMappingProfile.hasDragMapping { return .none }
        // Default: normal cursor movement
        return .normal
    }

    // Raw report data (full 78 bytes)
    @Published var reportBytes: [UInt8] = Array(repeating: 0, count: 78)

    /// Safe accessor for report bytes - returns 0 if index out of bounds
    func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }
    @Published var reportLength: Int = 0
    @Published var byteLastChanged: [Date] = Array(repeating: Date.distantPast, count: 78)

    // Bit-level tracking for button discovery (78 bytes * 8 bits)
    @Published var bitLastChanged: [[Date]] = Array(repeating: Array(repeating: Date.distantPast, count: 8), count: 78)

    // Throttling for UI updates
    private var lastUIUpdate: Date = .distantPast
    private let uiUpdateInterval: TimeInterval = 1.0 / 30.0  // 30 FPS for UI
    private var pendingReportBytes: [UInt8] = Array(repeating: 0, count: 78)
    private var pendingByteChanges: [Int: Date] = [:]
    private var pendingBitChanges: [(byte: Int, bit: Int, date: Date)] = []

    // MARK: - Settings

    @Published var sensitivity: Double = 15.0 {
        didSet { gyroProcessor.sensitivity = sensitivity }
    }

    @Published var gyroScale: Double = 1.0 / 16.0 {
        didSet { gyroProcessor.gyroScale = gyroScale }
    }

    // Gyro axis offsets (for tuning)
    @Published var gyroOffsetX: Int = 17 {
        didSet { controller.gyroOffsetX = gyroOffsetX }
    }
    @Published var gyroOffsetY: Int = 19 {
        didSet { controller.gyroOffsetY = gyroOffsetY }
    }
    @Published var gyroOffsetZ: Int = 21 {
        didSet { controller.gyroOffsetZ = gyroOffsetZ }
    }

    // MARK: - Controllers

    let controller = PSVR2Controller()
    let gyroProcessor = GyroProcessor()
    let mouseController = MouseController()

    // MARK: - Initialization

    init() {
        // Load trigger threshold from saved profile
        triggerThreshold = buttonMappingProfile.triggerThreshold
        setupCallbacks()
        controller.start()
    }

    private func setupCallbacks() {
        controller.onDebugMessage = { [weak self] message in
            Task { @MainActor in
                self?.debugLog.append(message)
                if (self?.debugLog.count ?? 0) > 10 {
                    self?.debugLog.removeFirst()
                }
                self?.statusMessage = message
            }
        }

        controller.onConnectionChange = { [weak self] connected, name in
            Task { @MainActor in
                self?.isConnected = connected
                self?.controllerName = name ?? "Unknown"
                self?.selectedControllerID = self?.controller.selectedControllerID
                self?.statusMessage = connected ? "Connected: \(name ?? "Controller")" : "Disconnected"
                self?.reportCount = 0
            }
        }

        controller.onControllersChanged = { [weak self] in
            Task { @MainActor in
                self?.availableControllers = self?.controller.discoveredControllers ?? []
                self?.selectedControllerID = self?.controller.selectedControllerID

                // Update isLeftController based on selected controller
                if let selectedID = self?.selectedControllerID,
                   let selected = self?.availableControllers.first(where: { $0.id == selectedID }) {
                    self?.isLeftController = selected.isLeft
                }
            }
        }

        controller.onGyroData = { [weak self] x, y, z, timestamp in
            guard let self = self else { return }

            // Process gyro immediately (low latency for mouse control)
            if self.isEnabled {
                if let (dx, dy) = self.gyroProcessor.process(rawX: x, rawY: y, rawZ: z, timestamp: timestamp) {
                    // Route based on current gyro mode
                    switch self.currentGyroMode {
                    case .none:
                        // Don't move cursor (drag mapped but not held)
                        break
                    case .normal, .drag:
                        // Move cursor normally
                        self.mouseController.moveRelative(dx: dx, dy: dy)
                    case .scroll:
                        // Convert gyro movement to scroll
                        self.mouseController.scroll(dx: dx, dy: dy)
                    }
                }
            }

            // Throttle debug display updates (piggyback on report throttle)
            let now = Date()
            guard now.timeIntervalSince(self.lastUIUpdate) >= self.uiUpdateInterval else { return }

            Task { @MainActor in
                self.lastGyroX = x
                self.lastGyroY = y
                self.lastGyroZ = z
                self.reportCount += 1
            }
        }

        // IMU callback for sensor fusion (gyro + accel combined)
        controller.onIMUData = { [weak self] gyroX, gyroY, gyroZ, accelX, accelY, accelZ, timestamp in
            guard let self = self else { return }

            // Update accel values for debug display (throttled with gyro)
            let now = Date()
            guard now.timeIntervalSince(self.lastUIUpdate) >= self.uiUpdateInterval else { return }

            Task { @MainActor in
                self.lastAccelX = accelX
                self.lastAccelY = accelY
                self.lastAccelZ = accelZ
            }
        }

        controller.onReportData = { [weak self] bytes, length in
            guard let self = self else { return }

            let now = Date()
            let isLeft = self.isLeftController
            let mapping = PSVR2ButtonMapping(isLeft: isLeft)

            // Process button actions immediately (low latency)
            self.processButtonActions(bytes: bytes, mapping: mapping)

            // Track changes (lightweight, no UI update)
            for i in 0..<min(bytes.count, self.pendingReportBytes.count) {
                if bytes[i] != self.pendingReportBytes[i] {
                    self.pendingByteChanges[i] = now

                    // Track individual bit changes
                    let oldByte = self.pendingReportBytes[i]
                    let newByte = bytes[i]
                    let changedBits = oldByte ^ newByte
                    for bit in 0..<8 {
                        if (changedBits >> bit) & 1 == 1 {
                            self.pendingBitChanges.append((i, bit, now))
                        }
                    }
                }
            }
            self.pendingReportBytes = bytes

            // Throttle UI updates to 30 FPS
            guard now.timeIntervalSince(self.lastUIUpdate) >= self.uiUpdateInterval else { return }
            self.lastUIUpdate = now

            // Batch update UI on main thread
            let byteChanges = self.pendingByteChanges
            let bitChanges = self.pendingBitChanges
            let reportBytes = bytes

            self.pendingByteChanges.removeAll(keepingCapacity: true)
            self.pendingBitChanges.removeAll(keepingCapacity: true)

            Task { @MainActor in
                // Apply pending byte changes
                for (index, date) in byteChanges {
                    self.byteLastChanged[index] = date
                }

                // Apply pending bit changes
                for (byteIndex, bit, date) in bitChanges {
                    self.bitLastChanged[byteIndex][bit] = date
                }

                self.reportBytes = reportBytes
                self.reportLength = length

                // Update button states using mapping
                for button in LogicalButton.allCases {
                    self.buttonStates[button] = mapping.isPressed(button, in: reportBytes)
                }
            }
        }
    }

    // MARK: - Actions

    func selectController(id: String) {
        controller.selectController(id: id)
    }

    func recalibrate() {
        gyroProcessor.reset()
        statusMessage = "Calibrating... keep still"

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if gyroProcessor.isCalibrated {
                    statusMessage = "Calibrated!"
                } else {
                    statusMessage = "Keep still to calibrate"
                }
            }
        }
    }

    /// Check if the app has Accessibility permission
    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    /// Open Accessibility settings and prompt for permission
    func openAccessibilitySettings() {
        // Try to trigger the system Accessibility permission prompt
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        hasAccessibilityPermission = trusted

        // Also open System Settings to the Accessibility pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // Start polling for permission changes
        startAccessibilityPolling()
    }

    private var accessibilityTimer: Timer?

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

    // MARK: - Button Action Processing

    /// Process button actions on HID thread (low latency)
    /// Called from onReportData callback - NOT on main thread
    private func processButtonActions(bytes: [UInt8], mapping: PSVR2ButtonMapping) {
        // Process all digital buttons
        for button in LogicalButton.allCases {
            // Skip trigger - handled separately with threshold
            if button == .trigger { continue }

            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = previousButtonStates[button] ?? false

            if isPressed != wasPressed {
                let actions = buttonMappingProfile.actions(for: button)
                if isPressed {
                    handleButtonDown(button: button, actions: actions)
                } else {
                    handleButtonUp(button: button)
                }
            }

            previousButtonStates[button] = isPressed
        }

        // Handle trigger with threshold (analog -> digital conversion)
        let triggerValue = mapping.triggerValue(in: bytes)
        let triggerPressed = triggerValue >= triggerThreshold

        if triggerPressed != previousTriggerPressed {
            let actions = buttonMappingProfile.actions(for: .trigger)
            if triggerPressed {
                handleButtonDown(button: .trigger, actions: actions)
            } else {
                handleButtonUp(button: .trigger)
            }
        }

        previousTriggerPressed = triggerPressed
    }

    /// Handle button press - start hold timer if needed
    private func handleButtonDown(button: LogicalButton, actions: ButtonActions) {
        // Handle gyro mode actions immediately (drag/scroll are inherently hold-based)
        if actions.pressIsGyroMode {
            switch actions.press {
            case .drag:
                dragButtonHeld = true
            case .scroll:
                scrollButtonHeld = true
            default:
                break
            }
            return
        }

        // Record press state
        buttonPressStates[button] = ButtonPressState(pressTime: Date(), actions: actions)

        // If there's a hold action, schedule a timer
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Check if button is still pressed
                guard var state = self.buttonPressStates[button], !state.holdFired else { return }

                // Fire hold action
                state.holdFired = true
                self.buttonPressStates[button] = state

                // Execute hold action (down)
                ActionExecutor.shared.execute(actions.hold, isPressed: true)
            }
            holdTimers[button]?.cancel()
            holdTimers[button] = timer
            holdQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    /// Handle button release - fire press action or release hold action
    private func handleButtonUp(button: LogicalButton) {
        // Cancel any pending hold timer
        holdTimers[button]?.cancel()
        holdTimers[button] = nil

        // Check if this was a gyro mode button
        if let state = buttonPressStates[button], state.actions.pressIsGyroMode {
            switch state.actions.press {
            case .drag:
                dragButtonHeld = false
            case .scroll:
                scrollButtonHeld = false
            default:
                break
            }
            buttonPressStates[button] = nil
            return
        }

        // Also check current mapping for gyro modes (in case state wasn't recorded)
        let actions = buttonMappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            switch actions.press {
            case .drag:
                dragButtonHeld = false
            case .scroll:
                scrollButtonHeld = false
            default:
                break
            }
            return
        }

        guard let state = buttonPressStates[button] else { return }

        if state.holdFired {
            // Hold action was executed, release it
            ActionExecutor.shared.execute(state.actions.hold, isPressed: false)
        } else {
            // Hold didn't fire, execute press action as tap (down + up)
            if state.actions.press != .none {
                ActionExecutor.shared.execute(state.actions.press, isPressed: true)
                ActionExecutor.shared.execute(state.actions.press, isPressed: false)
            }
        }

        buttonPressStates[button] = nil
    }
}
