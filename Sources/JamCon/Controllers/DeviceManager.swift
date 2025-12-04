import Foundation
import SwiftUI
import os.lock

// MARK: - Unified Device Wrapper

/// Wrapper to provide InputDevice conformance for Joy-Cons
final class JoyConDeviceWrapper: InputDevice, @unchecked Sendable {
    let id: UUID
    let deviceType: InputDeviceType
    let displayName: String
    let capabilities: DeviceCapabilities = .joyCon

    private(set) var batteryLevel: BatteryLevel
    private(set) var isConnected: Bool

    /// The underlying connected controller
    let connectedController: ConnectedController

    init(from controller: ConnectedController) {
        self.id = controller.id
        self.deviceType = InputDeviceType(from: controller.type)
        self.displayName = controller.name
        self.batteryLevel = controller.batteryLevel
        self.isConnected = true
        self.connectedController = controller
    }

    func updateBattery(_ level: BatteryLevel) {
        batteryLevel = level
    }

    func markDisconnected() {
        isConnected = false
    }
}

// MARK: - Device Slot

/// Represents an assignment of a device to a slot (primary/secondary)
enum DeviceSlot: String, CaseIterable {
    case primary
    case secondary

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Device Manager

/// Manages all input devices (Joy-Cons and air mice), providing unified callbacks
@MainActor
class DeviceManager: ObservableObject {

    // MARK: - Published State

    /// All currently connected devices (Joy-Cons + air mice)
    @Published private(set) var connectedDevices: [any InputDevice] = []

    /// Available air mice (discovered but not connected), grouped by device
    @Published private(set) var availableAirMice: [AvailableDevice] = []

    /// Device assigned to primary slot
    @Published private(set) var primaryDevice: (any InputDevice)?

    /// Device assigned to secondary slot
    @Published private(set) var secondaryDevice: (any InputDevice)?

    // MARK: - Callbacks (for AppState to wire up)

    /// Motion update callback with device ID and motion data
    var onMotionUpdate: ((_ deviceId: UUID, _ motion: MotionData, _ timestamp: TimeInterval) -> Void)?

    /// Button press callback
    var onButtonPress: ((_ deviceId: UUID, _ deviceType: InputDeviceType, _ button: DeviceButton) -> Void)?

    /// Button release callback
    var onButtonRelease: ((_ deviceId: UUID, _ deviceType: InputDeviceType, _ button: DeviceButton) -> Void)?

    /// Stick update callback (Joy-Cons only)
    var onStickUpdate: ((_ deviceId: UUID, _ position: StickPosition) -> Void)?

    /// Connection change callback
    var onConnectionChange: ((_ devices: [any InputDevice]) -> Void)?

    /// Battery update callback
    var onBatteryUpdate: ((_ deviceId: UUID, _ level: BatteryLevel) -> Void)?

    /// Activity callback
    var onActivity: ((_ deviceId: UUID) -> Void)?

    // MARK: - Controllers

    private let joyConController = JoyConController()
    private let airMouseController = AirMouseController()

    /// Joy-Con wrappers indexed by their ID
    private var joyConWrappers: [UUID: JoyConDeviceWrapper] = [:]

    // MARK: - Initialization

    init() {
        setupJoyConCallbacks()
        setupAirMouseCallbacks()
    }

    // MARK: - Public Methods

    /// Start scanning for all device types
    func startScanning() {
        joyConController.startScanning()
        airMouseController.startScanning()
    }

    /// Stop scanning
    func stopScanning() {
        joyConController.stopScanning()
        airMouseController.stopScanning()
    }

    /// Assign a device to the primary slot
    func assignToPrimary(_ device: any InputDevice) {
        // If device was in secondary, clear it
        if secondaryDevice?.id == device.id {
            secondaryDevice = nil
        }
        primaryDevice = device
        print("[DeviceManager] Primary device: \(device.displayName)")
    }

    /// Assign a device to the secondary slot
    func assignToSecondary(_ device: any InputDevice) {
        // If device was in primary, clear it
        if primaryDevice?.id == device.id {
            primaryDevice = nil
        }
        secondaryDevice = device
        print("[DeviceManager] Secondary device: \(device.displayName)")
    }

    /// Clear a slot
    func clearSlot(_ slot: DeviceSlot) {
        switch slot {
        case .primary:
            primaryDevice = nil
        case .secondary:
            secondaryDevice = nil
        }
    }

    /// Connect to an available air mouse (all its interfaces)
    func connectAirMouse(_ device: AvailableDevice) {
        airMouseController.connect(to: device)
    }

    /// Disconnect an air mouse
    func disconnectAirMouse(_ deviceId: UUID) {
        // Clear from slots if assigned
        if primaryDevice?.id == deviceId {
            primaryDevice = nil
        }
        if secondaryDevice?.id == deviceId {
            secondaryDevice = nil
        }
        airMouseController.disconnect(deviceId: deviceId)
    }

    /// Get the slot for a device, if assigned
    func slot(for deviceId: UUID) -> DeviceSlot? {
        if primaryDevice?.id == deviceId { return .primary }
        if secondaryDevice?.id == deviceId { return .secondary }
        return nil
    }

    /// Check if a device ID is the primary device
    func isPrimary(_ deviceId: UUID) -> Bool {
        primaryDevice?.id == deviceId
    }

    // MARK: - Joy-Con Callbacks

    private func setupJoyConCallbacks() {
        joyConController.onConnectionChange = { [weak self] controllers in
            Task { @MainActor in
                self?.handleJoyConConnectionChange(controllers)
            }
        }

        joyConController.onGyroUpdate = { [weak self] controllerId, gyro, timestamp in
            self?.onMotionUpdate?(controllerId, .gyro(gyro), timestamp)
        }

        joyConController.onButtonPress = { [weak self] controllerId, controllerType, button in
            let deviceType = InputDeviceType(from: controllerType)
            self?.onButtonPress?(controllerId, deviceType, .joycon(button))
        }

        joyConController.onButtonRelease = { [weak self] controllerId, controllerType, button in
            let deviceType = InputDeviceType(from: controllerType)
            self?.onButtonRelease?(controllerId, deviceType, .joycon(button))
        }

        joyConController.onStickUpdate = { [weak self] controllerId, position in
            self?.onStickUpdate?(controllerId, position)
        }

        joyConController.onBatteryUpdate = { [weak self] controllerId, level in
            Task { @MainActor in
                self?.joyConWrappers[controllerId]?.updateBattery(level)
            }
            self?.onBatteryUpdate?(controllerId, level)
        }

        joyConController.onActivity = { [weak self] controllerId in
            self?.onActivity?(controllerId)
        }
    }

    private func handleJoyConConnectionChange(_ controllers: [ConnectedController]) {
        // Update wrappers
        var newWrappers: [UUID: JoyConDeviceWrapper] = [:]
        for controller in controllers {
            if let existing = joyConWrappers[controller.id] {
                newWrappers[controller.id] = existing
            } else {
                newWrappers[controller.id] = JoyConDeviceWrapper(from: controller)
            }
        }

        // Mark disconnected ones (but don't clear slot assignments - they persist)
        for (id, wrapper) in joyConWrappers {
            if newWrappers[id] == nil {
                wrapper.markDisconnected()
            }
        }

        joyConWrappers = newWrappers
        updateConnectedDevices()

        // Auto-assign first Joy-Con to primary if no primary set
        if primaryDevice == nil, let firstJoyCon = joyConWrappers.values.first {
            primaryDevice = firstJoyCon
        }
    }

    // MARK: - Air Mouse Callbacks

    private func setupAirMouseCallbacks() {
        airMouseController.onAvailableDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                self?.availableAirMice = devices
            }
        }

        airMouseController.onDeviceConnected = { [weak self] device in
            Task { @MainActor in
                self?.handleAirMouseConnected(device)
            }
        }

        airMouseController.onDeviceDisconnected = { [weak self] device in
            Task { @MainActor in
                self?.handleAirMouseDisconnected(device)
            }
        }

        airMouseController.onMotionUpdate = { [weak self] deviceId, dx, dy, timestamp in
            self?.onMotionUpdate?(deviceId, .mouseDeltas(dx: dx, dy: dy), timestamp)
        }

        airMouseController.onButtonPress = { [weak self] deviceId, buttonIndex in
            self?.onButtonPress?(deviceId, .airMouse, .mouseButton(index: buttonIndex))
        }

        airMouseController.onButtonRelease = { [weak self] deviceId, buttonIndex in
            self?.onButtonRelease?(deviceId, .airMouse, .mouseButton(index: buttonIndex))
        }

        airMouseController.onActivity = { [weak self] deviceId in
            self?.onActivity?(deviceId)
        }
    }

    private func handleAirMouseConnected(_ device: AirMouseDevice) {
        updateConnectedDevices()

        // Auto-assign to primary if no primary set
        if primaryDevice == nil {
            primaryDevice = device
        }
    }

    private func handleAirMouseDisconnected(_ device: AirMouseDevice) {
        // Don't clear slot assignments - they persist through disconnects
        // The persistent SlotAssignment (by name) remains, device just becomes unavailable
        updateConnectedDevices()
    }

    // MARK: - Helpers

    private func updateConnectedDevices() {
        var devices: [any InputDevice] = []

        // Add Joy-Cons
        for wrapper in joyConWrappers.values {
            devices.append(wrapper)
        }

        // Add air mice
        for airMouse in airMouseController.connectedDevices {
            devices.append(airMouse)
        }

        connectedDevices = devices
        onConnectionChange?(devices)
    }
}
