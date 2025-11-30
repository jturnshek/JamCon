import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

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

            // Footer with accessibility and quit
            footerSection
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            Image(systemName: appState.isConnected ? "gamecontroller.fill" : "gamecontroller")
                .font(.title2)
                .foregroundColor(appState.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.isConnected ? appState.controllerType.rawValue : "No Controller")
                    .font(.headline)

                if appState.isConnected {
                    HStack(spacing: 4) {
                        batteryIcon
                        Text(appState.batteryLevel.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Pair via Bluetooth Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    private var batteryIcon: some View {
        let (imageName, color) = batteryIconInfo
        return Image(systemName: imageName)
            .font(.caption)
            .foregroundColor(color)
    }

    private var batteryIconInfo: (String, Color) {
        switch appState.batteryLevel {
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
