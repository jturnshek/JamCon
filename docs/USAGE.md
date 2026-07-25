# Usage

## Pairing

### Joy-Con 2

1. Open JamCon's Devices screen.
2. Hold the sync button until the player lights chase.
3. Select the discovered Joy-Con 2 as a managed device.

JamCon connects through the Joy-Con 2 proprietary BLE service; it does not use
the original Joy-Con HID pairing path.

After the Mac wakes from sleep, the Joy-Con 2 may not resume advertising on its
own. Hold the controller's sync button until the player lights chase; JamCon
will reconnect the managed controller without needing to select it again.

### Canonical one-handed Joy-Con controls

Original and second-generation Joy-Cons share the same default control
semantics. Physical controls are mirrored by side:

| Action | Right Joy-Con | Left Joy-Con |
| --- | --- | --- |
| Left click | ZR | ZL |
| Right click | R | L |
| Middle click | + | − |
| Browser Back / Forward | Stick press / hold | Stick press / hold |
| Mission Control / Play-Pause | Home press / hold | Capture press / hold |
| Drag | X | D-pad Up |
| Radial menu | B | D-pad Down |

Browser Back and Forward use the standard macOS `⌘[` and `⌘]` shortcuts.
Default stick scrolling uses speed `8` and acceleration `3`.

### Original Joy-Con and PS VR2 Sense

1. Open System Settings > Bluetooth.
2. Put your controller in pairing mode:
   - Joy-Con: hold the sync button on the rail until the lights flash.
   - PS VR2 Sense: hold PS + Create until the light bar flashes.
3. Select the controller from the Bluetooth list.

## Permissions

JamCon posts system input events. Grant Accessibility permission when prompted:

System Settings > Privacy & Security > Accessibility > JamCon

## Default controls

| Control | Action |
| --- | --- |
| Tilt controller | Move mouse cursor |
| Analog stick | Scroll (velocity-based) |
| ZR / ZL (or R2/L2) | Left click |
| R / L (or R1/L1) | Right click |

## Button mapping

Open the menu bar icon and expand Button Mappings:

- Press: action when button is tapped
- Hold: action when button is held (configurable delay)
- Clutch: hold to drag (mouse down while held, mouse up on release)
- Scroll: hold to convert gyro tilt into scrolling
- Radial Menu: hold to open the radial menu and select with gyro or mouse movement

Each button can be assigned to only one override mode (Clutch/Scroll/Radial Menu).

The default radial menu uses arrow keys on its inner ring. Its outer ring
contains Mission Control, New Tab, previous Space, reverse Tab, Close
Window/Tab, Play/Pause, next Space, and Reopen Closed Tab. **Reset to Default**
restores this complete two-ring layout.

## Multiple devices

JamCon lets you manage multiple supported devices at once:

- Managed devices are selected in the Devices screen
- Button mappings are saved per controller profile
- Cursor control can be enabled or disabled per controller profile
- Multiple managed controllers can stay connected at the same time

## Linked Joy-Con gamepad

The Devices screen can save one left and one right Joy-Con as a linked pair.
Once JamCon is signed with Apple's restricted Virtual HID entitlement, enabling
the pair exposes one standard game controller to games. Selected controllers
automatically become managed and switch exclusively from JamCon's cursor
pipeline to the gamepad pipeline while the mode is active.

The virtual controller stays present while a selected half reconnects. JamCon
publishes neutral input after a short report timeout, then resumes only when
both halves are fresh, preventing a silent controller from leaving a stuck
stick or button.

Linked-gamepad mode currently exposes standard sticks, buttons, D-pad, and
triggers. Rumble requested by a game and virtual battery state are not
forwarded. Physical Joy-Con motion still powers JamCon's cursor mode, but
linked mode does not yet expose gyro/accelerometer data onward to games as
virtual controller motion.

See [Linked Joy-Con Virtual Gamepad](VIRTUAL_GAMEPAD.md) for the control layout,
reconnect behavior, performance design, current entitlement status, and
approval-day setup.

## Settings

- Mouse Control: enable/disable gyro mouse movement
- Sensitivity:
  - Mouse: gyro sensitivity (1-50)
  - Scroll: stick scroll speed (1-20)
- Stabilization:
  - Smoothing: reduces jitter for slow movements (0=off, higher=smoother)
  - Recalibrate: reset gyro calibration (hold controller still after)
