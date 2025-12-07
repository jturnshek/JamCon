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
        Window("PSVR2 Gyro Settings", id: "settings") {
            SettingsView(appState: appState)
                .onAppear {
                    // Start engine AFTER SwiftUI is fully initialized
                    // This prevents crashes during app startup
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        await MainActor.run {
                            appState.startEngine()
                        }
                    }
                }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            if appState.isConnected {
                Text(appState.controllerName)
                if appState.batteryLevel > 0 {
                    Text("Battery: \(appState.batteryLevel)%")
                }
            } else {
                Text("No controller selected")
            }

            Divider()

            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "rotate.3d")
        }
    }
}
