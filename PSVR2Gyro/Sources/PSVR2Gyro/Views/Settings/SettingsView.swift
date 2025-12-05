import SwiftUI

// MARK: - Settings View

/// Main settings window with tabbed interface
struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            ControllerTab(appState: appState)
                .tabItem {
                    Label("Controller", systemImage: "gamecontroller")
                }

            MouseControlTab(appState: appState)
                .tabItem {
                    Label("Mouse", systemImage: "computermouse")
                }

            ButtonsTab(appState: appState)
                .tabItem {
                    Label("Buttons", systemImage: "circle.grid.3x3")
                }

            StickTab(appState: appState)
                .tabItem {
                    Label("Stick", systemImage: "l.joystick")
                }

            DebugTab(appState: appState)
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }

            LogTab(appState: appState)
                .tabItem {
                    Label("Log", systemImage: "doc.text")
                }
        }
        .frame(minWidth: 500, minHeight: 450)
    }
}
