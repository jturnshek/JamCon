# JamCon

A macOS menu bar app that turns Nintendo Switch Joy-Con controllers into a wireless mouse and keyboard input device.

## Features

- **Gyro Mouse Control** - Move the cursor by tilting the Joy-Con like an LG Magic Remote
- **Button Mapping** - Map Joy-Con buttons to mouse clicks or any keyboard shortcut
- **Joystick Scrolling** - Use the analog stick for smooth scrolling
- **Dual Controller Support** - Use two Joy-Cons simultaneously with separate mappings
- **Auto-Calibration** - Gyro drift is automatically corrected when the controller is held still
- **Low Latency** - Direct input processing without main thread overhead

## Requirements

- macOS 15.0 (Sequoia) or later
- Nintendo Switch Joy-Con controller(s)
- Bluetooth

## Installation

### From Source

1. Clone the repository
2. Open `JamCon.xcodeproj` in Xcode
3. Build and run (Cmd+R)

Or using the command line:
```bash
xcodegen generate  # If project.yml was modified
xcodebuild -project JamCon.xcodeproj -scheme JamCon -configuration Release build
```

### Pairing Joy-Cons

1. Open **System Settings → Bluetooth**
2. Hold the sync button on the Joy-Con (small button on the rail) until the lights start flashing
3. Select the Joy-Con from the Bluetooth devices list

## Usage

### First Launch

1. Launch JamCon from Applications or the build output
2. Grant **Accessibility permission** when prompted (required for mouse/keyboard control)
   - If the prompt doesn't appear, manually add JamCon in **System Settings → Privacy & Security → Accessibility**
3. The app appears as a controller icon in the menu bar

### Controls

| Control | Action |
|---------|--------|
| Tilt Joy-Con | Move mouse cursor |
| Analog stick | Scroll (velocity-based) |
| ZR / ZL (default) | Left click |
| R / L (default) | Right click |

### Settings

Click the menu bar icon to access settings:

- **Mouse Control** - Enable/disable gyro mouse movement
- **Sensitivity**
  - *Mouse* - Gyro sensitivity (1-50)
  - *Scroll* - Stick scroll speed (1-20)
- **Stabilization**
  - *Smoothing* - Reduces jitter for slow movements (0=off, higher=smoother)
  - *Recalibrate* - Reset gyro calibration (hold controller still after)
- **Button Mapping** - Customize what each button does
  - Click the keyboard area to capture a key combination
  - Click the mouse icon to assign a mouse click
  - Click X to clear a mapping

### Dual Controller Mode

When two Joy-Cons are connected:
- The **Primary** controller handles mouse movement and uses the primary button mapping
- The **Secondary** controller only sends button inputs using the secondary mapping
- Click "Set Primary" next to a controller to switch which one controls the mouse

### Mirror Face Buttons

When enabled (default), the Left Joy-Con's D-pad buttons map to the same positions as the Right Joy-Con's face buttons:
- Left Joy-Con ← maps to Right Joy-Con Y position
- Left Joy-Con → maps to Right Joy-Con A position

This makes both controllers feel consistent when held sideways.

## Architecture

```
JamCon/
├── JamConApp.swift          # App entry point, MenuBarExtra scene
├── MenuBarView.swift        # Settings UI
├── Models/
│   ├── AppState.swift       # Central state management
│   └── ButtonMapping.swift  # Button-to-action mapping system
└── Controllers/
    ├── JoyConController.swift   # Joy-Con Bluetooth communication
    ├── InputProcessor.swift     # Gyro/button processing, calibration
    ├── MouseController.swift    # CGEvent-based mouse/keyboard control
    └── KeyCaptureManager.swift  # Keyboard shortcut capture for mapping
```

## Troubleshooting

### Mouse not moving / buttons not working

1. Check that Accessibility permission is granted (orange warning appears if not)
2. Ensure the Joy-Con is connected (green controller icon in menu)
3. Verify "Mouse Control" toggle is enabled

### Cursor drifts when controller is still

Hold the controller completely still for 1-2 seconds. The app auto-calibrates when it detects no movement. The status indicator will show "Calibrated" when complete.

### Joy-Con not connecting

1. Remove the Joy-Con from Bluetooth settings
2. Re-pair using the sync button
3. Ensure no other device (like a Switch) is trying to connect to it

### Can't capture Cmd+Space or other system shortcuts

System shortcuts will briefly activate (e.g., Spotlight opens) during capture, but the shortcut will still be recorded. This is a macOS limitation.

## Building

### Prerequisites

- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for regenerating project)

```bash
brew install xcodegen
```

### Development Build

```bash
xcodebuild -project JamCon.xcodeproj -scheme JamCon -configuration Debug build
```

### Release Build

```bash
xcodebuild -project JamCon.xcodeproj -scheme JamCon -configuration Release build
```

## Credits

- [JoyConSwift](https://github.com/magicien/JoyConSwift) - Joy-Con communication library (modified for Apple Silicon compatibility)
- Inspired by [JoyShockMapper](https://github.com/JibbSmart/JoyShockMapper) gyro mouse implementation

## License

MIT
