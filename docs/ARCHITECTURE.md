# Architecture

## Input pipeline

1. SenseController, JoyConHIDController, or G502XHIDController receives HID reports on a dedicated background thread.
2. Callbacks fire on that HID thread.
3. InputEngine processes input and calls MouseController directly.
4. MouseController posts CGEvents to the system.
5. UI state updates are dispatched to MainActor only.

## Threading model

- InputEngine owns its mutable processing state on a dedicated serial queue for low latency.
- SettingsStore provides a lock-protected snapshot of UI settings for the engine.
- Controller-local hot settings use small lock-protected runtime config objects with explicit last-writer-wins semantics across UI, engine, and HID threads.
- MouseController's movement and synthetic-button state follows InputEngine's queue ownership. Each controller instance owns its CGEventSource; cursor-visibility work is isolated to the main queue.
- DebugBuffer records optional telemetry without spamming the main thread.

## Key components

- AppState: central UI state, persists managed devices and profile settings, and mirrors engine callbacks into SwiftUI state.
- HIDTransport: shared opaque device handles, device properties, transport errors, callback registrations, and stable identity selection used by controller backends.
- SenseController, JoyConHIDController, and G502XHIDController: device-specific lifecycle, managed-device policy, setup, and report decoding. They revalidate queued activations and only open explicitly managed devices.
- IOKitSenseHIDTransport and IOKitJoyConHIDTransport: low-level discovery and exclusive input registration for motion controllers.
- IOKitG502XHIDTransport: low-level Logitech discovery, non-exclusive per-interface input registration, and HID++ feature/output writes. A physical G502 can expose several HID interfaces, which the controller groups under one stable identity before activating only the selected mouse.
- InputEngine: unified processing for gyro, buttons, and radial menu.
- GyroProcessor: gyro to mouse translation, smoothing, and bias estimation.
- MouseController: CGEvent-based mouse/keyboard output.
- SettingsStore: thread-safe settings bridge from UI to engine.
- DebugBuffer: thread-safe engine-to-UI telemetry and log buffer for diagnostics.

Device transport handles, decoded reports, settings snapshots, and mapping profiles are `Sendable`. Raw IOKit references and callback buffers remain inside the concrete transports; controllers immediately copy callback bytes into owned storage. This is the boundary for adding future HID or Game Controller backends without exposing framework objects to the engine. Controller start/stop is serialized, failed startup is retryable, managed selections survive backend restarts and reconnects, and shutdown closes each active input registration exactly once. Deterministic fake transports cover those lifecycle contracts without connected hardware.
