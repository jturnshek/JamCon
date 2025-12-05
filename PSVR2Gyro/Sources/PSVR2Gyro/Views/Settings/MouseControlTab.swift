import SwiftUI

// MARK: - Mouse Control Tab

struct MouseControlTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Enable Mouse Control", isOn: $appState.isEnabled)
            }

            Section("Sensitivity") {
                LabeledContent("Sensitivity") {
                    HStack {
                        Slider(value: $appState.sensitivity, in: 1...50)
                            .frame(width: 200)
                        Text("\(Int(appState.sensitivity))")
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }

                LabeledContent("Gyro Scale") {
                    HStack {
                        Slider(value: $appState.gyroScale, in: 0.001...0.5)
                            .frame(width: 200)
                        Text(String(format: "%.4f", appState.gyroScale))
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
            }

            Section("Gyro Axis Offsets (Bytes)") {
                Stepper("X Offset: \(appState.gyroOffsetX)", value: $appState.gyroOffsetX, in: 0...70)
                Stepper("Y Offset: \(appState.gyroOffsetY)", value: $appState.gyroOffsetY, in: 0...70)
                Stepper("Z Offset: \(appState.gyroOffsetZ)", value: $appState.gyroOffsetZ, in: 0...70)
            }

            Section("Debug") {
                LabeledContent("Gyro X") {
                    Text("\(appState.lastGyroX)")
                        .monospacedDigit()
                }
                LabeledContent("Gyro Y") {
                    Text("\(appState.lastGyroY)")
                        .monospacedDigit()
                }
                LabeledContent("Gyro Z") {
                    Text("\(appState.lastGyroZ)")
                        .monospacedDigit()
                }
                LabeledContent("Report Count") {
                    Text("\(appState.reportCount)")
                        .monospacedDigit()
                }

                Button("Recalibrate") {
                    appState.recalibrate()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
