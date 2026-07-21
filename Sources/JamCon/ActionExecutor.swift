import Foundation
import CoreGraphics
import AppKit

final class MacOSSyntheticEventBackend: SyntheticEventBackend {
    private let mouseController: MouseController

    init(mouseController: MouseController) {
        self.mouseController = mouseController
    }

    func post(_ event: SyntheticOutputEvent) {
        switch event {
        case .mouseButton(let button, let isPressed):
            if isPressed {
                mouseController.mouseDown(button: button)
            } else {
                mouseController.mouseUp(button: button)
            }

        case .key(let combo, let isPressed):
            var flags = combo.eventFlags
            let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
            if arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskNumericPad)
            }
            if flags.contains(.maskControl), arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskSecondaryFn)
            }

            if let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(combo.keyCode),
                keyDown: isPressed
            ) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
    }
}

/// Executes button actions (mouse clicks, key presses, system actions)
class ActionExecutor {
    private let outputCoordinator: SyntheticOutputCoordinator

    init(mouseController: MouseController) {
        self.outputCoordinator = SyntheticOutputCoordinator(
            backend: MacOSSyntheticEventBackend(mouseController: mouseController)
        )
    }

    init(eventBackend: SyntheticEventBackend) {
        self.outputCoordinator = SyntheticOutputCoordinator(backend: eventBackend)
    }

    // MARK: - Execute Action

    func execute(_ action: ButtonAction, isPressed: Bool, owner: SyntheticOutputOwner) {
        switch action {
        case .none, .drag, .scroll, .radialMenu:
            // No-op: drag/scroll/radialMenu are handled by AppState gyro routing
            break
        case .mouseClick(let button):
            outputCoordinator.set(.mouseButton(button), pressed: isPressed, owner: owner)
        case .keyPress(let combo):
            outputCoordinator.set(.key(combo), pressed: isPressed, owner: owner)
        case .systemAction(let action):
            if isPressed {
                performSystemAction(action, owner: owner)
            }
        }
    }

    func tap(_ action: ButtonAction, owner: SyntheticOutputOwner) {
        switch action {
        case .mouseClick(let button):
            outputCoordinator.tap(.mouseButton(button), owner: owner)
        case .keyPress(let combo):
            outputCoordinator.tap(.key(combo), owner: owner)
        case .systemAction(let systemAction):
            performSystemAction(systemAction, owner: owner)
        case .none, .drag, .scroll, .radialMenu:
            break
        }
    }

    func executeSystemAction(_ action: SystemAction, owner: SyntheticOutputOwner) {
        performSystemAction(action, owner: owner)
    }

    /// Release every synthetic down event still owned by JamCon.
    /// Call this before stopping input, disabling output, or losing a device.
    func releaseAll() {
        outputCoordinator.releaseAll()
    }

    func releaseAll(for device: ManagedDeviceKey) {
        outputCoordinator.releaseAll(for: device)
    }

    // MARK: - System Actions

    private func performSystemAction(_ action: SystemAction, owner: SyntheticOutputOwner) {
        switch action {
        case .missionControl:
            outputCoordinator.tap(
                .key(KeyCombo(keyCode: 126, modifiers: .maskControl)),
                owner: owner.withRole(.systemAction, control: SystemAction.missionControl.rawValue)
            )
        case .launchpad:
            openLaunchpad()
        case .showDesktop:
            outputCoordinator.tap(
                .key(KeyCombo(keyCode: 103, modifiers: .maskSecondaryFn)),
                owner: owner.withRole(.systemAction, control: SystemAction.showDesktop.rawValue)
            )
        case .appSwitcher:
            outputCoordinator.tap(
                .key(KeyCombo(keyCode: 48, modifiers: .maskCommand)),
                owner: owner.withRole(.systemAction, control: SystemAction.appSwitcher.rawValue)
            )
        case .playPause:
            sendMediaKey(.playPause)
        }
    }

    private func openLaunchpad() {
        // Open Launchpad via its app bundle
        Task { @MainActor in
            if let launchpadURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.launchpad.launcher") {
                NSWorkspace.shared.openApplication(at: launchpadURL, configuration: NSWorkspace.OpenConfiguration())
            }
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
        Task { @MainActor in
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
}
