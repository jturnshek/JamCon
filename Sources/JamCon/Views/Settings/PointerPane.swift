import SwiftUI

struct PointerPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.isEnabled) {
                    HStack {
                        Image(systemName: appState.isEnabled ? "cursorarrow.motionlines" : "cursorarrow")
                        Text("Mouse Control")
                    }
                }
                .toggleStyle(.switch)
                .disabled(!appState.isConnected)
            }

            Section("Sensitivity") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $appState.gyroSensitivity, in: 1...200)
                            .frame(width: 200)
                        Text(String(format: "%.0f", appState.gyroSensitivity))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent("Acceleration") {
                    HStack {
                        Slider(value: $appState.accelerationGain, in: 0...500)
                            .frame(width: 200)
                        Text(String(format: "%.1fx", 1.0 + appState.accelerationGain))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                Text("Acceleration boosts speed for fast wrist flicks while leaving fine aim unchanged.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Smoothing") {
                LabeledContent("Jitter Filter") {
                    HStack {
                        Slider(value: $appState.smoothThreshold, in: 0...50)
                            .frame(width: 200)
                        Text(appState.smoothThreshold == 0 ? "Off" : String(format: "%.0f", appState.smoothThreshold))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Text("Higher values = smoother when moving slowly; too high can feel floaty.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Adaptive Mode", selection: $appState.adaptiveSmoothingMode) {
                    ForEach(AdaptiveSmoothingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Fine Tuning") {
                Toggle("Precision Zone", isOn: $appState.precisionZoneEnabled)
                Text("Slows cursor at low speeds for fine aiming")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Early Ramp", isOn: $appState.earlyRampEnabled)
                Text("Reaches top acceleration gain sooner")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LabeledContent("Filter Beta") {
                    HStack {
                        Slider(value: $appState.filterBeta, in: 0...1.0)
                            .frame(width: 200)
                        Text(String(format: "%.2f", appState.filterBeta))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                Text("Higher = drops smoothing sooner during motion; lower = steadier but can add lag.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pointer")
    }
}

#Preview {
    PointerPane()
        .environmentObject(AppState())
        .frame(width: 500, height: 500)
}
