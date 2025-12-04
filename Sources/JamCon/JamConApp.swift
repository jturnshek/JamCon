import SwiftUI
import AppKit

@main
struct JamConApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar (simplified status + quick controls)
        MenuBarExtra {
            CompactMenuView()
                .environmentObject(appState)
        } label: {
            MenuBarIcon(
                leftConnected: appState.connectedControllers.contains { $0.type == .leftJoyCon },
                rightConnected: appState.connectedControllers.contains { $0.type == .rightJoyCon || $0.type == .proController }
            )
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Window("JamCon Settings", id: "settings") {
            SettingsContainer()
                .environmentObject(appState)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 500)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Menu bar icon showing Joy-Con connection status
struct MenuBarIcon: View {
    let leftConnected: Bool
    let rightConnected: Bool

    var body: some View {
        Image(nsImage: MenuBarIconCache.shared.icon(leftConnected: leftConnected, rightConnected: rightConnected))
    }
}

/// Pre-rendered menu bar icons for all connection states
class MenuBarIconCache {
    static let shared = MenuBarIconCache()

    // Four permutations
    private let noneConnected: NSImage
    private let leftOnly: NSImage
    private let rightOnly: NSImage
    private let bothConnected: NSImage

    private init() {
        // Menu bar icons should be ~18pt tall
        let iconHeight: CGFloat = 18
        // Original aspect ratio: 39w x 92h
        let iconWidth: CGFloat = iconHeight * (39.0 / 92.0)
        let spacing: CGFloat = 2

        let leftImage = Self.loadImage("joyconL")
        let rightImage = Self.loadImage("joyconR")

        // Use theme disabled opacity for disconnected state
        let disconnectedOpacity = JamConColors.disabledOpacity

        noneConnected = Self.createCombined(leftImage: leftImage, rightImage: rightImage,
                                            leftOpacity: disconnectedOpacity, rightOpacity: disconnectedOpacity,
                                            iconWidth: iconWidth, iconHeight: iconHeight, spacing: spacing)
        leftOnly = Self.createCombined(leftImage: leftImage, rightImage: rightImage,
                                       leftOpacity: 1.0, rightOpacity: disconnectedOpacity,
                                       iconWidth: iconWidth, iconHeight: iconHeight, spacing: spacing)
        rightOnly = Self.createCombined(leftImage: leftImage, rightImage: rightImage,
                                        leftOpacity: disconnectedOpacity, rightOpacity: 1.0,
                                        iconWidth: iconWidth, iconHeight: iconHeight, spacing: spacing)
        bothConnected = Self.createCombined(leftImage: leftImage, rightImage: rightImage,
                                            leftOpacity: 1.0, rightOpacity: 1.0,
                                            iconWidth: iconWidth, iconHeight: iconHeight, spacing: spacing)
    }

    func icon(leftConnected: Bool, rightConnected: Bool) -> NSImage {
        switch (leftConnected, rightConnected) {
        case (false, false): return noneConnected
        case (true, false): return leftOnly
        case (false, true): return rightOnly
        case (true, true): return bothConnected
        }
    }

    private static func loadImage(_ name: String) -> NSImage? {
        // Try SPM bundle first, fall back to main bundle for Xcode builds
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        #endif
        // For Xcode builds, resources are in the main bundle
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    private static func createCombined(leftImage: NSImage?, rightImage: NSImage?,
                                       leftOpacity: CGFloat, rightOpacity: CGFloat,
                                       iconWidth: CGFloat, iconHeight: CGFloat, spacing: CGFloat) -> NSImage {
        let totalWidth = iconWidth * 2 + spacing
        let combinedSize = NSSize(width: totalWidth, height: iconHeight)

        let combinedImage = NSImage(size: combinedSize)
        combinedImage.lockFocus()

        // Draw left Joy-Con
        if let leftImage = leftImage {
            let leftRect = NSRect(x: 0, y: 0, width: iconWidth, height: iconHeight)
            leftImage.draw(in: leftRect,
                          from: NSRect(origin: .zero, size: leftImage.size),
                          operation: .sourceOver,
                          fraction: leftOpacity)
        }

        // Draw right Joy-Con
        if let rightImage = rightImage {
            let rightRect = NSRect(x: iconWidth + spacing, y: 0, width: iconWidth, height: iconHeight)
            rightImage.draw(in: rightRect,
                           from: NSRect(origin: .zero, size: rightImage.size),
                           operation: .sourceOver,
                           fraction: rightOpacity)
        }

        combinedImage.unlockFocus()
        combinedImage.isTemplate = true

        return combinedImage
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock (LSUIElement should handle this, but just in case)
        NSApp.setActivationPolicy(.accessory)
    }
}
