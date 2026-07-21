import SwiftUI
import AppKit

@main
struct JamConApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // Check for previous crash and log it
        if let previousCrash = CrashReporter.checkForPreviousCrash() {
            JamLog.error(.app, "Previous crash detected:\n\(previousCrash)")
        }

        // Install crash reporter to log crashes to ~/Library/Logs/JamCon/crash.log
        CrashReporter.install()
    }

    var body: some Scene {
        Window("JamCon Settings", id: "settings") {
            SettingsView(appState: appState)
                .onAppear {
                    guard !Self.isRunningTests else { return }
                    // Start engine AFTER SwiftUI is fully initialized
                    // This prevents crashes during app startup
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        await MainActor.run {
                            appState.startEngine()
                        }
                    }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    appState.prepareForSystemSleep()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    appState.resumeAfterSystemWake()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.stopEngine()
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
