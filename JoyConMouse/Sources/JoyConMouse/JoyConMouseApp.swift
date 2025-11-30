import SwiftUI
import AppKit

@main
struct JoyConMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("JoyConMouse", systemImage: appState.isConnected ? "gamecontroller.fill" : "gamecontroller")
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock (LSUIElement should handle this, but just in case)
        NSApp.setActivationPolicy(.accessory)
    }
}
