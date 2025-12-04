import SwiftUI

/// Calibration settings for a specific slot and device type
struct CalibrationSettingsView: View {
    @EnvironmentObject var appState: AppState
    let slot: DeviceSlot
    let deviceType: ConfigurableDeviceType

    var body: some View {
        Form {
            Section("Gyro Calibration") {
                HStack {
                    Circle()
                        .fill(appState.isGyroCalibrated ? Color.green : Color.orange)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.isGyroCalibrated ? "Calibrated" : "Calibrating...")
                            .fontWeight(.medium)
                        Text("Hold controller still during calibration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Recalibrate") {
                        appState.resetGyroCalibration()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.isConnected)
                }

                Text("Gyro calibration compensates for sensor drift. Recalibrate if the cursor moves when the controller is stationary.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("About \(deviceType.displayName) Calibration") {
                switch deviceType {
                case .leftJoyCon, .rightJoyCon, .proController:
                    Label {
                        Text("Joy-Cons use gyroscope sensors that require calibration for accurate pointer control. The calibration process measures sensor bias when the controller is stationary.")
                    } icon: {
                        Image(systemName: "gamecontroller")
                            .foregroundColor(JamConColors.green)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                case .dinostrike, .airMouseBasic:
                    Label {
                        Text("Most air mice have built-in calibration and typically don't require manual recalibration. If you experience drift, try the recalibrate button above.")
                    } icon: {
                        Image(systemName: "computermouse")
                            .foregroundColor(JamConColors.blue)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calibration")
    }
}

#Preview {
    NavigationStack {
        CalibrationSettingsView(slot: .primary, deviceType: .rightJoyCon)
            .environmentObject(AppState())
    }
    .frame(width: 500, height: 400)
}
