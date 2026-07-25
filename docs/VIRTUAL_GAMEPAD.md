# Linked Joy-Con Virtual Gamepad

JamCon can combine one left and one right Joy-Con into one standard virtual
game controller while the physical controllers remain wireless and
single-handed. Original Joy-Cons, Joy-Con 2 controllers, and mixed-generation
pairs are supported by the shared application pipeline.

Apple Virtual HID entitlement request `7SQPJYNJYZ` was submitted on July 25,
2026. Until Apple approves it, normal JamCon builds intentionally omit the
restricted entitlement and the Devices screen reports `Awaiting Apple
Approval`. Pair selection and persistence are already usable.

## User experience

1. Connect both controllers as usual.
2. Open JamCon's Devices screen.
3. In **Linked Joy-Cons**, choose a left controller and a right controller.
   JamCon marks both as managed automatically and saves their stable identities.
4. Turn on **Expose this pair as a game controller**.
5. Games see one controller named **JamCon Linked Joy-Cons**.

Saved selections remain visible while a controller is offline. Enabling the
mode creates one stable, neutral virtual controller. If either physical half
disconnects or stops reporting for 250 ms, JamCon publishes neutral state but
keeps that virtual controller enumerated so games do not have to rediscover it.
Input resumes automatically once both selected controllers are fresh again.
The virtual device is removed only when the mode is disabled, the app is
disabled, or JamCon exits.

While the mode is active, the selected controllers are exclusive to the
gamepad pipeline. Their normal JamCon cursor, scrolling, button mappings, and
radial-menu actions do not also fire. Turning the mode off restores normal
JamCon behavior.

## Control layout

| Virtual control | Physical control |
| --- | --- |
| Left stick | Left Joy-Con stick |
| Right stick | Right Joy-Con stick |
| D-pad | Left Joy-Con directional buttons |
| South / East / West / North | B / A / Y / X |
| Left / Right shoulder | L / R |
| Left / Right trigger | ZL / ZR |
| Left / Right stick click | Left / Right stick click |
| Select / Start | − / + |
| Capture / Home | Capture / Home |
| Auxiliary | Joy-Con 2 C button |

Stick values go directly from calibrated 12-bit physical input to signed
16-bit HID axes, including per-direction factory ranges and a bounded neutral
deadzone. Joy-Con 2 supplies its factory record during BLE setup; original
Joy-Cons load the corresponding record through Nintendo's SPI-read
subcommand. A fixed conservative range is used until that reply arrives.
After Reset Device, axes remain neutral until a fresh neutral window validates
the center, while buttons continue working. There is no intermediate 8-bit
cursor representation. Nintendo's upward-positive stick Y is inverted once
for the raw HID convention; the acceptance observer records the final Game
Controller direction explicitly.

Each physical input event immediately combines with the newest fresh state
from the other half. Two independently reporting 66 Hz controllers can
therefore produce up to roughly 132 combined-state updates per second; JamCon
does not add a resampling timer. The asynchronous CoreHID writer coalesces
obsolete analog-only reports instead of building latency, while retaining an
ordered bounded queue for button, hat, and trigger transitions. Creation or
dispatch failures are latched instead of retried at input frequency; the
Devices screen offers an explicit **Try Again** action.

## Enable after Apple approval

The normal `./dev.sh` must stay entitlement-free until approval; embedding an
unauthorized restricted entitlement makes macOS terminate JamCon at launch.
After Apple confirms approval:

1. Open Xcode once and make sure the approved Apple Developer account is
   signed in.
2. Run:

   ```bash
   ./virtual-gamepad-dev.sh
   ```

   The script uses automatic provisioning for team `3EZHX57W9Y` by default.
   Override it if needed:

   ```bash
   DEVELOPMENT_TEAM=YOURTEAMID ./virtual-gamepad-dev.sh
   ```

3. The script builds in a separate directory and verifies that both the app's
   code signature and its embedded provisioning profile authorize
   `com.apple.developer.hid.virtual.device`. It does not replace the working
   app in `/Applications` unless both checks pass.
4. Open Devices, select the saved pair, and enable the gamepad toggle.

`Resources/JamCon.VirtualHID.entitlements` is the opt-in entitlement file.
`Resources/JamCon.entitlements`, `project.yml`, and `dev.sh` deliberately
remain on the safe production configuration while the request is pending.

## First authorized acceptance test

Build the independent observer:

```bash
mkdir -p build/VirtualGamepadProbe
xcrun swiftc \
  -parse-as-library \
  Tools/VirtualGamepadProbe/observer.swift \
  -framework GameController \
  -framework IOKit \
  -o build/VirtualGamepadProbe/VirtualGamepadObserver
```

Then:

1. Run `build/VirtualGamepadProbe/VirtualGamepadObserver 60`.
2. Enable the linked pair in JamCon.
3. Move both sticks and press every control during the 60-second window.
4. Confirm the observer reports exactly one `0xCAFE:0x0001` HID device and one
   JamCon Game Controller, prints exact element values, and ends with `PASS`.
5. Confirm a representative game sees one extended gamepad and that stick
   direction, range, face-button position, D-pad diagonals, shoulders,
   triggers, silent-half neutralization, and reconnect behavior all feel
   correct without the virtual controller disappearing.

The feasibility probe and the previously observed entitlement gate are
documented in `Tools/VirtualGamepadProbe/README.md`.
