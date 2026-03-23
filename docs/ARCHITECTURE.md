# Architecture

## Input pipeline

1. SenseController or JoyConHIDController receives HID reports on a background thread.
2. Callbacks fire on that HID thread.
3. InputEngine processes input and calls MouseController directly.
4. MouseController posts CGEvents to the system.
5. UI state updates are dispatched to MainActor only.

## Threading model

- InputEngine runs on a dedicated serial queue for low latency.
- SettingsStore provides a lock-protected snapshot of UI settings for the engine.
- Controller-local hot settings use small lock-protected runtime config objects with explicit last-writer-wins semantics across UI, engine, and HID threads.
- DebugBuffer records optional telemetry without spamming the main thread.

## Key components

- AppState: central UI state, persists managed devices and profile settings, and mirrors engine callbacks into SwiftUI state.
- SenseController: PS VR2 Sense HID driver.
- JoyConHIDController: Joy-Con HID driver with IMU parsing.
- G502XHIDController: Logitech G502 X HID driver for button remapping/debugging.
- InputEngine: unified processing for gyro, buttons, and radial menu.
- GyroProcessor: gyro to mouse translation, smoothing, and bias estimation.
- MouseController: CGEvent-based mouse/keyboard output.
- SettingsStore: thread-safe settings bridge from UI to engine.
- DebugBuffer: thread-safe engine-to-UI telemetry and log buffer for diagnostics.
