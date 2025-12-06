import SwiftUI
import AppKit

@main
struct PSVR2GyroApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Install crash reporter to log crashes to ~/Library/Logs/PSVR2Gyro/crash.log
        CrashReporter.install()

        // Check for previous crash and log it
        if let previousCrash = CrashReporter.checkForPreviousCrash() {
            print("Previous crash detected:\n\(previousCrash)")
        }
    }

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
