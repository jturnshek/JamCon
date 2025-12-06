import Foundation
import SwiftUI
import ApplicationServices  // For AXIsProcessTrusted
import os  // For OSAllocatedUnfairLock

/// Central app state for PSVR2Gyro
@MainActor
class AppState: ObservableObject {

    // MARK: - UserDefaults Keys

    private static let lastSelectedControllerKey = "lastSelectedControllerID"

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var controllerName: String = "Not connected"
    @Published var isEnabled: Bool = true {
        didSet { updateCachedIsEnabled() }
    }
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

    // Available controllers (UI-safe - no IOHIDDevice references)
    @Published var availableControllers: [ControllerInfo] = []
    @Published var selectedControllerID: String?
    @Published var isLeftController: Bool = false {
        didSet { updateCachedIsLeftController() }
    }

    // Battery level (updated from HID reports)
    @Published var batteryLevel: Int = 0

    // Button states (logical buttons, mirrored between L/R) - NOT @Published
    // Array-backed for hot path; dictionary view is derived for UI consumers if needed
    private var buttonStatesArray: [Bool] = Array(repeating: false, count: LogicalButton.allCases.count)
    var buttonStates: [LogicalButton: Bool] {
        var dict: [LogicalButton: Bool] = [:]
        for button in LogicalButton.allCases {
            dict[button] = buttonStatesArray[button.index]
        }
        return dict
    }

    // Button mapping
    @Published var buttonMappingProfile: PSVR2ButtonMappingProfile = .load() {
        didSet { buttonMappingProfile.save() }
    }
    @Published var triggerThreshold: UInt8 = 128 {
        didSet {
            buttonMappingProfile.triggerThreshold = triggerThreshold
            buttonMappingProfile.save()
            updateCachedTriggerThreshold()
        }
    }
    @Published var holdThreshold: Double = 0.3 {
        didSet {
            buttonMappingProfile.holdThreshold = holdThreshold
            buttonMappingProfile.save()
        }
    }

    // Joystick scroll settings
    @Published var joystickScrollEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(joystickScrollEnabled, forKey: "joystick.scrollEnabled")
            updateCachedJoystickScrollEnabled()
        }
    }
    @Published var joystickScrollSpeed: Double = 5.0 {
        didSet {
            UserDefaults.standard.set(joystickScrollSpeed, forKey: "joystick.scrollSpeed")
            updateCachedJoystickScrollSpeed()
        }
    }
    @Published var joystickScrollAcceleration: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(joystickScrollAcceleration, forKey: "joystick.scrollAcceleration")
            updateCachedJoystickScrollAcceleration()
        }
    }

    // Previous button states for edge detection (non-UI, used for action execution)
    private var previousButtonStates: [Bool] = Array(repeating: false, count: LogicalButton.allCases.count)
    private var previousTriggerPressed: Bool = false

    // Hold detection state
    private struct ButtonPressState {
        let pressTime: Date
        let actions: ButtonActions
        var holdFired: Bool = false
    }
    private var buttonPressStates: [ButtonPressState?] = Array(repeating: nil, count: LogicalButton.allCases.count)
    private var holdTimers: [DispatchWorkItem?] = Array(repeating: nil, count: LogicalButton.allCases.count)
    private let holdQueue = DispatchQueue(label: "PSVR2Gyro.holdQueue", qos: .userInitiated)

    // Gyro override mode tracking
    private var dragButtonHeld: Bool = false
    private var scrollButtonHeld: Bool = false
    private var radialMenuButtonHeld: Bool = false
    private var pendingRadialDelta: (dx: CGFloat, dy: CGFloat)?
    private var radialUpdateScheduled: Bool = false

    // MARK: - Radial Menu

    /// Radial menu state (UI-facing, observable)
    let radialMenuState = RadialMenuState()

    /// Radial menu window controller (lazy initialization)
    private var radialMenuWindowController: RadialMenuWindowController?

    /// Radial menu configuration with persistence
    @Published var radialMenuConfiguration: RadialMenuConfiguration = .load() {
        didSet { radialMenuConfiguration.save() }
    }

    /// Current gyro processing mode based on button states and mappings
    enum GyroMode {
        case none       // No cursor movement (drag mapped but not held)
        case normal     // Normal cursor movement
        case drag       // Drag button held - move cursor
        case scroll     // Scroll button held - scroll instead of move
        case radialMenu // Radial menu button held - route to menu selection
    }

    var currentGyroMode: GyroMode {
        // Radial menu takes highest priority
        if radialMenuButtonHeld { return .radialMenu }
        // Scroll takes priority if held
        if scrollButtonHeld { return .scroll }
        // Drag mode active if held
        if dragButtonHeld { return .drag }
        // If drag is mapped but not held, don't move cursor
        if buttonMappingProfile.hasDragMapping { return .none }
        // Default: normal cursor movement
        return .normal
    }

    // Raw report data (full report) - NOT @Published to avoid SwiftUI observation thrashing
    var reportBytes: [UInt8] = Array(repeating: 0, count: PSVR2HIDProtocol.reportLength)

    /// Safe accessor for report bytes - returns 0 if index out of bounds
    func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }
    var reportLength: Int = 0
    var byteLastChanged: [Date] = Array(repeating: Date.distantPast, count: PSVR2HIDProtocol.reportLength)

    // Bit-level tracking for button discovery (reportLength bytes * 8 bits) - NOT @Published
    var bitLastChanged: [[Date]] = Array(repeating: Array(repeating: Date.distantPast, count: 8), count: PSVR2HIDProtocol.reportLength)

    // Manual refresh trigger for views that need high-frequency updates (e.g., Debug tab)
    @Published var debugRefreshTrigger: Int = 0

    // Which tab is currently active (to avoid unnecessary UI updates)
    enum ActiveTab: String { case controller, mouse, buttons, joystick, radial, debug, log }
    @Published var activeTab: ActiveTab = .controller {
        didSet {
            // Auto-disable debug rendering when leaving the Debug tab
            if activeTab != .debug {
                debugRenderingEnabled = false
            }
        }
    }

    // Toggle for real-time rendering in Debug tab (opt-in to avoid performance issues)
    @Published var debugRenderingEnabled: Bool = false

    // Throttling for UI updates
    private var lastUIUpdate: Date = .distantPast
    private let uiUpdateInterval: TimeInterval = 1.0 / 30.0  // 30 FPS for UI
    private var pendingReportBytes: [UInt8] = Array(repeating: 0, count: PSVR2HIDProtocol.reportLength)
    private var pendingByteChanges: [Int: Date] = [:]
    private var pendingBitChanges: [(byte: Int, bit: Int, date: Date)] = Array(
        repeating: (0, 0, .distantPast),
        count: PSVR2HIDProtocol.reportLength * 8
    )
    private var pendingBitCount: Int = 0

    // Thread-safe cached values for HID callback access (avoid data races with @Published properties)
    private let callbackLock = OSAllocatedUnfairLock()
    private var _cachedIsLeftController: Bool = false
    private var _cachedIsEnabled: Bool = true
    private var _cachedTriggerThreshold: UInt8 = 128
    private var _cachedJoystickScrollEnabled: Bool = false
    private var _cachedJoystickScrollSpeed: Double = 5.0
    private var _cachedJoystickScrollAcceleration: Double = 1.0
    private var _isPaused: Bool = false
    private var _cachedGyroSettings: GyroSettingsState = .default

    private struct CallbackSnapshot {
        let isPaused: Bool
        let isLeftController: Bool
        let isEnabled: Bool
        let triggerThreshold: UInt8
        let joystickScrollEnabled: Bool
        let joystickScrollSpeed: Double
        let joystickScrollAcceleration: Double
        let gyroSettings: GyroSettingsState
    }

    /// Thread-safe pause flag - when true, all HID callbacks return early
    /// Used during tab switches to prevent state updates while SwiftUI transitions
    var isPaused: Bool {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _isPaused }
        set { callbackLock.lock(); _isPaused = newValue; callbackLock.unlock() }
    }

    /// Thread-safe accessor for isLeftController (for use in HID callbacks)
    private var cachedIsLeftController: Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _cachedIsLeftController
    }

    /// Thread-safe accessor for isEnabled (for use in HID callbacks)
    private var cachedIsEnabled: Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _cachedIsEnabled
    }

    /// Thread-safe accessor for triggerThreshold (for use in HID callbacks)
    private var cachedTriggerThreshold: UInt8 {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _cachedTriggerThreshold
    }

    /// Thread-safe accessor for joystickScrollEnabled (for use in HID callbacks)
    private var cachedJoystickScrollEnabled: Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _cachedJoystickScrollEnabled
    }

    /// Thread-safe accessor for joystickScrollSpeed (for use in HID callbacks)
    private var cachedJoystickScrollSpeed: Double {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _cachedJoystickScrollSpeed
    }

    /// Thread-safe accessor for joystickScrollAcceleration (for use in HID callbacks)
    private var cachedJoystickScrollAcceleration: Double {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _cachedJoystickScrollAcceleration
    }

    /// Update individual cached values (avoids reading back properties in didSet)
    private func updateCachedIsLeftController() {
        callbackLock.lock()
        _cachedIsLeftController = isLeftController
        callbackLock.unlock()
    }

    private func updateCachedIsEnabled() {
        callbackLock.lock()
        _cachedIsEnabled = isEnabled
        callbackLock.unlock()
    }

    private func updateCachedTriggerThreshold() {
        callbackLock.lock()
        _cachedTriggerThreshold = triggerThreshold
        callbackLock.unlock()
    }

    private func updateCachedJoystickScrollEnabled() {
        callbackLock.lock()
        _cachedJoystickScrollEnabled = joystickScrollEnabled
        callbackLock.unlock()
    }

    private func updateCachedJoystickScrollSpeed() {
        callbackLock.lock()
        _cachedJoystickScrollSpeed = joystickScrollSpeed
        callbackLock.unlock()
    }

    private func updateCachedJoystickScrollAcceleration() {
        callbackLock.lock()
        _cachedJoystickScrollAcceleration = joystickScrollAcceleration
        callbackLock.unlock()
    }

    private func readCallbackSnapshot() -> CallbackSnapshot {
        callbackLock.lock()
        let snapshot = CallbackSnapshot(
            isPaused: _isPaused,
            isLeftController: _cachedIsLeftController,
            isEnabled: _cachedIsEnabled,
            triggerThreshold: _cachedTriggerThreshold,
            joystickScrollEnabled: _cachedJoystickScrollEnabled,
            joystickScrollSpeed: _cachedJoystickScrollSpeed,
            joystickScrollAcceleration: _cachedJoystickScrollAcceleration,
            gyroSettings: _cachedGyroSettings
        )
        callbackLock.unlock()
        return snapshot
    }

    /// Update all cached values (call during init)
    private func updateAllCachedValues() {
        callbackLock.lock()
        _cachedIsLeftController = isLeftController
        _cachedIsEnabled = isEnabled
        _cachedTriggerThreshold = triggerThreshold
        _cachedJoystickScrollEnabled = joystickScrollEnabled
        _cachedJoystickScrollSpeed = joystickScrollSpeed
        _cachedJoystickScrollAcceleration = joystickScrollAcceleration
        _cachedGyroSettings = gyroSettings.read()
        callbackLock.unlock()
    }

    // Cached mappings to avoid per-report allocation
    private let leftMapping = PSVR2ButtonMapping(isLeft: true)
    private let rightMapping = PSVR2ButtonMapping(isLeft: false)

    // MARK: - Gyro Settings (Thread-Safe)

    /// Thread-safe settings container for HID callback access
    let gyroSettings = GyroSettings.load()

    // Published properties that sync with GyroSettings for UI binding
    @Published var sensitivity: Double = 50.0 {
        didSet { gyroSettings.update { $0.sensitivity = sensitivity }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var gyroScale: Double = 1.0 / 16.0 {
        didSet { gyroSettings.update { $0.gyroScale = gyroScale }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var filterEnabled: Bool = true {
        didSet { gyroSettings.update { $0.filterEnabled = filterEnabled }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var minCutoff: Double = 0.5 {
        didSet { gyroSettings.update { $0.minCutoff = minCutoff }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var beta: Double = 1.0 {
        didSet { gyroSettings.update { $0.beta = beta }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speed {
        didSet { gyroSettings.update { $0.adaptiveSmoothingMode = adaptiveSmoothingMode }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var accelerationMode: AccelerationMode = .simple {
        didSet { gyroSettings.update { $0.accelerationMode = accelerationMode }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var simpleAcceleration: Double = 5.0 {
        didSet { gyroSettings.update { $0.simpleAcceleration = simpleAcceleration }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var accelerationCurve: AccelerationCurve = .power {
        didSet { gyroSettings.update { $0.accelerationCurve = accelerationCurve }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var accelerationStrength: Double = 10.0 {
        didSet { gyroSettings.update { $0.accelerationStrength = accelerationStrength }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var sensitivityCap: Double = 20.0 {
        didSet { gyroSettings.update { $0.sensitivityCap = sensitivityCap }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var curveExponent: Double = 1.0 {
        didSet { gyroSettings.update { $0.curveExponent = curveExponent }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var rampSpeed: Double = 150.0 {
        didSet { gyroSettings.update { $0.rampSpeed = rampSpeed }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var softCutoffThreshold: Double = 0.5 {
        didSet { gyroSettings.update { $0.softCutoffThreshold = softCutoffThreshold }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    @Published var recoveryThreshold: Double = 1.5 {
        didSet { gyroSettings.update { $0.recoveryThreshold = recoveryThreshold }; gyroSettings.save(); refreshGyroSettingsCache() }
    }

    // Gyro axis offsets (for tuning)
    @Published var gyroOffsetX: Int = PSVR2HIDProtocol.Offset.gyroXLow {
        didSet { controller.gyroOffsetX = gyroOffsetX }
    }
    @Published var gyroOffsetY: Int = PSVR2HIDProtocol.Offset.gyroYLow {
        didSet { controller.gyroOffsetY = gyroOffsetY }
    }
    @Published var gyroOffsetZ: Int = PSVR2HIDProtocol.Offset.gyroZLow {
        didSet { controller.gyroOffsetZ = gyroOffsetZ }
    }

    /// Reset all gyro settings to defaults
    func resetGyroSettings() {
        gyroSettings.resetToDefaults()
        refreshGyroSettingsCache()
        loadGyroSettingsToPublished()
    }

    /// Load settings from GyroSettings into published properties
    private func loadGyroSettingsToPublished() {
        let state = gyroSettings.read()
        sensitivity = state.sensitivity
        gyroScale = state.gyroScale
        filterEnabled = state.filterEnabled
        minCutoff = state.minCutoff
        beta = state.beta
        adaptiveSmoothingMode = state.adaptiveSmoothingMode
        accelerationMode = state.accelerationMode
        simpleAcceleration = state.simpleAcceleration
        accelerationCurve = state.accelerationCurve
        accelerationStrength = state.accelerationStrength
        sensitivityCap = state.sensitivityCap
        curveExponent = state.curveExponent
        rampSpeed = state.rampSpeed
        softCutoffThreshold = state.softCutoffThreshold
        recoveryThreshold = state.recoveryThreshold
        refreshGyroSettingsCache()
    }

    // MARK: - Controllers

    let controller = PSVR2Controller()
    let gyroProcessor = GyroProcessor()
    let mouseController = MouseController()
    private(set) lazy var actionExecutor = ActionExecutor(mouseController: mouseController)

    // MARK: - Initialization

    init() {
        // Load trigger threshold from saved profile
        triggerThreshold = buttonMappingProfile.triggerThreshold

        // Load joystick settings from UserDefaults
        joystickScrollEnabled = UserDefaults.standard.bool(forKey: "joystick.scrollEnabled")
        let savedSpeed = UserDefaults.standard.double(forKey: "joystick.scrollSpeed")
        joystickScrollSpeed = savedSpeed > 0 ? savedSpeed : 5.0
        let savedAccel = UserDefaults.standard.double(forKey: "joystick.scrollAcceleration")
        joystickScrollAcceleration = savedAccel > 0 ? savedAccel : 1.0

        updateAllCachedValues()
        // Load gyro settings into published properties (without triggering saves)
        loadGyroSettingsToPublishedSilent()
        setupCallbacks()

        // Load last selected controller preference before starting HID scanning
        if let savedID = UserDefaults.standard.string(forKey: Self.lastSelectedControllerKey) {
            controller.preferredControllerID = savedID
        }

        controller.start()
    }

    /// Load settings without triggering didSet saves (for init only)
    private func loadGyroSettingsToPublishedSilent() {
        let state = gyroSettings.read()
        // Use direct assignment to backing storage if possible, or accept the save overhead
        // For now, we accept re-saves during init as they're idempotent
        _sensitivity = Published(initialValue: state.sensitivity)
        _gyroScale = Published(initialValue: state.gyroScale)
        _filterEnabled = Published(initialValue: state.filterEnabled)
        _minCutoff = Published(initialValue: state.minCutoff)
        _beta = Published(initialValue: state.beta)
        _adaptiveSmoothingMode = Published(initialValue: state.adaptiveSmoothingMode)
        _accelerationCurve = Published(initialValue: state.accelerationCurve)
        _accelerationStrength = Published(initialValue: state.accelerationStrength)
        _sensitivityCap = Published(initialValue: state.sensitivityCap)
        _curveExponent = Published(initialValue: state.curveExponent)
        _rampSpeed = Published(initialValue: state.rampSpeed)
        _softCutoffThreshold = Published(initialValue: state.softCutoffThreshold)
        _recoveryThreshold = Published(initialValue: state.recoveryThreshold)
        refreshGyroSettingsCache()
    }

    private func refreshGyroSettingsCache() {
        callbackLock.lock()
        _cachedGyroSettings = gyroSettings.read()
        callbackLock.unlock()
    }

    private func setupCallbacks() {
        setupDebugCallback()
        setupConnectionCallbacks()
        setupGyroCallback()
        setupIMUCallback()
        setupReportCallback()
    }

    private func setupDebugCallback() {
        controller.onDebugMessage = { [weak self] message in
            Task { @MainActor in
                self?.debugLog.append(message)
                if (self?.debugLog.count ?? 0) > 10 {
                    self?.debugLog.removeFirst()
                }
                self?.statusMessage = message
            }
        }
    }

    private func setupConnectionCallbacks() {
        controller.onConnectionChange = { [weak self] connected, name, controllerID in
            Task { @MainActor in
                self?.isConnected = connected
                self?.controllerName = name ?? "Unknown"
                self?.selectedControllerID = controllerID
                self?.statusMessage = connected ? "Connected: \(name ?? "Controller")" : "Disconnected"
                self?.reportCount = 0

                // Update isLeftController based on selected controller
                // (didSet will update cached value automatically)
                if connected,
                   let selectedID = controllerID,
                   let selected = self?.availableControllers.first(where: { $0.id == selectedID }) {
                    self?.isLeftController = selected.isLeft
                }
            }
        }

        controller.onControllersChanged = { [weak self] in
            // Capture UI-safe controller info before dispatching to main thread
            let controllerInfos = self?.controller.discoveredControllers.map { $0.info } ?? []
            let selectedID = self?.controller.selectedControllerID

            Task { @MainActor in
                self?.availableControllers = controllerInfos
                self?.selectedControllerID = selectedID

                // Update isLeftController based on selected controller
                // (didSet will update cached value automatically)
                if let selectedID = selectedID,
                   let selected = controllerInfos.first(where: { $0.id == selectedID }) {
                    self?.isLeftController = selected.isLeft
                }
            }
        }
    }

    private func setupGyroCallback() {
        // Gyro is now handled in the report callback to ensure button/mode state is fresh
    }

    private func setupIMUCallback() {
        controller.onIMUData = { [weak self] gyroX, gyroY, gyroZ, accelX, accelY, accelZ, timestamp in
            guard let self = self, !self.isPaused else { return }

            // Update accel values for debug display (throttled with gyro)
            let now = Date()
            guard now.timeIntervalSince(self.lastUIUpdate) >= self.uiUpdateInterval else { return }

            Task { @MainActor in
                self.lastAccelX = accelX
                self.lastAccelY = accelY
                self.lastAccelZ = accelZ
            }
        }
    }

    private func setupReportCallback() {
        controller.onReportData = { [weak self] report in
            guard let self = self else { return }

            let snapshot = self.readCallbackSnapshot()
            guard !snapshot.isPaused else { return }

            let debugActive = self.debugRenderingEnabled && self.activeTab == .debug
            let now = Date()  // Always use real time for throttle check (battery needs updates)

            // Use cached mappings to avoid per-report allocation
            let mapping = snapshot.isLeftController ? self.leftMapping : self.rightMapping
            let byteAt: (Int) -> UInt8 = { idx in
                (idx >= 0 && idx < report.length) ? report.bytes[idx] : 0
            }

            // Process button actions immediately (low latency) so mode is current for gyro
            self.processButtonActions(bytes: report.bytes, mapping: mapping, triggerThreshold: snapshot.triggerThreshold)

            // Process joystick for scrolling (on HID thread for low latency)
            if snapshot.joystickScrollEnabled {
                let joystickPos = mapping.joystickPosition(in: report.bytes)
                let deadzone: Double = 20.0
                let center: Double = 128.0
                let maxDelta: Double = 127.0

                let deltaX = Double(joystickPos.x) - center
                let deltaY = Double(joystickPos.y) - center

                if abs(deltaX) > deadzone || abs(deltaY) > deadzone {
                    let speed = snapshot.joystickScrollSpeed

                    // Lightweight quadratic scaling to avoid pow on hot path
                    func scaled(_ delta: Double) -> CGFloat {
                        let sign = delta >= 0 ? 1.0 : -1.0
                        let normalized = min(1.0, abs(delta) / maxDelta)
                        let curved = normalized * normalized  // simple accel
                        return CGFloat(sign * curved * speed * 2.0)
                    }

                    let scrollX = scaled(deltaX)
                    let scrollY = scaled(deltaY)
                    self.mouseController.scroll(dx: scrollX, dy: scrollY)
                }
            }

            // Process gyro now that button/mode state is current
            // Always process for live speed visualization, even if mouse movement is disabled
            let settings = snapshot.gyroSettings
            let gyroResult = self.gyroProcessor.process(
                rawX: report.gyroX,
                rawY: report.gyroY,
                rawZ: report.gyroZ,
                timestamp: report.timestamp,
                settings: settings
            )

            if snapshot.isEnabled, let (dx, dy) = gyroResult {
                switch self.currentGyroMode {
                case .none:
                    break
                case .normal, .drag:
                    self.mouseController.moveRelative(dx: dx, dy: dy)
                case .scroll:
                    self.mouseController.scroll(dx: dx, dy: dy)
                case .radialMenu:
                    // Coalesce radial menu updates to avoid per-report Task spam
                    pendingRadialDelta = (dx, dy)
                    if !radialUpdateScheduled {
                        radialUpdateScheduled = true
                        Task { @MainActor in
                            if let delta = self.pendingRadialDelta {
                                self.radialMenuState.updateFromDelta(dx: delta.dx, dy: delta.dy)
                            }
                            self.pendingRadialDelta = nil
                            self.radialUpdateScheduled = false
                        }
                    }
                }
            }

            // Track changes only when debug rendering is active
            if debugActive {
                pendingBitCount = 0
                let maxIndex = min(report.length, self.pendingReportBytes.count)
                for i in 0..<maxIndex {
                    if report.bytes[i] != self.pendingReportBytes[i] {
                        self.pendingByteChanges[i] = now

                        // Track individual bit changes
                        let oldByte = self.pendingReportBytes[i]
                        let newByte = report.bytes[i]
                        let changedBits = oldByte ^ newByte
                        for bit in 0..<8 {
                            if (changedBits >> bit) & 1 == 1 {
                                if pendingBitCount < self.pendingBitChanges.count {
                                    self.pendingBitChanges[pendingBitCount] = (i, bit, now)
                                    pendingBitCount += 1
                                }
                            }
                        }
                    }
                }
                for i in 0..<maxIndex {
                    self.pendingReportBytes[i] = report.bytes[i]
                }
            }

            // Throttle UI updates to 30 FPS
            guard now.timeIntervalSince(self.lastUIUpdate) >= self.uiUpdateInterval else { return }
            self.lastUIUpdate = now

            // Batch update UI on main thread
            let byteChanges = self.pendingByteChanges
            let bitChangesCount = self.pendingBitCount
            let reportBytes = report.bytes
            let reportLength = report.length

            if debugActive {
                self.pendingByteChanges.removeAll(keepingCapacity: true)
                self.pendingBitCount = 0

                // Update non-published properties directly (no SwiftUI observation overhead)
                for (index, date) in byteChanges { self.byteLastChanged[index] = date }
                for idx in 0..<bitChangesCount {
                    let (byteIndex, bit, date) = self.pendingBitChanges[idx]
                    if byteIndex < self.bitLastChanged.count && bit < self.bitLastChanged[byteIndex].count {
                        self.bitLastChanged[byteIndex][bit] = date
                    }
                }
                self.reportBytes = self.pendingReportBytes
                self.reportLength = reportLength
            }

            for button in LogicalButton.allCases {
                self.buttonStatesArray[button.index] = mapping.isPressed(button, in: reportBytes)
            }

            // Update debug-facing gyro/accel state, battery, and counters
            // Only read battery if report contains the battery byte (offset 43)
            let newBatteryLevel: Int? = report.length > PSVR2HIDProtocol.Offset.battery
                ? BatteryHelper.level(from: byteAt(PSVR2HIDProtocol.Offset.battery))
                : nil
            Task { @MainActor in
                self.lastGyroX = report.gyroX
                self.lastGyroY = report.gyroY
                self.lastGyroZ = report.gyroZ
                self.reportCount += 1
                if let newBatteryLevel, self.batteryLevel != newBatteryLevel {
                    self.batteryLevel = newBatteryLevel
                }
                if debugActive {
                    self.debugRefreshTrigger += 1
                }
            }
        }
    }

    // MARK: - Actions

    func selectController(id: String) {
        UserDefaults.standard.set(id, forKey: Self.lastSelectedControllerKey)
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
    private func processButtonActions(bytes: [UInt8], mapping: PSVR2ButtonMapping, triggerThreshold: UInt8) {
        // Process all digital buttons
        for button in LogicalButton.allCases {
            // Skip trigger - handled separately with threshold
            if button == .trigger { continue }

            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = previousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = buttonMappingProfile.actions(for: button)
                if isPressed {
                    handleButtonDown(button: button, actions: actions)
                } else {
                    handleButtonUp(button: button)
                }
            }

            previousButtonStates[idx] = isPressed
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
        let idx = button.index

        // Handle gyro mode actions immediately (drag/scroll/radialMenu are inherently hold-based)
        if actions.pressIsGyroMode {
            switch actions.press {
            case .drag:
                dragButtonHeld = true
            case .scroll:
                scrollButtonHeld = true
            case .radialMenu:
                radialMenuButtonHeld = true
                showRadialMenu()
            default:
                break
            }
            return
        }

        // Handle mouse clicks immediately (need mouseDown on press, mouseUp on release for proper drag)
        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true)
            // Record state so we know to send mouseUp on release
            buttonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)
            return
        }

        // Record press state
            buttonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)

        // If there's a hold action, schedule a timer
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Check if button is still pressed
                guard var state = self.buttonPressStates[idx], !state.holdFired else { return }

                // Fire hold action
                state.holdFired = true
                self.buttonPressStates[idx] = state

                // Execute hold action (down)
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            holdTimers[idx]?.cancel()
            holdTimers[idx] = timer
            holdQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    /// Handle button release - fire press action or release hold action
    private func handleButtonUp(button: LogicalButton) {
        let idx = button.index

        // Cancel any pending hold timer
        holdTimers[idx]?.cancel()
        holdTimers[idx] = nil

        // Check if this was a gyro mode button
        if let state = buttonPressStates[idx], state.actions.pressIsGyroMode {
            switch state.actions.press {
            case .drag:
                dragButtonHeld = false
            case .scroll:
                scrollButtonHeld = false
            case .radialMenu:
                radialMenuButtonHeld = false
                hideRadialMenuAndExecute()
            default:
                break
            }
            buttonPressStates[idx] = nil
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
            case .radialMenu:
                radialMenuButtonHeld = false
                hideRadialMenuAndExecute()
            default:
                break
            }
            return
        }

        guard let state = buttonPressStates[idx] else { return }

        // Handle mouse click releases - mouseDown was sent on press, now send mouseUp
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false)
            buttonPressStates[idx] = nil
            return
        }

        if state.holdFired {
            // Hold action was executed, release it
            actionExecutor.execute(state.actions.hold, isPressed: false)
        } else {
            // Hold didn't fire, execute press action as tap (down + up)
            if state.actions.press != .none {
                actionExecutor.execute(state.actions.press, isPressed: true)
                actionExecutor.execute(state.actions.press, isPressed: false)
            }
        }

        buttonPressStates[idx] = nil
    }

    // MARK: - Radial Menu Control

    /// Show the radial menu at current cursor position
    private func showRadialMenu() {
        Task { @MainActor in
            // Initialize window controller if needed
            if radialMenuWindowController == nil {
                radialMenuWindowController = RadialMenuWindowController(state: radialMenuState)
            }

            // Get current mouse position
            let mousePosition = NSEvent.mouseLocation

            // Show menu with current configuration
            radialMenuState.show(at: mousePosition, configuration: radialMenuConfiguration)
            radialMenuWindowController?.show(at: mousePosition)

            // Hide system cursor
            mouseController.hideCursor()
        }
    }

    /// Hide radial menu and execute selected action
    private func hideRadialMenuAndExecute() {
        Task { @MainActor in
            // Get selected item before hiding based on which ring is active
            let selectedItem: RadialMenuItem?
            switch radialMenuState.selectedRing {
            case .inner:
                selectedItem = radialMenuState.highlightedItem()
            case .outer:
                selectedItem = radialMenuState.outerRingHighlightedItem()
            case .none:
                selectedItem = nil
            }

            // Hide menu and show cursor
            radialMenuState.hide()
            radialMenuWindowController?.hide()
            mouseController.showCursor()

            // Execute selected action
            if let item = selectedItem {
                executeRadialMenuAction(item.action)
            }
        }
    }

    /// Execute a radial menu action
    private func executeRadialMenuAction(_ action: RadialMenuAction) {
        switch action {
        case .none:
            break
        case .keyPress(let combo):
            // Build flags with required extras for arrow keys
            var flags = combo.eventFlags
            let arrowKeys: [UInt16] = [123, 124, 125, 126]  // left, right, down, up
            if arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskNumericPad)
            }
            if flags.contains(.maskControl) && arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskSecondaryFn)
            }

            // Key down + up
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
