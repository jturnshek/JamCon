# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development

**Prerequisites:** Xcode 16+, XcodeGen (`brew install xcodegen`), Apple Developer account for code signing.

### Commands

```bash
# First time setup (generates Xcode project from project.yml)
xcodegen generate

# Build, sign, install to /Applications, and launch
./dev.sh

# Quick relaunch without rebuilding
./relaunch.sh
```

### Why Script-Based Workflow

macOS accessibility permissions are tied to code signatures. Running from Xcode produces unstable debug signatures that break permissions on every rebuild. The `dev.sh` script builds a Release version, signs with a stable Developer ID, and installs to `/Applications/JamCon.app` where permissions persist.

Edit `SIGNING_IDENTITY` in `dev.sh` to use your certificate. Find yours with:
```bash
security find-identity -v -p codesigning
```

## Architecture

### Threading Model

Input processing happens off the main thread to minimize latency. The `InputSettings` class provides thread-safe access to settings using `OSAllocatedUnfairLock`, avoiding main thread dispatch for high-frequency gyro updates (~66Hz).

**Input flow:**
1. `JoyConController` receives HID reports on a background queue
2. Callbacks (`onGyroUpdate`, `onButtonPress`, `onStickUpdate`) fire on that queue
3. `InputProcessor` processes input and calls `MouseController` directly (no dispatch)
4. `MouseController` posts `CGEvent`s to the system
5. Only UI state changes dispatch to `@MainActor`

### Key Components

- **AppState** (`Models/AppState.swift`): Central state management. `@Published` properties for UI, `InputSettings` for thread-safe input processing. Routes Joy-Con events to appropriate handlers based on controller role (primary/secondary).

- **InputProcessor** (`Controllers/InputProcessor.swift`): Gyro→mouse translation with bias estimation, One Euro filtering, acceleration curves, and override modes (clutch/scroll/zoom). Button hold detection with configurable thresholds.

- **MouseController** (`Controllers/MouseController.swift`): CGEvent-based mouse/keyboard control. Handles multi-display coordinate conversion. Requires Accessibility permission.

- **JoyConController** (`Controllers/JoyConController.swift`): Joy-Con Bluetooth HID communication via bundled JoyConSwift library.

- **RadialMenuController/State/View** (`Controllers/RadialMenuController.swift`, `Models/RadialMenu*.swift`, `Views/RadialMenuView.swift`): Joystick-activated pie menu system. Controller runs on HID thread, State/View are `@MainActor`.

### Dual Controller Support

When two Joy-Cons are connected:
- Primary controller handles gyro mouse + primary button mappings
- Secondary controller only sends button inputs with separate mappings
- `inputSettings.primaryControllerId` determines which controller is primary
- Each has independent clutch/scroll/zoom button assignments

### Button Mapping System

`ButtonMappingProfile` maps `LogicalButton` → `ButtonActions` (press + hold actions). Actions can be mouse clicks, keyboard shortcuts, or system actions. Override buttons (clutch/scroll/zoom) bypass normal mappings to convert gyro to drag/scroll/magnify gestures.

## Accessibility Permission

The app requires macOS Accessibility permission for CGEvent posting. If permissions break after code changes:
1. Stop the app
2. System Settings → Privacy & Security → Accessibility
3. Remove JamCon if present, toggle it back on
4. Run `./dev.sh` to reinstall with stable signature
