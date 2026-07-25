# Virtual Gamepad Feasibility Probe

This local-only probe tests whether the current Mac, signing identity, and
CoreHID stack accept a generic virtual gamepad before JamCon exposes a
production gamepad mode. It intentionally remains separate from JamCon: an
unauthorized restricted entitlement makes macOS terminate the executable at
launch.

## Build

Build the producer and its independent observer:

```bash
mkdir -p build/VirtualGamepadProbe
xcrun swiftc \
  -parse-as-library \
  Sources/JamCon/VirtualGamepad/VirtualGamepadHIDReport.swift \
  Tools/VirtualGamepadProbe/main.swift \
  -o build/VirtualGamepadProbe/VirtualGamepadProbe

xcrun swiftc \
  -parse-as-library \
  Tools/VirtualGamepadProbe/observer.swift \
  -framework GameController \
  -framework IOKit \
  -o build/VirtualGamepadProbe/VirtualGamepadObserver
```

Sign the producer with an identity and provisioning profile authorized for
`com.apple.developer.hid.virtual.device`:

```bash
codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --entitlements Tools/VirtualGamepadProbe/VirtualGamepadProbe.entitlements \
  --options runtime \
  build/VirtualGamepadProbe/VirtualGamepadProbe
```

## Run

Start the observer, then the producer in a second terminal:

```bash
build/VirtualGamepadProbe/VirtualGamepadObserver 60
build/VirtualGamepadProbe/VirtualGamepadProbe 60
```

The probe publishes a controller named `JamCon Virtual Gamepad Probe` and
cycles through deterministic half-second phases covering neutral state, both
signs of every stick axis, all face positions, shoulders, stick clicks,
diagonal D-pad values, triggers, and menu buttons. It records CoreHID dispatch
duration, schedules reports on fixed 8 ms deadlines, and fails if its achieved
rate is below 110 reports per second. It does not connect to or modify a
physical controller.

The observer filters raw HID by the probe VID/PID, ignores unrelated Game
Controllers, installs a raw input-report callback, and advances through the
eight expected phases only when the entire Game Controller state exactly
matches. It exits successfully only when it sees exactly one matching HID
device, at least 110 valid 14-byte input reports per second for at least three
seconds, no report gap above 50 ms, exactly one JamCon Game Controller, and
every phase in order with the expected axis directions and button positions.
A successful run ends with:

```text
PASS: virtual gamepad satisfied exact HID cadence and Game Controller semantic mapping checks
```

## Result on July 25, 2026

Environment: macOS 26.5.2, macOS SDK 26.5.

| Producer signature | Embedded virtual-HID entitlement | Result |
| --- | --- | --- |
| Developer ID Application | No | Runs; CoreHID creation returns `nil` |
| Developer ID Application | Yes | Terminated by macOS at launch (`137`) |
| Apple Development | Yes | Terminated by macOS at launch (`137`) |
| Ad hoc | Yes | Terminated by macOS at launch (`137`) |

The executable passes `codesign --verify`. All locally installed macOS
provisioning profiles were also inspected, and none authorizes
`com.apple.developer.hid.virtual.device`. Xcode automatic signing could not
obtain a matching profile from the account currently available to the command
line.

This establishes a signing/provisioning block before report descriptor,
Game Controller recognition, report-rate, or loopback-fidelity testing begins.
Adding the entitlement to the production JamCon target in this state would
prevent JamCon from launching.

Apple entitlement request `7SQPJYNJYZ` was submitted on July 25, 2026 and is
awaiting review.

The production user experience, opt-in authorized build, and first-approval
acceptance checklist are prepared in `docs/VIRTUAL_GAMEPAD.md`. The normal app
continues to use its entitlement-free signing path until approval.

## Unlock and acceptance criteria

The preferred architecture remains an in-process CoreHID producer because it
avoids a helper process and an extra input queue. Obtain an Apple-authorized
development and distribution provisioning profile for
`com.apple.developer.hid.virtual.device`, then rerun this probe.

The output path is viable only if:

1. IOKit enumerates the virtual gamepad and receives changing values.
2. Game Controller enumerates it as an extended gamepad and receives values.
3. The raw-HID observer measures at least 110 reports per second over at least
   three seconds, with no gap above 50 ms.
4. Every complete semantic phase arrives in order with exact button identity,
   stick/D-pad direction, trigger state, and neutral state.

If Apple does not make the application entitlement available, the supported
software alternative is a DriverKit virtual-HID system extension. That route
also requires Apple-approved DriverKit entitlements and adds installation and
activation complexity. A small USB HID bridge is the entitlement-independent
fallback; it would enumerate as a physical gamepad and can still preserve the
single Joy-Con input latency by receiving JamCon's already-decoded state.
