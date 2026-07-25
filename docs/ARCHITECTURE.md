# Architecture

## Input pipeline

1. A concrete InputDeviceBackend receives framework or HID input on its transport thread.
2. The backend copies any callback-owned bytes, decodes transport timing and motion, and emits an InputDeviceFrame.
3. InputDeviceBackendRegistry validates the frame's backend identity, stable device identity, finite clocks, motion shape, and declared capabilities before forwarding it to InputEngine's serial queue.
4. InputEngine applies profile settings and application-level button, gyro, scroll, and radial-menu policy.
5. A linked Joy-Con pair branches before normal JamCon actions into a
   full-resolution combined gamepad state and an asynchronous CoreHID virtual
   device; other inputs continue to MouseController.
6. MouseController posts CGEvents directly to the system.
7. UI state updates are dispatched to MainActor only.

## Threading model

- InputEngine owns its mutable processing state on a dedicated serial queue for low latency.
- SettingsStore provides a lock-protected snapshot of UI settings for the engine.
- Controller-local hot settings use small lock-protected runtime config objects with explicit last-writer-wins semantics across UI, engine, and HID threads.
- MouseController's movement and synthetic-button state follows InputEngine's queue ownership. Each controller instance owns its CGEventSource; cursor-visibility work is isolated to the main queue.
- DebugBuffer records optional telemetry without spamming the main thread.

## Key components

- AppState: central UI state, persists managed devices and profile settings, and mirrors engine callbacks into SwiftUI state.
- HIDTransport: shared opaque device handles, device properties, transport errors, callback registrations, and stable identity selection used by controller backends.
- InputDeviceBackend: common contract for backend identity and capabilities, lifecycle, discovery snapshots, backend-supplied handedness, managed-device intent, connection state, lifecycle events, and high-frequency InputDeviceFrame delivery.
- InputDeviceFrame: allocation-conscious engine handoff containing stable device/backend identity, monotonic timing, copied diagnostic bytes, and either no motion, one IMU sample, or an adapter-owned sample batch.
- InputDeviceBackendRegistry: ordered owner of the active backends. InputEngine uses it for start/stop, device enumeration, management routing, aggregate connection state, lifecycle callbacks, and validated input-frame delivery. The registry only forwards callbacks while its lifecycle is running, so teardown callbacks cannot revive stopped engine state.
- SenseInputDeviceBackend: owns the complete Sense adapter by combining IOKit identity discovery with Apple's Game Controller session and resolving native left/right input to stable managed-device IDs.
- JoyConHIDController and G502XHIDController: complete direct-HID backends with device-specific lifecycle, managed-device policy, setup, decoding, and common-frame emission. They revalidate queued activations and only open explicitly managed devices.
- SenseController: IOKit discovery and stable identity component owned by SenseInputDeviceBackend. It never opens raw Sense input.
- SenseGameControllerSession: owns Sense motion, buttons, stick, and battery input through Apple's background Game Controller APIs, activates native motion when required, and records aggregate callback health.
- IOKitSenseHIDTransport: Sense discovery and stable physical identity only. JamCon intentionally does not open Sense HID devices because either raw-open mode terminates their Bluetooth session on macOS.
- IOKitJoyConHIDTransport: low-level Joy-Con discovery and exclusive input registration.
- IOKitG502XHIDTransport: low-level Logitech discovery, non-exclusive per-interface input registration, and HID++ feature/output writes. A physical G502 can expose several HID interfaces, which the controller groups under one stable identity before activating only the selected mouse.
- InputEngine: unified processing for gyro, buttons, and radial menu.
- GyroProcessor: gyro to mouse translation, smoothing, and bias estimation.
- MouseController: CGEvent-based mouse/keyboard output.
- SettingsStore: thread-safe settings bridge from UI to engine.
- DebugBuffer: thread-safe engine-to-UI telemetry and log buffer for diagnostics.
- LinkedGamepadConfiguration: persisted stable left/right device selections and
  activation intent.
- LinkedJoyConGamepadComposer: timestamped latest-half state composer that maps
  two physical layouts to one standard gamepad and rejects stale input.
- VirtualGamepadOutputCoordinator: generation-ordered asynchronous CoreHID
  output that coalesces analog-only updates, preserves bounded digital
  transitions, and cannot stall InputEngine's queue.

Device transport handles, backend descriptors, common frames, decoded reports, settings snapshots, and mapping profiles are `Sendable`. Raw IOKit and framework references and callback buffers remain inside the concrete backends; adapters immediately copy callback bytes into owned storage. Controller start/stop is serialized, failed startup is retryable, managed selections survive backend restarts and reconnects, and shutdown closes each active input registration exactly once. Deterministic fake transports, native sessions, and registry backends cover those lifecycle contracts without connected hardware.

## Backend boundary versus product policy

The backend owns facts and mechanics specific to the physical device: framework or HID objects, discovery, stable identity, handedness, transport lifecycle, report validation, timestamps, common motion extraction, and copied raw diagnostic bytes. Shared models must not infer those facts from vendor or product IDs.

InputEngine and the settings UI own JamCon behavior layered on those facts: family-specific button/stick layout interpretation, controller profiles, logical mappings, clutch and scroll overrides, radial-menu behavior, gyro tuning, and synthetic output. An explicit InputEngine processor per controller family is intentional product policy rather than a transport leak; a generic physical-control schema should only be introduced when concrete new-device requirements justify it.

## Adding a device backend

1. Add a stable InputDeviceBackendID and a descriptor declaring the device kind and capabilities.
2. Keep all framework objects, HID handles, discovery, report validation, common timing/motion extraction, and transport lifecycle inside the adapter.
3. Emit stable device snapshots with explicit handedness, and connection events only for managed input-ready devices.
4. Emit InputDeviceFrame values with a nonempty stable device ID, copied raw bytes, finite real report/receipt clocks, and reusable IMU samples only when the descriptor declares motion capability.
5. Register the adapter with InputDeviceBackendRegistry and add only the profile-specific application policy needed by InputEngine.
6. Use InputDeviceBackendContractHarness with a deterministic fake transport or session to cover start/stop retryability, stable identity and handedness, manage/unmanage, disconnect cleanup, valid frame delivery, and callback shutdown.
