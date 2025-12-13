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
                    Slider(value: $appState.joystickScrollSpeed, in: 1...50, step: 1)
                    Text(String(format: "%.0f", appState.joystickScrollSpeed))
                        .frame(width: 30)
                }
                .disabled(!appState.joystickScrollEnabled)

                HStack {
                    Text("Acceleration")
                    Slider(value: $appState.joystickScrollAcceleration, in: 0.2...5.0, step: 0.1)
                    Text(String(format: "%.1f", appState.joystickScrollAcceleration))
                        .frame(width: 30)
                }
                .disabled(!appState.joystickScrollEnabled)
            } footer: {
                Text("Applies to controller joysticks (Sense/Joy-Con). USB mice are not affected.\n\nAcceleration < 1: more responsive at low deflection\nAcceleration > 1: more precision at low deflection, faster at full push")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Joystick")
    }
}
