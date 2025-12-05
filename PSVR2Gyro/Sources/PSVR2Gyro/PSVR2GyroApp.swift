import SwiftUI
import AppKit

@main
struct PSVR2GyroApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState) {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Image(systemName: appState.isConnected ? "gamecontroller.fill" : "gamecontroller")
        }
        .menuBarExtraStyle(.window)

        Window("PSVR2 Gyro Settings", id: "settings") {
            SettingsView(appState: appState)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
