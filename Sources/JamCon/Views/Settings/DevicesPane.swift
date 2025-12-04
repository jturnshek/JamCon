import SwiftUI
import AppKit

struct DevicesPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                // Device Slots (main navigation)
                Section("Device Slots") {
                    NavigationLink(value: DeviceSlot.primary) {
                        SlotRow(slot: .primary)
                    }

                    NavigationLink(value: DeviceSlot.secondary) {
                        SlotRow(slot: .secondary)
                    }
                }

                // Connected Devices (informational)
                Section("Connected Devices") {
                    if appState.connectedControllers.isEmpty && !hasConnectedAirMice {
                        Text("No devices connected")
                            .foregroundColor(.secondary)
                    } else {
                        // Joy-Cons
                        ForEach(appState.connectedControllers, id: \.id) { controller in
                            connectedDeviceRow(controller)
                        }

                        // Air Mice
                        if let deviceManager = appState.deviceManager {
                            ForEach(deviceManager.connectedDevices.filter { $0.deviceType.isMouse }, id: \.id) { device in
                                connectedAirMouseRow(device)
                            }
                        }
                    }
                }

                // Available USB Devices
                let usbDevices = appState.availableAirMice.filter { $0.isUSB }
                if !usbDevices.isEmpty {
                    Section("USB Devices") {
                        ForEach(usbDevices) { device in
                            availableDeviceRow(device)
                        }
                    }
                }

                // Available Bluetooth Devices
                let btDevices = appState.availableAirMice.filter { $0.isBluetooth }
                if !btDevices.isEmpty {
                    Section("Bluetooth Devices") {
                        ForEach(btDevices) { device in
                            availableDeviceRow(device)
                        }
                    }
                }

                // Other available devices (unknown transport)
                let otherDevices = appState.availableAirMice.filter { !$0.isUSB && !$0.isBluetooth }
                if !otherDevices.isEmpty {
                    Section("Other Devices") {
                        ForEach(otherDevices) { device in
                            availableDeviceRow(device)
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: DeviceSlot.self) { slot in
                SlotConfigView(slot: slot)
            }
        }
    }

    private var hasConnectedAirMice: Bool {
        appState.deviceManager?.connectedDevices.contains { $0.deviceType.isMouse } ?? false
    }

    // MARK: - Slot Row

    @ViewBuilder
    private func SlotRow(slot: DeviceSlot) -> some View {
        let assignment = SlotAssignment.load(slot: slot)
        let hasAssignment = assignment.deviceName != nil

        HStack {
            Image(systemName: slot == .primary ? "1.circle.fill" : "2.circle.fill")
                .font(.title2)
                .foregroundColor(hasAssignment ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.displayName)
                    .fontWeight(.medium)

                if let deviceName = assignment.deviceName {
                    HStack(spacing: 4) {
                        Image(systemName: assignment.deviceType.icon)
                            .font(.caption)
                        Text(deviceName)
                            .font(.caption)
                        Text("(\(assignment.deviceType.displayName))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.secondary)
                } else {
                    Text("Tap to configure")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Connected Device Rows

    private func connectedDeviceRow(_ controller: ConnectedController) -> some View {
        HStack {
            joyConIcon(type: controller.type, isConnected: true)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.name)

                let (batteryImage, batteryColor) = batteryIconInfo(for: controller.batteryLevel)
                HStack(spacing: 4) {
                    Image(systemName: batteryImage)
                        .font(.caption)
                        .foregroundColor(batteryColor)
                    Text(controller.batteryLevel.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            slotBadge(for: controller.name)
        }
    }

    private func connectedAirMouseRow(_ device: any InputDevice) -> some View {
        HStack {
            Image(systemName: "computermouse.fill")
                .foregroundColor(JamConColors.green)
                .frame(width: 24)

            Text(device.displayName)
                .lineLimit(1)

            Spacer()

            slotBadge(for: device.displayName)

            Menu {
                Button("Disconnect", role: .destructive) {
                    appState.deviceManager?.disconnectAirMouse(device.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    private func availableDeviceRow(_ device: AvailableDevice) -> some View {
        HStack {
            Image(systemName: "computermouse")
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(device.displayName)
                    .lineLimit(1)
                Text("\(device.interfaceCount) interface\(device.interfaceCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Connect") {
                appState.deviceManager?.connectAirMouse(device)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .foregroundColor(.secondary)
    }

    // MARK: - Helpers

    private func findDevice(id: UUID?) -> (any InputDevice)? {
        guard let id else { return nil }
        return appState.deviceManager?.connectedDevices.first { $0.id == id }
    }

    @ViewBuilder
    private func slotBadge(for deviceName: String) -> some View {
        let primaryAssignment = SlotAssignment.load(slot: .primary)
        let secondaryAssignment = SlotAssignment.load(slot: .secondary)

        if primaryAssignment.deviceName == deviceName {
            OutlineBadge("Primary", color: JamConColors.green)
        } else if secondaryAssignment.deviceName == deviceName {
            OutlineBadge("Secondary", color: JamConColors.blue)
        }
    }

    @ViewBuilder
    private func joyConIcon(type: ControllerType, isConnected: Bool) -> some View {
        let imageName = type == .leftJoyCon ? "joyconR" : "joyconL"

        if let nsImage = loadJoyConImage(imageName) {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 17)
                .rotationEffect(.degrees(-90))
                .foregroundColor(isConnected ? JamConColors.green : .secondary)
                .opacity(isConnected ? 1.0 : JamConColors.disabledOpacity)
        } else {
            Image(systemName: "gamecontroller")
                .foregroundColor(isConnected ? JamConColors.green : .secondary)
                .opacity(isConnected ? 1.0 : JamConColors.disabledOpacity)
        }
    }

    private func loadJoyConImage(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    private func batteryIconInfo(for level: BatteryLevel) -> (String, Color) {
        switch level {
        case .full:
            return ("battery.100", JamConColors.green)
        case .medium:
            return ("battery.75", JamConColors.green)
        case .low:
            return ("battery.25", JamConColors.yellow)
        case .critical, .empty:
            return ("battery.0", JamConColors.red)
        case .unknown:
            return ("battery.0", .secondary)
        }
    }
}

#Preview {
    DevicesPane()
        .environmentObject(AppState())
        .frame(width: 500, height: 500)
}
