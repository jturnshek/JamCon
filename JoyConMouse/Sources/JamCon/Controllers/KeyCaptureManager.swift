import AppKit
import Combine
import Carbon.HIToolbox
import CoreGraphics

/// Tracks which button is currently being configured for key capture
enum KeyCaptureState: Equatable {
    case idle
    case capturing(button: LogicalButton)
}

/// Manages keyboard event capture for button mapping configuration
/// Uses CGEventTap to intercept system shortcuts like Cmd+Space
@MainActor
class KeyCaptureManager: ObservableObject {
    @Published var captureState: KeyCaptureState = .idle
    @Published var currentModifiers: KeyModifiers = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Callback when a key combo is captured - provides the button and combo
    var onCapture: ((LogicalButton, KeyCombo) -> Void)?

    /// Start capturing keyboard input for a specific button
    func startCapture(for button: LogicalButton) {
        captureState = .capturing(button: button)
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
        if case .capturing(let b) = captureState {
            return b == button
        }
        return false
    }

    private func installEventTap() {
        removeEventTap()

        // Event mask for key down and modifier changes
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Create event tap at session level to intercept system shortcuts
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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

        guard case .capturing(let button) = captureState else {
            return Unmanaged.passRetained(event)  // Pass through if not capturing
        }

        // Extract modifiers from event flags
        let flags = event.flags
        var modifiers: KeyModifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }

        // Update modifiers display (needs main thread)
        Task { @MainActor in
            self.currentModifiers = modifiers
        }

        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            // Escape with no modifiers cancels capture
            if keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                Task { @MainActor in
                    self.cancelCapture()
                }
                return nil  // Consume the event
            }

            // Capture the key combo
            let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)

            Task { @MainActor in
                self.onCapture?(button, combo)
                self.removeEventTap()
                self.captureState = .idle
                self.currentModifiers = []
            }

            return nil  // Consume the event (prevents Spotlight from opening)
        }

        // For flagsChanged, just update display (don't complete capture)
        return nil  // Consume modifier-only events during capture
    }

    deinit {
        // Inline cleanup since deinit is nonisolated and can't call @MainActor methods
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
