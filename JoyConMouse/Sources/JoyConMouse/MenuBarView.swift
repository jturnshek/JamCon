import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with connection status
            headerSection

            Divider()

            // Enable/Disable toggle
            toggleSection

            Divider()

            // Sensitivity settings
            sensitivitySection

            Divider()

            // Stabilization settings
            stabilizationSection

            Divider()

            // Button mapping
            buttonMappingSection

            Divider()

            // Footer with accessibility and quit
            footerSection
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.connectedControllers.isEmpty {
                // No controllers connected
                HStack {
                    Image(systemName: "gamecontroller")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Controller")
                            .font(.headline)
                        Text("Pair via Bluetooth Settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            } else {
                // Show all connected controllers
                ForEach(appState.connectedControllers) { controller in
                    controllerRow(controller)
                }
            }
        }
    }

    private func controllerRow(_ controller: ConnectedController) -> some View {
        let isPrimary = controller.id == appState.primaryController?.id
        let (batteryImage, batteryColor) = batteryIconInfo(for: controller.batteryLevel)

        return HStack {
            Image(systemName: isPrimary ? "gamecontroller.fill" : "gamecontroller")
                .font(.title2)
                .foregroundColor(isPrimary ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(controller.type.rawValue)
                        .font(.headline)
                    if isPrimary {
                        Text("Primary")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(3)
                    }
                }

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

            // Set as primary button (only show if not already primary and multiple controllers)
            if !isPrimary && appState.connectedControllers.count > 1 {
                Button(action: { appState.setPrimaryController(controller) }) {
                    Text("Set Primary")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func batteryIconInfo(for level: BatteryLevel) -> (String, Color) {
        switch level {
        case .full:
            return ("battery.100", .green)
        case .medium:
            return ("battery.75", .green)
        case .low:
            return ("battery.25", .yellow)
        case .critical, .empty:
            return ("battery.0", .red)
        case .unknown:
            return ("battery.0", .secondary)
        }
    }

    // MARK: - Toggle Section

    private var toggleSection: some View {
        Toggle(isOn: $appState.isEnabled) {
            HStack {
                Image(systemName: appState.isEnabled ? "cursorarrow.motionlines" : "cursorarrow")
                Text("Mouse Control")
            }
        }
        .toggleStyle(.switch)
        .disabled(!appState.isConnected)
    }

    // MARK: - Sensitivity Section

    private var sensitivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sensitivity")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Mouse sensitivity
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mouse")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f", appState.gyroSensitivity))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Slider(value: $appState.gyroSensitivity, in: 1...50, step: 1)
            }

            // Scroll sensitivity
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Scroll")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f", appState.scrollSensitivity))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Slider(value: $appState.scrollSensitivity, in: 1...20, step: 1)
            }
        }
    }

    // MARK: - Stabilization Section

    private var stabilizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stabilization")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Smoothing threshold
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Smoothing")
                        .font(.caption)
                    Spacer()
                    Text(appState.smoothThreshold == 0 ? "Off" : String(format: "%.0f", appState.smoothThreshold))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Slider(value: $appState.smoothThreshold, in: 0...20, step: 1)
            }

            // Calibration status and button
            HStack {
                // Status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.isGyroCalibrated ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(appState.isGyroCalibrated ? "Calibrated" : "Calibrating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Recalibrate button
                Button(action: appState.resetGyroCalibration) {
                    Text("Recalibrate")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appState.isConnected)
            }

            Text("Hold controller still to calibrate")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Button Mapping Section

    private var buttonMappingSection: some View {
        Button(action: { openWindow(id: "button-mapping") }) {
            HStack {
                Image(systemName: "keyboard")
                Text("Configure Buttons...")
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(spacing: 8) {
            // Accessibility settings button
            Button(action: appState.openAccessibilitySettings) {
                HStack {
                    Image(systemName: "hand.raised")
                    Text("Accessibility Settings")
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)

            Divider()

            // Quit button
            Button(action: appState.quit) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit JoyConMouse")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
