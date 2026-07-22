import SwiftUI

// MARK: - Joystick Tab

struct JoystickTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Enable Joystick Scroll", isOn: $appState.joystickScrollEnabled)

                HStack {
                    Text("Scroll Speed")
                    PreciseSlider(
                        value: $appState.joystickScrollSpeed,
                        range: 1...50,
                        step: 1,
                        fractionDigits: 0
                    )
                }
                .disabled(!appState.joystickScrollEnabled)

                HStack {
                    Text("Acceleration")
                    PreciseSlider(
                        value: $appState.joystickScrollAcceleration,
                        range: 0.2...5,
                        step: 0.1,
                        fractionDigits: 1
                    )
                }
                .disabled(!appState.joystickScrollEnabled)

                Button {
                    appState.resetJoystickSettings()
                } label: {
                    Label("Reset Joystick Scroll", systemImage: "arrow.counterclockwise")
                }
                .foregroundColor(.secondary)
            } footer: {
                Text("Applies to Sense and Joy-Con joysticks. Higher acceleration preserves more precision near the center while retaining full-speed scrolling.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Joystick")
    }
}
