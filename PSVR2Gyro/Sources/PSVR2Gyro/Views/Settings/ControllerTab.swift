import SwiftUI

// MARK: - Controller Tab

struct ControllerTab: View {
    @ObservedObject var appState: AppState

    private var batteryLevel: Int {
        BatteryHelper.level(from: appState.safeReportByte(PSVR2HIDProtocol.Offset.battery))
    }

    var body: some View {
        Form {
            Section {
                if appState.availableControllers.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("No PSVR2 controllers found")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)

                    Text("Press the PlayStation button on your controller to connect via Bluetooth.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.availableControllers) { controller in
                        ControllerRow(
                            controller: controller,
                            isSelected: controller.id == appState.selectedControllerID,
                            onSelect: {
                                appState.selectController(id: controller.id)
                            }
                        )
                    }
                }
            } header: {
                Text("Available Controllers")
            } footer: {
                if !appState.availableControllers.isEmpty {
                    Text("Select the controller to use for gyro mouse control.")
                }
            }

            Section("Status") {
                LabeledContent("Connection") {
                    ConnectionIndicator(isConnected: appState.isConnected)
                }

                if appState.isConnected {
                    LabeledContent("Active Controller") {
                        Text(appState.controllerName)
                    }

                    LabeledContent("Battery") {
                        BatteryIndicatorWithBar(level: batteryLevel)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ControllerRow: View {
    let controller: DiscoveredController
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: controller.isLeft ? "l.joystick" : "r.joystick")
                        .foregroundColor(.blue)
                    Text(controller.side)
                        .font(.headline)
                }
                Text(controller.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else {
                Button("Select") {
                    onSelect()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isSelected {
                onSelect()
            }
        }
    }
}
