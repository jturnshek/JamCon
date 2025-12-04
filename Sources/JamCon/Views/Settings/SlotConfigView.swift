import SwiftUI

/// View for configuring a device slot (Primary or Secondary)
/// Shows device selection, device type selection, and links to configuration categories
struct SlotConfigView: View {
    @EnvironmentObject var appState: AppState
    let slot: DeviceSlot

    @State private var assignment: SlotAssignment
    @State private var settings: DeviceTypeSettings

    init(slot: DeviceSlot) {
        self.slot = slot
        // Load initial state
        let loadedAssignment = SlotAssignment.load(slot: slot)
        _assignment = State(initialValue: loadedAssignment)
        _settings = State(initialValue: DeviceTypeSettings.load(slot: slot, deviceType: loadedAssignment.deviceType))
    }

    var body: some View {
        List {
            // Device Selection
            Section("Assigned Device") {
                Picker("Device", selection: $assignment.deviceId) {
                    Text("None").tag(nil as UUID?)

                    ForEach(availableDevices) { device in
                        let assignedToOther = isAssignedToOtherSlot(device.name)
                        HStack {
                            Image(systemName: device.icon)
                            Text(device.name)
                            if assignedToOther {
                                Text("(\(otherSlot.displayName))")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(device.id as UUID?)
                        .foregroundColor(assignedToOther ? .secondary : .primary)
                    }
                }
                .onChange(of: assignment.deviceId) { _, newValue in
                    // Don't allow selecting a device assigned to the other slot
                    if let deviceId = newValue,
                       let device = findDevice(id: deviceId),
                       isAssignedToOtherSlot(device.name) {
                        assignment.deviceId = nil
                        assignment.deviceName = nil
                        return
                    }
                    if let deviceId = newValue,
                       let device = findDevice(id: deviceId) {
                        // Save device name (stable identifier)
                        assignment.deviceName = device.name
                        // Use the device type from the selectable device
                        assignment.deviceType = device.type
                        loadSettingsForCurrentType()
                    } else {
                        // Device deselected
                        assignment.deviceName = nil
                    }
                    saveAssignment()
                }
            }

            // Device Type Selection (only if device assigned)
            if assignment.deviceId != nil {
                Section("Device Type") {
                    Picker("Type", selection: $assignment.deviceType) {
                        ForEach(ConfigurableDeviceType.allCases) { type in
                            Label(type.displayName, systemImage: type.icon)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: assignment.deviceType) { _, _ in
                        loadSettingsForCurrentType()
                        saveAssignment()
                    }

                    Text("Settings are stored per device type. Switching types loads that type's saved configuration.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Configuration Categories
                Section("Configuration") {
                    ForEach(assignment.deviceType.availableSettings) { category in
                        NavigationLink(value: category) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.displayName)
                                    Text(category.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: category.icon)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("\(slot.displayName) Slot")
        .navigationDestination(for: SettingsCategory.self) { category in
            DeviceSettingsView(
                slot: slot,
                deviceType: assignment.deviceType,
                category: category,
                settings: $settings
            )
        }
        .onDisappear {
            saveSettings()
        }
    }

    // MARK: - Data

    /// Simple struct for device picker options
    private struct SelectableDevice: Identifiable, Hashable {
        let id: UUID
        let name: String
        let type: ConfigurableDeviceType
        let icon: String
    }

    private var availableDevices: [SelectableDevice] {
        var devices: [SelectableDevice] = []

        // Add Joy-Cons from connectedControllers
        for controller in appState.connectedControllers {
            let configurableType: ConfigurableDeviceType
            switch controller.type {
            case .leftJoyCon:
                configurableType = .leftJoyCon
            case .rightJoyCon:
                configurableType = .rightJoyCon
            case .proController:
                configurableType = .proController
            case .none:
                configurableType = .rightJoyCon
            }
            devices.append(SelectableDevice(
                id: controller.id,
                name: controller.name,
                type: configurableType,
                icon: "gamecontroller"
            ))
        }

        // Add air mice from deviceManager
        if let deviceManager = appState.deviceManager {
            for device in deviceManager.connectedDevices where device.deviceType.isMouse {
                devices.append(SelectableDevice(
                    id: device.id,
                    name: device.displayName,
                    type: .airMouseBasic,
                    icon: "computermouse"
                ))
            }
        }

        return devices
    }

    private var otherSlot: DeviceSlot {
        slot == .primary ? .secondary : .primary
    }

    private func isAssignedToOtherSlot(_ deviceName: String) -> Bool {
        let otherAssignment = SlotAssignment.load(slot: otherSlot)
        return otherAssignment.deviceName == deviceName
    }

    private func findDevice(id: UUID) -> SelectableDevice? {
        availableDevices.first { $0.id == id }
    }

    // MARK: - Persistence

    private func loadSettingsForCurrentType() {
        settings = DeviceTypeSettings.load(slot: slot, deviceType: assignment.deviceType)
    }

    private func saveAssignment() {
        appState.updateSlotAssignment(assignment, for: slot)
    }

    private func saveSettings() {
        settings.save(slot: slot, deviceType: assignment.deviceType)
        // Sync to InputSettings so changes take effect immediately
        appState.syncInputSettings()
    }
}

/// Routes to the appropriate settings view based on category
struct DeviceSettingsView: View {
    let slot: DeviceSlot
    let deviceType: ConfigurableDeviceType
    let category: SettingsCategory
    @Binding var settings: DeviceTypeSettings

    var body: some View {
        switch category {
        case .calibration:
            CalibrationSettingsView(slot: slot, deviceType: deviceType)
        case .pointer:
            PointerSettingsView(slot: slot, deviceType: deviceType, settings: $settings)
        case .stick:
            StickSettingsView(slot: slot, deviceType: deviceType, settings: $settings)
        case .buttons:
            ButtonsSettingsView(slot: slot, deviceType: deviceType, settings: $settings)
        }
    }
}

#Preview {
    NavigationStack {
        SlotConfigView(slot: .primary)
            .environmentObject(AppState())
    }
    .frame(width: 500, height: 600)
}
