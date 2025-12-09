import AppKit
import CoreGraphics

/// State for key capture
enum KeyCaptureState: Equatable {
    case idle
    case capturing(button: LogicalButton, isHold: Bool)
}

/// Manages keyboard event capture for button mapping configuration
/// Uses CGEventTap to intercept system shortcuts like Cmd+Space
@MainActor
class KeyCaptureManager: ObservableObject {
    @Published var captureState: KeyCaptureState = .idle
    @Published var currentModifiers: CGEventFlags = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Callback when a key combo is captured (button, combo, isHold)
    var onCapture: ((LogicalButton, KeyCombo, Bool) -> Void)?

    /// Start capturing keyboard input for a specific button
    /// - Parameters:
    ///   - button: The button to capture for
    ///   - isHold: Whether this is for the hold action (true) or press action (false)
    func startCapture(for button: LogicalButton, isHold: Bool = false) {
        captureState = .capturing(button: button, isHold: isHold)
        currentModifiers = []
        installEventTap()
    }

    /// Cancel the current capture session
    func cancelCapture() {
        removeEventTap()
        captureState = .idle
        currentModifiers = []
    }

    /// Check if currently capturing for a specific button
    func isCapturing(button: LogicalButton) -> Bool {
        if case .capturing(let b, _) = captureState {
            return b == button
        }
        return false
    }

    var isCapturing: Bool {
        if case .idle = captureState {
            return false
        }
        return true
    }

    /// Current modifiers display string
    var modifiersDisplay: String {
        var parts: [String] = []
        if currentModifiers.contains(.maskControl) { parts.append("⌃") }
        if currentModifiers.contains(.maskAlternate) { parts.append("⌥") }
        if currentModifiers.contains(.maskShift) { parts.append("⇧") }
        if currentModifiers.contains(.maskCommand) { parts.append("⌘") }
        return parts.isEmpty ? "Press a key..." : parts.joined() + "..."
    }

    private func installEventTap() {
        removeEventTap()

        // Event mask for key down and modifier changes
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Create event tap at HID level to catch arrows/shortcuts even when menus are focused
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<KeyCaptureManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[KeyCaptureManager] Failed to create event tap - check Accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled (system may disable if callback takes too long)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Check if we're capturing
        guard case .capturing(let button, let isHold) = captureState else {
            return Unmanaged.passRetained(event)
        }

        // Extract modifiers from event flags
        let flags = event.flags

        // Update modifiers display (needs main thread)
        Task { @MainActor in
            self.currentModifiers = flags
        }

        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            // Create the key combo with only modifier flags
            let modifierFlags = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
            let combo = KeyCombo(keyCode: keyCode, modifiers: modifierFlags)

            Task { @MainActor in
                self.onCapture?(button, combo, isHold)
                self.removeEventTap()
                self.captureState = .idle
                self.currentModifiers = []
            }

            return nil  // Consume the event
        }

        // For flagsChanged, just update display (don't complete capture)
        return nil  // Consume modifier-only events during capture
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
