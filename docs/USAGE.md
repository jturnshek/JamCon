# Usage

## Pairing

### Joy-Con 2

1. Open JamCon's Devices screen.
2. Hold the sync button until the player lights chase.
3. Select the discovered Joy-Con 2 as a managed device.

JamCon connects through the Joy-Con 2 proprietary BLE service; it does not use
the original Joy-Con HID pairing path.

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

## Multiple devices

JamCon lets you manage multiple supported devices at once:

- Managed devices are selected in the Devices screen
- Button mappings are saved per controller profile
- Cursor control can be enabled or disabled per controller profile
- Multiple managed controllers can stay connected at the same time

## Settings

- Mouse Control: enable/disable gyro mouse movement
- Sensitivity:
  - Mouse: gyro sensitivity (1-50)
  - Scroll: stick scroll speed (1-20)
- Stabilization:
  - Smoothing: reduces jitter for slow movements (0=off, higher=smoother)
  - Recalibrate: reset gyro calibration (hold controller still after)
