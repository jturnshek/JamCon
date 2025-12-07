import SwiftUI

// MARK: - Joystick Tab

struct JoystickTab: View {
    @ObservedObject var appState: AppState
    private var isJoyCon: Bool { appState.activeControllerKind == .joyCon }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            if isJoyCon {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Joy-Con joystick configuration coming soon.")
                        .font(.headline)
                    Text("The Joy-Con stick will appear here with its own settings. For now, use the Debug tab to monitor raw stick bytes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                Spacer()
            } else {
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
                        Text("Acceleration < 1: more responsive at low deflection\nAcceleration > 1: more precision at low deflection, faster at full push")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}
