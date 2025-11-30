import AppKit
import Combine
import Carbon.HIToolbox

/// Tracks which button is currently being configured for key capture
enum KeyCaptureState: Equatable {
    case idle
    case capturing(button: LogicalButton)
}

/// Manages keyboard event capture for button mapping configuration
@MainActor
class KeyCaptureManager: ObservableObject {
    @Published var captureState: KeyCaptureState = .idle
    @Published var currentModifiers: KeyModifiers = []

    private var localMonitor: Any?
    private var globalMonitor: Any?  // For capturing system shortcuts like Cmd+Space

    /// Callback when a key combo is captured - provides the button and combo
    var onCapture: ((LogicalButton, KeyCombo) -> Void)?

    /// Start capturing keyboard input for a specific button
    func startCapture(for button: LogicalButton) {
        captureState = .capturing(button: button)
        currentModifiers = []
        installMonitor()
    }

    /// Cancel the current capture session
    func cancelCapture() {
        removeMonitor()
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

    private func installMonitor() {
        removeMonitor()

        // Local monitor for app-focused events (can consume events)
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyEvent(event)
        }

        // Global monitor for system-wide events (captures system shortcuts like Cmd+Space)
        // Note: Global monitor callback returns Void, can't consume events
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            _ = self?.handleKeyEvent(event)
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard case .capturing(let button) = captureState else {
            return event  // Pass through if not capturing
        }

        // Update current modifiers for display
        currentModifiers = KeyModifiers.from(event.modifierFlags)

        if event.type == .keyDown {
            // Escape with no modifiers cancels capture
            if event.keyCode == UInt16(kVK_Escape) && currentModifiers.isEmpty {
                cancelCapture()
                return nil  // Consume the event
            }

            // Capture the key combo
            let combo = KeyCombo(
                keyCode: event.keyCode,
                modifiers: currentModifiers
            )

            onCapture?(button, combo)

            // Clean up
            removeMonitor()
            captureState = .idle
            currentModifiers = []

            return nil  // Consume the event
        }

        // For flagsChanged, just update display (don't complete capture)
        return nil  // Consume modifier-only events during capture
    }

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
