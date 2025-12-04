import SwiftUI

/// Pointer settings for a specific slot and device type
struct PointerSettingsView: View {
    @EnvironmentObject var appState: AppState
    let slot: DeviceSlot
    let deviceType: ConfigurableDeviceType
    @Binding var settings: DeviceTypeSettings

    var body: some View {
        Form {
            Section("Sensitivity") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $settings.pointerSensitivity, in: sensitivityRange)
                            .frame(width: 200)
                        Text(String(format: "%.0f", settings.pointerSensitivity))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent("Acceleration") {
                    HStack {
                        Slider(value: $settings.accelerationGain, in: 0...500)
                            .frame(width: 200)
                        Text(String(format: "%.1fx", 1.0 + settings.accelerationGain / 100))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                Text("Acceleration boosts speed for fast movements while leaving fine aim unchanged.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Smoothing") {
                LabeledContent("Jitter Filter") {
                    HStack {
                        Slider(value: $settings.smoothThreshold, in: 0...50)
                            .frame(width: 200)
                        Text(settings.smoothThreshold == 0 ? "Off" : String(format: "%.0f", settings.smoothThreshold))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Text("Higher values = smoother when moving slowly; too high can feel floaty.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Adaptive Mode", selection: $settings.adaptiveSmoothingMode) {
                    ForEach(AdaptiveSmoothingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Fine Tuning") {
                Toggle("Precision Zone", isOn: $settings.precisionZoneEnabled)
                Text("Slows cursor at low speeds for fine aiming")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Early Ramp", isOn: $settings.earlyRampEnabled)
                Text("Reaches top acceleration gain sooner")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LabeledContent("Filter Beta") {
                    HStack {
                        Slider(value: $settings.filterBeta, in: 0...1.0)
                            .frame(width: 200)
                        Text(String(format: "%.2f", settings.filterBeta))
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
        .onDisappear {
            settings.save(slot: slot, deviceType: deviceType)
            appState.syncInputSettings()
        }
    }

    /// Sensitivity range varies by device type
    private var sensitivityRange: ClosedRange<Double> {
        switch deviceType {
        case .leftJoyCon, .rightJoyCon, .proController:
            return 1...200
        case .dinostrike, .airMouseBasic:
            return 1...100  // Air mice may need different range
        }
    }
}

#Preview {
    NavigationStack {
        PointerSettingsView(
            slot: .primary,
            deviceType: .rightJoyCon,
            settings: .constant(DeviceTypeSettings())
        )
    }
    .frame(width: 500, height: 500)
}
