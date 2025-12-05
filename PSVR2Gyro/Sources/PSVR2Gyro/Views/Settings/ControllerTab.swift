import SwiftUI

// MARK: - Controller Tab

struct ControllerTab: View {
    @ObservedObject var appState: AppState

    private func batteryColor(for level: Int) -> Color {
        if level > 50 { return .green }
        if level > 20 { return .yellow }
        return .red
    }

    private func batteryIcon(for level: Int) -> String {
        if level >= 75 { return "battery.100" }
        if level >= 50 { return "battery.75" }
        if level >= 25 { return "battery.50" }
        if level > 0 { return "battery.25" }
        return "battery.0"
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
                    HStack {
                        Circle()
                            .fill(appState.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                    }
                }

                if appState.isConnected {
                    LabeledContent("Active Controller") {
                        Text(appState.controllerName)
                    }

                    LabeledContent("Battery") {
                        HStack(spacing: 6) {
                            let level = Int(appState.safeReportByte(43) & 0x0F) * 10
                            Image(systemName: batteryIcon(for: level))
                                .foregroundColor(batteryColor(for: level))
                            Text("\(level)%")
                                .font(.system(.body, design: .monospaced))

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(batteryColor(for: level))
                                        .frame(width: geo.size.width * CGFloat(level) / 100.0)
                                }
                            }
                            .frame(width: 60, height: 12)
                        }
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
