# Usage

## Pairing

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
- Zoom: hold to convert gyro tilt into pinch-to-zoom gestures

Each button can be assigned to only one override mode (Clutch/Scroll/Zoom).

## Dual controller mode

When two controllers are connected:

- Primary handles mouse movement and primary button mappings
- Secondary sends button inputs with its own mappings
- Each controller has independent Clutch/Scroll/Zoom assignments
- Use Set Primary to switch which one controls the mouse

## Settings

- Mouse Control: enable/disable gyro mouse movement
- Sensitivity:
  - Mouse: gyro sensitivity (1-50)
  - Scroll: stick scroll speed (1-20)
- Stabilization:
  - Smoothing: reduces jitter for slow movements (0=off, higher=smoother)
  - Recalibrate: reset gyro calibration (hold controller still after)
