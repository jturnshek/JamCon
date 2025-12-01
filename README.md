# JamCon

A macOS menu bar app that turns Nintendo Switch Joy-Con controllers into a wireless mouse and keyboard input device.

## Features

- **Gyro Mouse Control** - Move the cursor by tilting the Joy-Con like an LG Magic Remote
- **Button Mapping** - Map Joy-Con buttons to mouse clicks or any keyboard shortcut
- **Joystick Scrolling** - Use the analog stick for smooth scrolling
- **Dual Controller Support** - Use two Joy-Cons simultaneously with independent button mappings
- **Override Button Modes** - Assign buttons as Clutch (drag), Scroll, or Zoom modifiers
- **Pinch-to-Zoom** - Zoom mode sends real trackpad-style magnification gestures
- **Auto-Calibration** - Gyro drift is automatically corrected when the controller is held still
- **Low Latency** - Direct input processing without main thread overhead

## Requirements

- macOS 14.0 (Sonoma) or later
- Nintendo Switch Joy-Con controller(s)
- Bluetooth

## Quick Start

### 1. Clone and Build

```bash
git clone <repository-url>
cd JamCon
brew install xcodegen  # if not already installed
xcodegen generate
xcodebuild -project JamCon.xcodeproj -scheme JamCon -configuration Debug build
```

The built app will be at:
```
~/Library/Developer/Xcode/DerivedData/JamCon-*/Build/Products/Debug/JamCon.app
```

### 2. Pair Your Joy-Con

1. Open **System Settings → Bluetooth**
2. Hold the sync button on the Joy-Con (small button on the rail) until the lights flash
3. Select the Joy-Con from the Bluetooth devices list

### 3. Launch and Grant Permissions

1. Launch JamCon (double-click the .app or run from Xcode)
2. Grant **Accessibility permission** when prompted
   - If the prompt doesn't appear: **System Settings → Privacy & Security → Accessibility → Add JamCon**
3. The app appears as a controller icon in the menu bar

## Usage

### Default Controls

| Control | Action |
|---------|--------|
| Tilt Joy-Con | Move mouse cursor |
| Analog stick | Scroll (velocity-based) |
| ZR / ZL | Left click |
| R / L | Right click |

### Button Mapping

Click the menu bar icon → expand **Button Mappings**:

- **Press** - Action when button is tapped
- **Hold** - Action when button is held (configurable delay)
- **Clutch** - Hold to drag (mouse down while held, mouse up on release)
- **Scroll** - Hold to convert gyro tilt into scrolling
- **Zoom** - Hold to convert gyro tilt into pinch-to-zoom gestures

Each button can only be assigned to one override mode (Clutch/Scroll/Zoom) at a time.

### Dual Controller Mode

When two Joy-Cons are connected:

- **Primary** controller handles mouse movement and uses primary button mappings
- **Secondary** controller only sends button inputs using secondary mappings
- Each controller has **independent** Clutch/Scroll/Zoom button assignments
- Click "Set Primary" next to a controller to switch which one controls the mouse
- Use the Primary/Secondary tabs in Button Mappings to configure each

### Settings

- **Mouse Control** - Enable/disable gyro mouse movement
- **Sensitivity**
  - *Mouse* - Gyro sensitivity (1-50)
  - *Scroll* - Stick scroll speed (1-20)
- **Stabilization**
  - *Smoothing* - Reduces jitter for slow movements (0=off, higher=smoother)
  - *Recalibrate* - Reset gyro calibration (hold controller still after)
- **Mirror Face Buttons** - Maps Left Joy-Con D-pad to match Right Joy-Con face button positions

## Development

### Prerequisites

- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen
```

### Project Structure

```
JamCon/
├── Sources/JamCon/
│   ├── JamConApp.swift          # App entry point, MenuBarExtra scene
│   ├── MenuBarView.swift        # Settings UI
│   ├── Models/
│   │   ├── AppState.swift       # Central state management
│   │   └── ButtonMapping.swift  # Button-to-action mapping system
│   └── Controllers/
│       ├── JoyConController.swift   # Joy-Con Bluetooth communication
│       ├── InputProcessor.swift     # Gyro/button processing, calibration
│       ├── MouseController.swift    # CGEvent-based mouse/keyboard control
│       └── KeyCaptureManager.swift  # Keyboard shortcut capture for mapping
├── Resources/
│   ├── Info.plist
│   ├── AppIcon.icns
│   └── *.png                    # Menu bar icons
├── Packages/JoyConSwift/        # Joy-Con communication library
├── project.yml                  # XcodeGen project definition
└── Package.swift                # Swift Package Manager manifest
```

### Building

```bash
# Generate Xcode project (after modifying project.yml)
xcodegen generate

# Debug build
xcodebuild -project JamCon.xcodeproj -scheme JamCon -configuration Debug build

# Release build
xcodebuild -project JamCon.xcodeproj -scheme JamCon -configuration Release build

# Or open in Xcode
open JamCon.xcodeproj
```

### Code Signing

For development, the app builds with ad-hoc signing. For distribution, configure your signing identity in `project.yml` under `settings.base.CODE_SIGN_IDENTITY`.

## Troubleshooting

### Mouse not moving / buttons not working

1. Check that Accessibility permission is granted (orange warning appears if not)
2. Ensure the Joy-Con is connected (green controller icon in menu)
3. Verify "Mouse Control" toggle is enabled

### Cursor drifts when controller is still

Hold the controller completely still for 1-2 seconds. The app auto-calibrates when it detects no movement.

### Joy-Con not connecting

1. Remove the Joy-Con from Bluetooth settings
2. Re-pair using the sync button
3. Ensure no other device (like a Switch) is trying to connect to it

### Zoom not working in some apps

Zoom sends standard macOS magnification gestures. Some apps (especially non-native ones) may not respond to these gestures.

## Credits

- [JoyConSwift](https://github.com/magicien/JoyConSwift) - Joy-Con communication library (bundled, modified for Apple Silicon)
- Inspired by [JoyShockMapper](https://github.com/JibbSmart/JoyShockMapper) gyro mouse implementation

## License

MIT
