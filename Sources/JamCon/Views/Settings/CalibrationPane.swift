import SwiftUI

struct CalibrationPane: View {
    @EnvironmentObject var appState: AppState

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

            Section("Device Notes") {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Joy-Cons require gyro calibration for accurate pointer control.")
                    } icon: {
                        Image(systemName: "gamecontroller")
                            .foregroundColor(JamConColors.green)
                    }

                    Label {
                        Text("Air mice typically have built-in calibration and may not need manual recalibration.")
                    } icon: {
                        Image(systemName: "computermouse")
                            .foregroundColor(JamConColors.blue)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calibration")
    }
}

#Preview {
    CalibrationPane()
        .environmentObject(AppState())
        .frame(width: 500, height: 400)
}
