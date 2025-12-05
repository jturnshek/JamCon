import Foundation
import CoreGraphics
import AppKit

/// Executes button actions (mouse clicks, key presses, system actions)
class ActionExecutor {

    static let shared = ActionExecutor()

    private init() {}

    // MARK: - Execute Action

    func execute(_ action: ButtonAction, isPressed: Bool) {
        switch action {
        case .none, .drag, .scroll:
            // No-op: drag/scroll are handled by AppState gyro routing
            break
        case .mouseClick(let button):
            if isPressed {
                performMouseDown(button)
            } else {
                performMouseUp(button)
            }
        case .keyPress(let combo):
            if isPressed {
                performKeyDown(combo)
            } else {
                performKeyUp(combo)
            }
        case .systemAction(let action):
            if isPressed {
                performSystemAction(action)
            }
        }
    }

    // MARK: - Mouse Actions

    private func performMouseDown(_ button: MouseButton) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let eventType: CGEventType
        let mouseButton: CGMouseButton

        switch button {
        case .left:
            eventType = .leftMouseDown
            mouseButton = .left
        case .right:
            eventType = .rightMouseDown
            mouseButton = .right
        case .middle:
            eventType = .otherMouseDown
            mouseButton = .center
        }

        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: location, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performMouseUp(_ button: MouseButton) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let eventType: CGEventType
        let mouseButton: CGMouseButton

        switch button {
        case .left:
            eventType = .leftMouseUp
            mouseButton = .left
        case .right:
            eventType = .rightMouseUp
            mouseButton = .right
        case .middle:
            eventType = .otherMouseUp
            mouseButton = .center
        }

        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: location, mouseButton: mouseButton) {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard Actions

    private func performKeyDown(_ combo: KeyCombo) {
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: true) {
            event.flags = combo.eventFlags
            event.post(tap: .cghidEventTap)
        }
    }

    private func performKeyUp(_ combo: KeyCombo) {
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: false) {
            event.flags = combo.eventFlags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System Actions

    private func performSystemAction(_ action: SystemAction) {
        switch action {
        case .missionControl:
            openMissionControl()
        case .launchpad:
            openLaunchpad()
        case .showDesktop:
            showDesktop()
        case .appSwitcher:
            openAppSwitcher()
        case .playPause:
            sendMediaKey(.playPause)
        }
    }

    private func openMissionControl() {
        // F3 key (key code 99) or Control+Up
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 160, keyDown: true) {
            event.post(tap: .cghidEventTap)
        }
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 160, keyDown: false) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func openLaunchpad() {
        // Open Launchpad via its app bundle
        if let launchpadURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.launchpad.launcher") {
            NSWorkspace.shared.openApplication(at: launchpadURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func showDesktop() {
        // F11 key (key code 103) - Show Desktop
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 103, keyDown: true) {
            event.flags = .maskSecondaryFn
            event.post(tap: .cghidEventTap)
        }
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 103, keyDown: false) {
            event.flags = .maskSecondaryFn
            event.post(tap: .cghidEventTap)
        }
    }

    private func openAppSwitcher() {
        // Command+Tab
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true) {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: false) {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Media Keys

    enum MediaKey: UInt32 {
        case playPause = 16
        case next = 17
        case previous = 18
        case volumeUp = 0
        case volumeDown = 1
        case mute = 7
    }

    private func sendMediaKey(_ key: MediaKey) {
        // Use NX_KEYTYPE constants for media keys
        let keyCode = key.rawValue

        // Key down
        let downEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xa << 8)),
            data2: -1
        )
        downEvent?.cgEvent?.post(tap: .cghidEventTap)

        // Key up
        let upEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xb << 8)),
            data2: -1
        )
        upEvent?.cgEvent?.post(tap: .cghidEventTap)
    }
}
