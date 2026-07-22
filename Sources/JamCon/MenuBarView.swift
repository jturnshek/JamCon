import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    let openSettings: () -> Void

    var body: some View {
        Group {
            if appState.isConnected {
                Text(appState.controllerName)
                if appState.batteryLevel > 0 {
                    Text("Battery: \(appState.batteryLevel)%")
                }
            } else {
                Text(appState.controllerName)
            }

            Divider()

            Toggle(isOn: $appState.isEnabled) {
                Label(
                    appState.isEnabled ? "JamCon Enabled" : "JamCon Paused",
                    systemImage: appState.isEnabled ? "play.fill" : "pause.fill"
                )
            }

            if !appState.hasAccessibilityPermission {
                Button {
                    appState.openAccessibilitySettings()
                } label: {
                    Label("Grant Accessibility Access…", systemImage: "exclamationmark.triangle")
                }

                Divider()
            }

            Button("Settings…", action: openSettings)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            appState.checkAccessibilityPermission()
        }
    }
}
