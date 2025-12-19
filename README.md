# JamCon

A macOS menu bar app that turns Nintendo Switch Joy-Con and PlayStation Sense controllers into a wireless mouse and keyboard input device.

## Features

- **Gyro Mouse Control** - Move the cursor by tilting the controller like an LG Magic Remote
- **Multi-Controller Support** - Works with Joy-Con and PlayStation Sense controllers
- **Button Mapping** - Map buttons to mouse clicks or any keyboard shortcut
- **Joystick Scrolling** - Use the analog stick for smooth scrolling
- **Radial Menu** - Toggle joystick to show a pie-menu for quick arrow key input
- **Dual Controller Support** - Use two controllers simultaneously with independent button mappings
- **Override Button Modes** - Assign buttons as Clutch (drag), Scroll, or Zoom modifiers
- **Pinch-to-Zoom** - Zoom mode sends real trackpad-style magnification gestures
- **Auto-Calibration** - Gyro drift is automatically corrected when the controller is held still
- **Low Latency** - Direct HID input processing without main thread overhead

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (arm64) Mac
- Nintendo Switch Joy-Con controller(s) or PlayStation Sense controller(s)
- Bluetooth

## Install

### Homebrew (recommended)

```bash
brew tap jturnshek/tap
brew install --cask jamcon
```

### Direct download

Download the latest `JamCon-<version>.dmg` from the GitHub Releases page and drag the app to `/Applications`.

## Quick Start

### 1. Clone and Build

```bash
git clone <repository-url>
cd JamCon
brew install xcodegen  # if not already installed
xcodegen generate
./dev.sh
```

This builds, signs, and installs the app to `/Applications/JamCon.app`.

### 2. Pair Your Controller

1. Open **System Settings → Bluetooth**
2. Put your controller in pairing mode:
   - **Joy-Con**: Hold the sync button on the rail until the lights flash
   - **Sense**: Hold PS + Create buttons until the light bar flashes
3. Select the controller from the Bluetooth devices list

### 3. Launch and Grant Permissions

1. Launch JamCon (double-click the .app or run `./dev.sh`)
2. Grant **Accessibility permission** when prompted
   - If the prompt doesn't appear: **System Settings → Privacy & Security → Accessibility → Add JamCon**
3. The app appears as a controller icon in the menu bar

## Usage

### Default Controls

| Control | Action |
|---------|--------|
| Tilt controller | Move mouse cursor |
| Analog stick | Scroll (velocity-based) |
| ZR / ZL (or R2/L2) | Left click |
| R / L (or R1/L1) | Right click |

### Button Mapping

Click the menu bar icon → expand **Button Mappings**:

- **Press** - Action when button is tapped
- **Hold** - Action when button is held (configurable delay)
- **Clutch** - Hold to drag (mouse down while held, mouse up on release)
- **Scroll** - Hold to convert gyro tilt into scrolling
- **Zoom** - Hold to convert gyro tilt into pinch-to-zoom gestures

Each button can only be assigned to one override mode (Clutch/Scroll/Zoom) at a time.

### Dual Controller Mode

When two controllers are connected:

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

## Development

### Prerequisites

- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple Developer account (for code signing)

```bash
brew install xcodegen
```

### Development Workflow

We use a script-based workflow instead of running from Xcode. This is because:
- macOS accessibility permissions are tied to code signatures
- Running from Xcode produces unstable debug signatures that break permissions on every rebuild
- A properly signed app in `/Applications` maintains permissions across rebuilds

**Scripts:**

| Script | Purpose |
|--------|---------|
| `./dev.sh` | Build, sign, install to `/Applications`, and launch |
| `./relaunch.sh` | Just kill and relaunch (no rebuild) |

**Typical workflow:**

```bash
# First time setup
xcodegen generate

# After making code changes
./dev.sh

# To restart the app without rebuilding
./relaunch.sh
```

The first time you run `./dev.sh`, you'll need to grant Accessibility permission to `/Applications/JamCon.app`. After that, permissions persist across rebuilds.

### Code Signing

Edit `dev.sh` to set your signing identity:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
```

Find your identity with:
```bash
security find-identity -v -p codesigning
```

### Project Structure

```
JamCon/
├── Sources/JamCon/
│   ├── JamConApp.swift              # App entry point, MenuBarExtra scene
│   ├── AppState.swift               # Central state management
│   ├── MenuBarView.swift            # Main settings UI
│   ├── SenseController.swift        # PlayStation Sense HID driver
│   ├── JoyConHIDController.swift    # Joy-Con Bluetooth HID driver
│   ├── GyroProcessor.swift          # Gyro→mouse translation, filtering
│   ├── GyroRemapper.swift           # Controller-specific axis mapping
│   ├── MouseController.swift        # CGEvent-based mouse/keyboard
│   ├── Engine/
│   │   ├── InputEngine.swift        # Unified input processing pipeline
│   │   ├── SettingsStore.swift      # Thread-safe settings bridge
│   │   └── DebugBuffer.swift        # Debug data collection
│   ├── Models/
│   │   ├── ControllerTypes.swift    # Controller type definitions
│   │   ├── RadialMenu.swift         # Radial menu configuration
│   │   └── RadialMenuState.swift    # Radial menu runtime state
│   ├── Views/
│   │   ├── Settings/                # Settings tab views
│   │   ├── Components/              # Reusable UI components
│   │   └── RadialMenuView.swift     # Radial menu overlay
│   └── Utilities/
├── Resources/
│   ├── Info.plist
│   ├── JamCon.entitlements
│   ├── AppIcon.icns
│   └── *.png                        # Menu bar icons
├── docs/                            # HID protocol documentation
├── project.yml                      # XcodeGen project definition
├── dev.sh                           # Build and install script
└── relaunch.sh                      # Quick relaunch script
```

### Threading Model

JamCon intentionally splits runtime work into two “worlds”:

- **World 1 (Engine)**: `InputEngine` owns all real-time state and runs on a dedicated serial queue (`engineQueue`). Controller HID callbacks forward work onto this queue. The engine emits system input via CoreGraphics (`CGEvent`) and avoids AppKit on the hot path.
- **World 2 (UI)**: `AppState` and SwiftUI views are `@MainActor`. UI code never receives HID callbacks directly.

Bridges between worlds:

- `SettingsStore`: lock-protected. UI writes via `update()` (main thread), engine reads via `snapshot()`.
- `DebugBuffer`: lock-protected. Engine records optional telemetry; UI polls and publishes it separately (`DebugTelemetryState`) so high-frequency debug updates don’t invalidate non-debug UI.

Rule of thumb: if you add new shared mutable state, keep it confined to `engineQueue` / `@MainActor`, or protect it with a lock and document the invariant.

### Building Manually

```bash
# Generate Xcode project (after modifying project.yml)
xcodegen generate

# Release build
xcodebuild -scheme JamCon -configuration Release -derivedDataPath build

# Or open in Xcode (for editing, not recommended for running)
open JamCon.xcodeproj
```

## Troubleshooting

### Mouse not moving / buttons not working

1. Check that Accessibility permission is granted (orange warning appears if not)
2. Ensure the controller is connected (green controller icon in menu)
3. Verify "Mouse Control" toggle is enabled

### Cursor drifts when controller is still

Hold the controller completely still for 1-2 seconds. The app auto-calibrates when it detects no movement.

### Controller not connecting

1. Remove the controller from Bluetooth settings
2. Re-pair using the pairing button sequence
3. Ensure no other device (like a Switch or PlayStation) is trying to connect to it

### Zoom not working in some apps

Zoom sends standard macOS magnification gestures. Some apps (especially non-native ones) may not respond to these gestures.

## License

MIT
