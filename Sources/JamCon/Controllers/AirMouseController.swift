import Foundation
import IOKit
import IOKit.hid
import os.lock
import QuartzCore
import CoreGraphics
import Carbon.HIToolbox
import AppKit

// MARK: - Air Mouse Device

/// Represents a connected (seized) air mouse device
final class AirMouseDevice: InputDevice, @unchecked Sendable {
    let id: UUID
    let deviceType: InputDeviceType = .airMouse
    let displayName: String
    let capabilities: DeviceCapabilities = .airMouse

    private(set) var batteryLevel: BatteryLevel = .unknown
    private(set) var isConnected: Bool = true

    /// The underlying HID devices (may be multiple interfaces for composite devices)
    let hidDevices: [IOHIDDevice]

    /// Button count detected from this device
    let buttonCount: Int

    /// Callbacks - called on HID queue
    var onMotionUpdate: ((_ dx: Double, _ dy: Double, _ timestamp: TimeInterval) -> Void)?
    var onButtonPress: ((_ buttonIndex: Int) -> Void)?
    var onButtonRelease: ((_ buttonIndex: Int) -> Void)?
    var onDisconnect: (() -> Void)?
    var onActivity: (() -> Void)?
    /// Called when a consumer/media key should be blocked from reaching the system
    var onConsumerKey: ((_ mediaKeyCode: Int64) -> Void)?

    /// Track button states for edge detection
    private var buttonStates: [Bool]

    /// Last activity timestamp
    var lastActivity: TimeInterval = CACurrentMediaTime()

    init(hidDevices: [IOHIDDevice], device: AvailableDevice, buttonCount: Int) {
        self.id = UUID()
        self.hidDevices = hidDevices
        self.displayName = device.displayName
        self.buttonCount = buttonCount
        self.buttonStates = Array(repeating: false, count: max(buttonCount, 8))
    }

    /// Process an HID input value
    func processInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        switch Int(usagePage) {
        case kHIDPage_GenericDesktop:
            processGenericDesktopValue(usage: Int(usage), value: intValue)

        case kHIDPage_Button:
            processButtonValue(usage: Int(usage), value: intValue)

        case kHIDPage_Consumer:
            // Consumer page - media keys, etc.
            // Map HID consumer usages to macOS media key codes
            // HID: 0xE9 (233) = Volume Up, macOS media key: 0
            // HID: 0xEA (234) = Volume Down, macOS media key: 1
            // HID: 0xE2 (226) = Mute, macOS media key: 7
            if intValue != 0 {
                logDebug("Consumer usage 0x\(String(usage, radix: 16)) = \(intValue)", category: "AirMouse")

                // Map HID consumer usage to macOS media key code and mark for blocking
                let mediaKeyCode: Int64?
                switch Int(usage) {
                case 0xE9: mediaKeyCode = 0    // Volume Up
                case 0xEA: mediaKeyCode = 1    // Volume Down
                case 0xE2: mediaKeyCode = 7    // Mute
                case 0xCD: mediaKeyCode = 16   // Play/Pause
                case 0xB5: mediaKeyCode = 17   // Next Track
                case 0xB6: mediaKeyCode = 18   // Previous Track
                default: mediaKeyCode = nil
                }

                if let code = mediaKeyCode {
                    onConsumerKey?(code)
                }
            }

        case kHIDPage_KeyboardOrKeypad:
            // Keyboard page
            if intValue != 0 {
                logDebug("Keyboard usage 0x\(String(usage, radix: 16)) = \(intValue)", category: "AirMouse")
            }

        default:
            // Log unknown pages to help identify what buttons send
            if intValue != 0 {
                logDebug("Unknown page 0x\(String(usagePage, radix: 16)) usage 0x\(String(usage, radix: 16)) = \(intValue)", category: "AirMouse")
            }
        }
    }

    private func processGenericDesktopValue(usage: Int, value: Int) {
        switch usage {
        case kHIDUsage_GD_X:
            // Horizontal movement
            if value != 0 {
                lastActivity = CACurrentMediaTime()
                onActivity?()
                // We'll accumulate and send in batches from the controller
                pendingDx += Double(value)
            }

        case kHIDUsage_GD_Y:
            // Vertical movement
            if value != 0 {
                lastActivity = CACurrentMediaTime()
                onActivity?()
                pendingDy += Double(value)
            }

        case kHIDUsage_GD_Wheel:
            // Scroll wheel - could be used for scroll mode
            // For now, we ignore it since we handle scroll via override mode
            break

        default:
            break
        }
    }

    private func processButtonValue(usage: Int, value: Int) {
        // Button usages are 1-indexed (Button 1, Button 2, etc.)
        let buttonIndex = usage - 1
        guard buttonIndex >= 0 && buttonIndex < buttonStates.count else { return }

        let isPressed = value != 0
        let wasPressed = buttonStates[buttonIndex]

        if isPressed != wasPressed {
            buttonStates[buttonIndex] = isPressed
            lastActivity = CACurrentMediaTime()
            onActivity?()

            if isPressed {
                onButtonPress?(buttonIndex)
            } else {
                onButtonRelease?(buttonIndex)
            }
        }
    }

    /// Accumulated movement deltas (sent in batches)
    private var pendingDx: Double = 0
    private var pendingDy: Double = 0

    /// Flush accumulated movement deltas
    func flushMotion() {
        if pendingDx != 0 || pendingDy != 0 {
            onMotionUpdate?(pendingDx, pendingDy, CACurrentMediaTime())
            pendingDx = 0
            pendingDy = 0
        }
    }

    func markDisconnected() {
        isConnected = false
        onDisconnect?()
    }
}

// MARK: - Air Mouse Controller

/// Manages generic air mouse HID connections
class AirMouseController {

    // MARK: - Callbacks

    /// Called when the list of available (not yet seized) devices changes
    var onAvailableDevicesChanged: ((_ devices: [AvailableDevice]) -> Void)?

    /// Called when a device is successfully seized and connected
    var onDeviceConnected: ((_ device: AirMouseDevice) -> Void)?

    /// Called when a seized device is disconnected
    var onDeviceDisconnected: ((_ device: AirMouseDevice) -> Void)?

    /// Motion update callback (dx, dy, timestamp)
    var onMotionUpdate: ((_ deviceId: UUID, _ dx: Double, _ dy: Double, _ timestamp: TimeInterval) -> Void)?

    /// Button press callback
    var onButtonPress: ((_ deviceId: UUID, _ buttonIndex: Int) -> Void)?

    /// Button release callback
    var onButtonRelease: ((_ deviceId: UUID, _ buttonIndex: Int) -> Void)?

    /// Activity callback
    var onActivity: ((_ deviceId: UUID) -> Void)?

    // MARK: - State

    private var isScanning = false
    private var scanManager: IOHIDManager?
    private var seizeManager: IOHIDManager?
    private var runLoop: RunLoop?
    private let hidQueue = DispatchQueue(label: "AirMouseController.hidQueue", qos: .userInteractive)

    /// Retained reference to self for IOKit callbacks
    private var retainedSelf: Unmanaged<AirMouseController>?

    /// Available devices (discovered but not seized)
    private let availableLock = OSAllocatedUnfairLock(initialState: [IOHIDDevice: HIDDeviceInfo]())

    /// Connected (seized) devices
    private let connectedLock = OSAllocatedUnfairLock(initialState: [IOHIDDevice: AirMouseDevice]())

    /// Device being seized (waiting for seize to complete)
    private var pendingSeize: HIDDeviceInfo?

    /// Timer for flushing motion updates
    private var motionFlushTimer: Timer?

    // MARK: - Event Tap for Blocking System Events

    /// Event tap to intercept and block media/consumer keys
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    /// Consumer key codes that we should block (received from our device)
    /// Key: NX key code, Value: timestamp when received (to expire old entries)
    private let blockedKeysLock = OSAllocatedUnfairLock(initialState: [Int64: TimeInterval]())

    /// How long to block a key after receiving it from our device (in seconds)
    private let blockKeyDuration: TimeInterval = 0.1

    // MARK: - Privileged Daemon Client

    /// Client for receiving events from jamcon-hid daemon (keyboard interface)
    private var privilegedClient: PrivilegedHIDClient?

    // MARK: - DinoStrike Button State Machine

    /// State for DinoStrike keyboard buttons (Button 1 & 2)
    private enum DinoStrikeButtonState {
        case idle
        case pendingClick(button: Int)
        case holding(button: Int)
    }

    /// Current state for DinoStrike keyboard button detection
    private var dinoStrikeState: DinoStrikeButtonState = .idle

    /// Timer for click detection (fires if no hold events arrive)
    private var clickDetectionTimer: Timer?

    /// Timer for hold release detection (fires when hold events stop)
    private var holdReleaseTimer: Timer?

    /// Map keyboard usages to button numbers: 75 (Page Up) -> Button 1, 78 (Page Down) -> Button 2
    private let dinoStrikeButtonMap: [Int: Int] = [75: 1, 78: 2]

    /// Click detection delay (ms) - how long to wait to confirm it's not a hold
    private let clickDetectionDelay: TimeInterval = 0.15

    /// Hold release delay (ms) - how long without events before we consider hold released
    private let holdReleaseDelay: TimeInterval = 0.20

    // MARK: - Public Methods

    /// Start scanning for available mouse devices
    func startScanning() {
        guard !isScanning else { return }
        isScanning = true

        // Set up event tap on main thread
        DispatchQueue.main.async { [weak self] in
            self?.setupEventTap()
        }

        // Try to connect to privileged daemon for keyboard interface events
        connectToPrivilegedDaemon()

        hidQueue.async { [weak self] in
            self?.setupScanManager()
        }
    }

    /// Connect to the jamcon-hid daemon for keyboard interface events
    private func connectToPrivilegedDaemon() {
        privilegedClient = PrivilegedHIDClient()
        if privilegedClient?.connect() == true {
            logInfo("Connected to jamcon-hid daemon for keyboard events", category: "AirMouse")
            privilegedClient?.onInput = { [weak self] page, usage, value in
                self?.handleDaemonInput(page: page, usage: usage, value: value)
            }
            privilegedClient?.onDeviceEvent = { connected, name in
                if connected {
                    logInfo("Daemon: device connected - \(name)", category: "AirMouse")
                } else {
                    logInfo("Daemon: device disconnected - \(name)", category: "AirMouse")
                }
            }
        } else {
            logInfo("jamcon-hid daemon not available (keyboard buttons won't work)", category: "AirMouse")
            privilegedClient = nil
        }
    }

    /// Stop scanning
    func stopScanning() {
        guard isScanning else { return }
        isScanning = false

        if let currentLoop = runLoop?.getCFRunLoop() {
            CFRunLoopStop(currentLoop)
        }

        unregisterCallbacks()
        cleanUp()

        // Disconnect from privileged daemon
        privilegedClient?.disconnect()
        privilegedClient = nil

        // Tear down event tap on main thread
        DispatchQueue.main.async { [weak self] in
            self?.teardownEventTap()
        }
    }

    /// Get currently available (not seized) devices, grouped by physical device
    var availableDevices: [AvailableDevice] {
        let allInfos = availableLock.withLock { Array($0.values) }

        // Group by vendorId + productId + transport
        var groups: [String: [HIDDeviceInfo]] = [:]
        for info in allInfos {
            let key = info.groupKey
            groups[key, default: []].append(info)
        }

        // Convert to AvailableDevice
        return groups.map { key, infos in
            let first = infos[0]
            return AvailableDevice(
                id: key,
                vendorId: first.vendorId,
                productId: first.productId,
                productName: first.productName,
                manufacturerName: first.manufacturerName,
                transport: first.transport,
                interfaceCount: infos.count
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    /// Get currently connected (seized) devices
    var connectedDevices: [AirMouseDevice] {
        connectedLock.withLock { Array($0.values) }
    }

    /// Connect to (seize) a specific device (all its interfaces)
    /// Also adds the device to the managed list for auto-reconnection
    func connect(to device: AvailableDevice) {
        logInfo("Connecting to device: \(device.displayName)", category: "AirMouse")

        // Add to managed list for auto-reconnection
        ManagedDeviceRegistry.shared.add(device)

        // Find ALL IOHIDDevice interfaces with matching vendorId, productId, and transport
        let matchingDevices: [(IOHIDDevice, HIDDeviceInfo)] = availableLock.withLock { available in
            available.filter { _, info in
                info.vendorId == device.vendorId &&
                info.productId == device.productId &&
                info.transport == device.transport
            }.map { ($0.key, $0.value) }
        }

        guard !matchingDevices.isEmpty else {
            logError("Device not found in available list", category: "AirMouse")
            return
        }

        logInfo("Found \(matchingDevices.count) interface(s) to seize", category: "AirMouse")

        // Seize ALL matching interfaces
        var seizedDevices: [IOHIDDevice] = []
        var totalButtonCount = 0

        for (hidDevice, _) in matchingDevices {
            // Log interface details before attempting seizure
            let usagePage = IOHIDDeviceGetProperty(hidDevice, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(hidDevice, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            logDebug("Attempting to seize interface: usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))", category: "AirMouse")

            let result = IOHIDDeviceOpen(hidDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if result != kIOReturnSuccess {
                logWarning("Failed to seize interface (page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))): IOReturn 0x\(String(format: "%08X", UInt32(bitPattern: result)))", category: "AirMouse")
                continue
            }
            seizedDevices.append(hidDevice)
            totalButtonCount = max(totalButtonCount, getButtonCount(for: hidDevice))
            logDebug("Seized interface (page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))) with \(getButtonCount(for: hidDevice)) buttons", category: "AirMouse")
        }

        guard !seizedDevices.isEmpty else {
            logError("Failed to seize any interfaces", category: "AirMouse")
            return
        }

        logInfo("Successfully seized \(seizedDevices.count) interface(s)", category: "AirMouse")

        // Create AirMouseDevice with all seized interfaces
        let airMouse = AirMouseDevice(hidDevices: seizedDevices, device: device, buttonCount: totalButtonCount)

        // Register input callback on EACH seized device
        let airMousePtr = Unmanaged.passUnretained(airMouse).toOpaque()
        for hidDevice in seizedDevices {
            IOHIDDeviceRegisterInputValueCallback(hidDevice, { context, result, sender, value in
                guard let context else { return }
                let device = Unmanaged<AirMouseDevice>.fromOpaque(context).takeUnretainedValue()
                device.processInputValue(value)
            }, airMousePtr)
        }

        // Wire up callbacks for external notifications
        let deviceId = airMouse.id
        let deviceName = airMouse.displayName
        airMouse.onMotionUpdate = { [weak self] dx, dy, timestamp in
            self?.onMotionUpdate?(deviceId, dx, dy, timestamp)
        }
        airMouse.onButtonPress = { [weak self] buttonIndex in
            logInfo("Button \(buttonIndex) pressed on \(deviceName)", category: "AirMouse")
            self?.onButtonPress?(deviceId, buttonIndex)
        }
        airMouse.onButtonRelease = { [weak self] buttonIndex in
            logDebug("Button \(buttonIndex) released on \(deviceName)", category: "AirMouse")
            self?.onButtonRelease?(deviceId, buttonIndex)
        }
        airMouse.onActivity = { [weak self] in
            self?.onActivity?(deviceId)
        }
        airMouse.onConsumerKey = { [weak self] mediaKeyCode in
            self?.markKeyForBlocking(mediaKeyCode)
        }

        // Move ALL matching devices from available to connected
        availableLock.withLock { available in
            for hidDevice in seizedDevices {
                available.removeValue(forKey: hidDevice)
            }
        }
        // Store under first device key (all point to same AirMouseDevice)
        if let firstDevice = seizedDevices.first {
            connectedLock.withLock { $0[firstDevice] = airMouse }
        }

        logInfo("Successfully connected to: \(device.displayName) (\(seizedDevices.count) interfaces)", category: "AirMouse")

        // Notify
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDeviceConnected?(airMouse)
            self.onAvailableDevicesChanged?(self.availableDevices)
        }
    }

    /// Disconnect from a seized device
    /// Also removes the device from the managed list (no auto-reconnection)
    func disconnect(deviceId: UUID) {
        let entry: (IOHIDDevice, AirMouseDevice)? = connectedLock.withLock { connected in
            connected.first { $0.value.id == deviceId }
        }

        guard let (_, airMouse) = entry else {
            logWarning("Device not found for disconnect", category: "AirMouse")
            return
        }

        // Find the group key from device properties
        if let hidDevice = airMouse.hidDevices.first {
            let info = createDeviceInfo(for: hidDevice)
            ManagedDeviceRegistry.shared.remove(info.groupKey)
        }

        // Unregister input callbacks and close ALL interfaces
        for hidDevice in airMouse.hidDevices {
            IOHIDDeviceRegisterInputValueCallback(hidDevice, nil, nil)
            IOHIDDeviceClose(hidDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

            // Move back to available
            let deviceInfo = createDeviceInfo(for: hidDevice)
            availableLock.withLock { $0[hidDevice] = deviceInfo }
        }

        // Remove from connected (stored under first device)
        if let firstDevice = airMouse.hidDevices.first {
            _ = connectedLock.withLock { $0.removeValue(forKey: firstDevice) }
        }

        airMouse.markDisconnected()

        logInfo("Disconnected device: \(airMouse.displayName) (\(airMouse.hidDevices.count) interfaces)", category: "AirMouse")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDeviceDisconnected?(airMouse)
            self.onAvailableDevicesChanged?(self.availableDevices)
        }
    }

    // MARK: - HID Manager Setup

    private func setupScanManager() {
        scanManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = scanManager else { return }

        // Match pointing devices (mice) and consumer control devices
        // Composite devices like air mice often have multiple interfaces:
        // - Mouse interface (pointer movement, left click)
        // - Consumer Control interface (volume, media keys)
        // - Keyboard interface (other buttons)
        let mouseCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
        ]
        let pointerCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer,
        ]
        let consumerCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_Consumer,
            kIOHIDDeviceUsageKey as String: 0x01,  // Consumer Control
        ]
        let keyboardCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]

        let criteria = [mouseCriteria, pointerCriteria, consumerCriteria, keyboardCriteria]
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

        let currentRunLoop = RunLoop.current
        IOHIDManagerScheduleWithRunLoop(manager, currentRunLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)

        // Open without seizing - just enumerate
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if ret != kIOReturnSuccess {
            print("[AirMouseController] Failed to open HID manager: \(ret)")
            return
        }

        registerCallbacks()

        // Start motion flush timer
        motionFlushTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            self?.flushAllMotion()
        }

        runLoop = currentRunLoop
        runLoop?.run()

        // Cleanup after run loop exits
        motionFlushTimer?.invalidate()
        motionFlushTimer = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, currentRunLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func registerCallbacks() {
        guard let manager = scanManager else { return }

        retainedSelf = Unmanaged.passRetained(self)
        let context = retainedSelf!.toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, handleMatchCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, handleRemoveCallback, context)
        IOHIDManagerRegisterInputValueCallback(manager, handleInputCallback, context)
    }

    private func unregisterCallbacks() {
        guard let manager = scanManager else { return }

        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)

        retainedSelf?.release()
        retainedSelf = nil
    }

    private func cleanUp() {
        // Disconnect all seized devices
        let connected = connectedLock.withLock { Array($0.values) }
        for airMouse in connected {
            for hidDevice in airMouse.hidDevices {
                IOHIDDeviceRegisterInputValueCallback(hidDevice, nil, nil)
                IOHIDDeviceClose(hidDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            }
            airMouse.markDisconnected()
        }
        connectedLock.withLock { $0.removeAll() }
        availableLock.withLock { $0.removeAll() }
    }

    // MARK: - Callbacks

    private let handleMatchCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context else { return }
        let controller = Unmanaged<AirMouseController>.fromOpaque(context).takeUnretainedValue()
        controller.handleDeviceMatched(device)
    }

    private let handleRemoveCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context else { return }
        let controller = Unmanaged<AirMouseController>.fromOpaque(context).takeUnretainedValue()
        controller.handleDeviceRemoved(device)
    }

    private let handleInputCallback: IOHIDValueCallback = { context, result, sender, value in
        guard let context, let sender else { return }
        let controller = Unmanaged<AirMouseController>.fromOpaque(context).takeUnretainedValue()
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        controller.handleInput(device: device, value: value)
    }

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        // Skip if already known
        let alreadyKnown = availableLock.withLock { $0[device] != nil } ||
                          connectedLock.withLock { $0[device] != nil }
        guard !alreadyKnown else { return }

        let deviceInfo = createDeviceInfo(for: device)

        // Skip Apple internal devices (trackpad, etc.)
        if isInternalDevice(deviceInfo) {
            logDebug("Skipping internal device: \(deviceInfo.displayName)", category: "AirMouse")
            return
        }

        // Log detailed device info for identification
        logInfo("Device discovered: \(deviceInfo.displayName)", category: "AirMouse")
        logInfo("  VendorID: 0x\(String(deviceInfo.vendorId, radix: 16, uppercase: true))", category: "AirMouse")
        logInfo("  ProductID: 0x\(String(deviceInfo.productId, radix: 16, uppercase: true))", category: "AirMouse")
        logInfo("  Manufacturer: \(deviceInfo.manufacturerName)", category: "AirMouse")
        logInfo("  Transport: \(deviceInfo.transport)", category: "AirMouse")
        if let serial = deviceInfo.serialNumber {
            logInfo("  Serial: \(serial)", category: "AirMouse")
        }

        availableLock.withLock { $0[device] = deviceInfo }

        // Notify about available devices
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onAvailableDevicesChanged?(self.availableDevices)
        }

        // Check if this device is in the managed list - if so, auto-connect
        if ManagedDeviceRegistry.shared.contains(deviceInfo.groupKey) {
            logInfo("Auto-connecting to managed device: \(deviceInfo.displayName)", category: "AirMouse")
            ManagedDeviceRegistry.shared.updateLastSeen(deviceInfo.groupKey)

            // Build AvailableDevice from info for auto-connect
            // Delay slightly to allow all interfaces to be discovered
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                // Re-check available devices to get all interfaces
                let availableNow = self.availableDevices
                if let device = availableNow.first(where: { $0.id == deviceInfo.groupKey }) {
                    self.autoConnect(to: device)
                }
            }
        }
    }

    /// Auto-connect to a managed device (internal use)
    private func autoConnect(to device: AvailableDevice) {
        logInfo("Auto-connecting to: \(device.displayName) (\(device.interfaceCount) interfaces)", category: "AirMouse")

        // Find ALL IOHIDDevice interfaces with matching vendorId, productId, and transport
        let matchingDevices: [(IOHIDDevice, HIDDeviceInfo)] = availableLock.withLock { available in
            available.filter { _, info in
                info.vendorId == device.vendorId &&
                info.productId == device.productId &&
                info.transport == device.transport
            }.map { ($0.key, $0.value) }
        }

        guard !matchingDevices.isEmpty else {
            logWarning("Auto-connect: device no longer available", category: "AirMouse")
            return
        }

        // Seize ALL matching interfaces
        var seizedDevices: [IOHIDDevice] = []
        var totalButtonCount = 0

        for (hidDevice, _) in matchingDevices {
            let usagePage = IOHIDDeviceGetProperty(hidDevice, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(hidDevice, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0

            let result = IOHIDDeviceOpen(hidDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if result != kIOReturnSuccess {
                logDebug("Auto-connect: failed to seize interface (page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)))", category: "AirMouse")
                continue
            }
            seizedDevices.append(hidDevice)
            totalButtonCount = max(totalButtonCount, getButtonCount(for: hidDevice))
        }

        guard !seizedDevices.isEmpty else {
            logWarning("Auto-connect: failed to seize any interfaces", category: "AirMouse")
            return
        }

        logInfo("Auto-connected: seized \(seizedDevices.count) interface(s)", category: "AirMouse")

        // Create AirMouseDevice with all seized interfaces
        let airMouse = AirMouseDevice(hidDevices: seizedDevices, device: device, buttonCount: totalButtonCount)

        // Register input callback on EACH seized device
        let airMousePtr = Unmanaged.passUnretained(airMouse).toOpaque()
        for hidDevice in seizedDevices {
            IOHIDDeviceRegisterInputValueCallback(hidDevice, { context, result, sender, value in
                guard let context else { return }
                let device = Unmanaged<AirMouseDevice>.fromOpaque(context).takeUnretainedValue()
                device.processInputValue(value)
            }, airMousePtr)
        }

        // Wire up callbacks for external notifications
        let deviceId = airMouse.id
        let deviceName = airMouse.displayName
        airMouse.onMotionUpdate = { [weak self] dx, dy, timestamp in
            self?.onMotionUpdate?(deviceId, dx, dy, timestamp)
        }
        airMouse.onButtonPress = { [weak self] buttonIndex in
            logInfo("Button \(buttonIndex) pressed on \(deviceName)", category: "AirMouse")
            self?.onButtonPress?(deviceId, buttonIndex)
        }
        airMouse.onButtonRelease = { [weak self] buttonIndex in
            logDebug("Button \(buttonIndex) released on \(deviceName)", category: "AirMouse")
            self?.onButtonRelease?(deviceId, buttonIndex)
        }
        airMouse.onActivity = { [weak self] in
            self?.onActivity?(deviceId)
        }
        airMouse.onConsumerKey = { [weak self] mediaKeyCode in
            self?.markKeyForBlocking(mediaKeyCode)
        }

        // Move ALL matching devices from available to connected
        availableLock.withLock { available in
            for hidDevice in seizedDevices {
                available.removeValue(forKey: hidDevice)
            }
        }
        // Store under first device key (all point to same AirMouseDevice)
        if let firstDevice = seizedDevices.first {
            connectedLock.withLock { $0[firstDevice] = airMouse }
        }

        // Notify
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDeviceConnected?(airMouse)
            self.onAvailableDevicesChanged?(self.availableDevices)
        }
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        // Check if it was available (not seized)
        if let info = availableLock.withLock({ $0.removeValue(forKey: device) }) {
            logInfo("Available device removed: \(info.displayName)", category: "AirMouse")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onAvailableDevicesChanged?(self.availableDevices)
            }
            return
        }

        // Check if it was connected (seized)
        if let airMouse = connectedLock.withLock({ $0.removeValue(forKey: device) }) {
            logWarning("Connected device removed: \(airMouse.displayName)", category: "AirMouse")
            airMouse.markDisconnected()
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceDisconnected?(airMouse)
            }
        }
    }

    private func handleInput(device: IOHIDDevice, value: IOHIDValue) {
        // Only process input from seized (connected) devices
        guard let airMouse = connectedLock.withLock({ $0[device] }) else { return }
        airMouse.processInputValue(value)
    }

    private func flushAllMotion() {
        let devices = connectedLock.withLock { Array($0.values) }
        for device in devices {
            device.flushMotion()
        }
    }

    // MARK: - Helpers

    private func createDeviceInfo(for device: IOHIDDevice) -> HIDDeviceInfo {
        let vendorId = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productId = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? ""
        let serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"

        return HIDDeviceInfo(
            id: UUID(),
            vendorId: vendorId,
            productId: productId,
            productName: productName,
            manufacturerName: manufacturer,
            serialNumber: serialNumber,
            transport: transport
        )
    }

    private func getButtonCount(for device: IOHIDDevice) -> Int {
        // Query the device for button elements
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return 3  // Default to 3 buttons
        }

        var maxButton = 0
        for element in elements {
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            if usagePage == kHIDPage_Button {
                maxButton = max(maxButton, Int(usage))
            }
        }

        return max(maxButton, 2)  // At least 2 buttons
    }

    private func isInternalDevice(_ info: HIDDeviceInfo) -> Bool {
        // Skip Apple internal devices and accessories
        let blacklist = [
            "Apple Internal Keyboard / Trackpad",
            "Lightning Trackpad",
            "Magic Keyboard",
            "Magic Trackpad",
            "Magic Mouse",
            "Touch Bar",
        ]
        if blacklist.contains(info.productName) {
            return true
        }
        // Skip any Apple device (vendor ID 0x05AC)
        if info.vendorId == 0x05AC {
            return true
        }
        return false
    }

    // MARK: - Daemon Event Handling

    /// Handle input events from the jamcon-hid daemon
    /// Implements DinoStrike button detection with click/hold/release
    private func handleDaemonInput(page: Int, usage: Int, value: Int) {
        // Get the first connected air mouse device (daemon events go to it)
        guard let airMouse = connectedLock.withLock({ $0.values.first }) else {
            return
        }

        let deviceId = airMouse.id

        // Map based on HID page
        switch page {
        case kHIDPage_KeyboardOrKeypad:  // Page 7
            handleDinoStrikeKeyboardEvent(usage: usage, deviceId: deviceId)

        case kHIDPage_Button:  // Page 9
            // Button 3 (Trigger) - skip daemon events, handled by direct HID to avoid duplicates
            break

        case kHIDPage_Consumer:  // Page 12
            // Volume buttons - will implement later (buttons 4 & 5)
            // For now, just block system volume changes
            if usage == 0xE9 { markKeyForBlocking(0) }  // Volume Up
            if usage == 0xEA { markKeyForBlocking(1) }  // Volume Down

        default:
            break
        }

        // Trigger activity
        onActivity?(deviceId)
    }

    /// Handle DinoStrike keyboard events with click/hold detection
    private func handleDinoStrikeKeyboardEvent(usage: Int, deviceId: UUID) {
        // Check if this is a primary button press (Button 1: 75, Button 2: 78)
        if let buttonNum = dinoStrikeButtonMap[usage] {
            // This is a primary button event
            handleDinoStrikePrimaryButton(button: buttonNum, deviceId: deviceId)
        } else {
            // This is a secondary event (hold indicator)
            handleDinoStrikeHoldEvent(deviceId: deviceId)
        }
    }

    /// Handle primary button press (usage 75 or 78)
    private func handleDinoStrikePrimaryButton(button: Int, deviceId: UUID) {
        // Cancel any existing timers
        clickDetectionTimer?.invalidate()
        holdReleaseTimer?.invalidate()

        // If we were holding a different button, release it first
        if case .holding(let prevButton) = dinoStrikeState, prevButton != button {
            logInfo("DinoStrike: Button \(prevButton) hold released (switching)", category: "AirMouse")
            onButtonRelease?(deviceId, prevButton)
        }

        // Start click detection timer
        dinoStrikeState = .pendingClick(button: button)
        clickDetectionTimer = Timer.scheduledTimer(withTimeInterval: clickDetectionDelay, repeats: false) { [weak self] _ in
            self?.handleClickTimerFired(button: button, deviceId: deviceId)
        }

        logDebug("DinoStrike: Button \(button) pending (waiting for click/hold)", category: "AirMouse")
    }

    /// Timer fired - no hold events arrived, so this was a click
    private func handleClickTimerFired(button: Int, deviceId: UUID) {
        guard case .pendingClick(let pendingButton) = dinoStrikeState, pendingButton == button else {
            return
        }

        // Fire click (press + release as one action)
        logInfo("DinoStrike: Button \(button) CLICK", category: "AirMouse")
        onButtonPress?(deviceId, button)
        onButtonRelease?(deviceId, button)

        dinoStrikeState = .idle
    }

    /// Handle secondary keyboard event (indicates hold is active)
    private func handleDinoStrikeHoldEvent(deviceId: UUID) {
        switch dinoStrikeState {
        case .idle:
            // Spurious event, ignore
            break

        case .pendingClick(let button):
            // Hold detected! Cancel click timer and fire hold start
            clickDetectionTimer?.invalidate()
            clickDetectionTimer = nil

            logInfo("DinoStrike: Button \(button) HOLD START", category: "AirMouse")
            onButtonPress?(deviceId, button)

            dinoStrikeState = .holding(button: button)
            startHoldReleaseTimer(button: button, deviceId: deviceId)

        case .holding(let button):
            // Still holding - reset the release timer
            startHoldReleaseTimer(button: button, deviceId: deviceId)
        }
    }

    /// Start/reset the hold release timer
    private func startHoldReleaseTimer(button: Int, deviceId: UUID) {
        holdReleaseTimer?.invalidate()
        holdReleaseTimer = Timer.scheduledTimer(withTimeInterval: holdReleaseDelay, repeats: false) { [weak self] _ in
            self?.handleHoldReleaseTimerFired(button: button, deviceId: deviceId)
        }
    }

    /// Hold release timer fired - no events for 200ms, hold is released
    private func handleHoldReleaseTimerFired(button: Int, deviceId: UUID) {
        guard case .holding(let holdingButton) = dinoStrikeState, holdingButton == button else {
            return
        }

        logInfo("DinoStrike: Button \(button) HOLD RELEASE", category: "AirMouse")
        onButtonRelease?(deviceId, button)

        dinoStrikeState = .idle
    }

    // MARK: - Event Tap

    /// Set up the event tap to intercept media/consumer keys
    private func setupEventTap() {
        guard eventTap == nil else { return }

        // Create event tap for system-defined events (which include media keys)
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << Int(NX_SYSDEFINED))

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<AirMouseController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleEventTap(proxy: proxy, type: type, event: event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: refcon
        )

        guard let tap = eventTap else {
            logWarning("Failed to create event tap - media key blocking unavailable", category: "AirMouse")
            return
        }

        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = eventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            logInfo("Event tap installed - media key blocking active", category: "AirMouse")
        }
    }

    /// Remove the event tap
    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapRunLoopSource = nil
    }

    /// Mark a consumer key code as one we should block
    func markKeyForBlocking(_ keyCode: Int64) {
        let now = CACurrentMediaTime()
        blockedKeysLock.withLock { blocked in
            blocked[keyCode] = now
            // Clean up old entries
            blocked = blocked.filter { $0.value > now - blockKeyDuration * 2 }
        }
    }

    /// Check if we should block this key code
    private func shouldBlockKey(_ keyCode: Int64) -> Bool {
        let now = CACurrentMediaTime()
        return blockedKeysLock.withLock { blocked in
            if let timestamp = blocked[keyCode], now - timestamp < blockKeyDuration {
                blocked.removeValue(forKey: keyCode)
                return true
            }
            return false
        }
    }

    /// Handle the event tap callback
    private func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle NX_SYSDEFINED events (media keys)
        if type.rawValue == UInt32(NX_SYSDEFINED) {
            // Media keys have subtype 8
            if let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 {
                let keyCode = (nsEvent.data1 >> 16) & 0xFF
                let keyDown = ((nsEvent.data1 >> 8) & 0xFF) == 0xA

                // Check if this is a media key we should block
                // Volume Up: 0, Volume Down: 1, Mute: 7
                // We block these if we recently received them from our HID device
                let keyCodeInt64 = Int64(keyCode)
                if shouldBlockKey(keyCodeInt64) {
                    logDebug("Blocked media key: \(keyCode) (\(keyDown ? "down" : "up"))", category: "AirMouse")
                    return nil  // Block the event
                }
            }
        }

        // Pass through unblocked events
        return Unmanaged.passUnretained(event)
    }

    deinit {
        teardownEventTap()
        stopScanning()
    }
}

// MARK: - Privileged HID Client (Socket)

/// Client that connects to jamcon-hid daemon for keyboard interface events
/// that macOS won't let unprivileged apps seize
class PrivilegedHIDClient {
    static let socketPath = "/var/run/jamcon-hid.sock"

    private var socket: Int32 = -1
    private var readThread: Thread?
    private var isRunning = false

    /// Callback for input events (page, usage, value)
    var onInput: ((_ page: Int, _ usage: Int, _ value: Int) -> Void)?

    /// Callback for device connect/disconnect
    var onDeviceEvent: ((_ connected: Bool, _ name: String) -> Void)?

    var isConnected: Bool { socket >= 0 }

    func connect() -> Bool {
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path
        let pathBytes = Self.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { sunPath in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    sunPath[i] = byte
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(socket)
            socket = -1
            return false
        }

        // Start read thread
        isRunning = true
        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.name = "PrivilegedHIDClient"
        readThread?.start()

        return true
    }

    func disconnect() {
        isRunning = false
        if socket >= 0 {
            close(socket)
            socket = -1
        }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var lineBuffer = ""

        while isRunning && socket >= 0 {
            let bytesRead = read(socket, &buffer, buffer.count)
            if bytesRead <= 0 { break }

            // Parse newline-delimited JSON
            lineBuffer += String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                let line = String(lineBuffer[..<newlineIndex])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
                parseMessage(line)
            }
        }

        // Connection lost
        isRunning = false
        socket = -1
    }

    private func parseMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        switch type {
        case "input":
            if let page = msg["page"] as? Int,
               let usage = msg["usage"] as? Int,
               let value = msg["value"] as? Int {
                // Filter out selector noise (0xFFFFFFFF)
                guard usage != Int(UInt32.max) else { return }
                onInput?(page, usage, value)
            }
        case "device_connected":
            if let name = msg["name"] as? String {
                onDeviceEvent?(true, name)
            }
        case "device_disconnected":
            if let name = msg["name"] as? String {
                onDeviceEvent?(false, name)
            }
        default:
            break
        }
    }
}
