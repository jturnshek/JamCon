import SwiftUI

// MARK: - Settings View

/// Main settings window with tabbed interface
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: AppState.ActiveTab = .controller

    var body: some View {
        TabView(selection: $selectedTab) {
            ControllerTab(appState: appState)
                .tabItem {
                    Label("Controller", systemImage: "gamecontroller")
                }
                .tag(AppState.ActiveTab.controller)

            MouseControlTab(appState: appState)
                .tabItem {
                    Label("Mouse", systemImage: "computermouse")
                }
                .tag(AppState.ActiveTab.mouse)

            ButtonsTab(appState: appState)
                .tabItem {
                    Label("Buttons", systemImage: "circle.grid.3x3")
                }
                .tag(AppState.ActiveTab.buttons)

            JoystickTab(appState: appState)
                .tabItem {
                    Label("Joystick", systemImage: "l.joystick")
                }
                .tag(AppState.ActiveTab.joystick)

            RadialMenuTab(appState: appState)
                .tabItem {
                    Label("Radial", systemImage: "circle.hexagongrid")
                }
                .tag(AppState.ActiveTab.radial)

            DebugTab(appState: appState)
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }
                .tag(AppState.ActiveTab.debug)

            LogTab(appState: appState)
                .tabItem {
                    Label("Log", systemImage: "doc.text")
                }
                .tag(AppState.ActiveTab.log)
        }
        .frame(minWidth: 500, minHeight: 450)
        .onChange(of: selectedTab) { _, newTab in
            appState.activeTab = newTab
        }
        .onAppear {
            appState.activeTab = selectedTab
        }
    }
}
