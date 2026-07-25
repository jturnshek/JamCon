# JamCon

JamCon is a macOS menu bar app that lets you use Nintendo Switch Joy-Con and PlayStation VR2 Sense controllers as a mouse and keyboard.

It includes a custom Joy-Con HID implementation, low-latency gyro mouse control, and flexible button mappings for macOS.

## What it does

- Gyro mouse control with adaptive smoothing
- Joy-Con and PS VR2 Sense controller support
- Button mapping for clicks, shortcuts, and system actions
- Multi-device management with per-profile settings
- Drag, scroll, and radial menu modes

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (arm64) Mac
- Joy-Con or PS VR2 Sense controllers
- Bluetooth
- Accessibility permission for input control

## Install from source

JamCon does not use hosted build or release automation. Clone the repository
and build it locally:

```bash
git clone https://github.com/jturnshek/JamCon
cd JamCon
brew install xcodegen
xcodegen generate
./dev.sh
```

The build requires Xcode 16 or later and a Developer ID Application or Apple
Development signing identity. `dev.sh` creates a Release build, installs it at
`/Applications/JamCon.app`, and launches it with a stable signature so macOS
Accessibility permission survives subsequent local rebuilds.

## Quick start

1. Pair your controller in System Settings > Bluetooth.
2. Launch JamCon and grant Accessibility permission when prompted.
3. Use the menu bar icon to configure mappings and settings.

## Development

See docs/DEVELOPMENT.md for build, test, signing, and diagnostic details. All
build and validation processes run on the developer's local Mac.

## Documentation

- Usage: docs/USAGE.md
- Development: docs/DEVELOPMENT.md
- Architecture: docs/ARCHITECTURE.md
- Troubleshooting: docs/TROUBLESHOOTING.md
- Releasing: RELEASING.md
- Security: SECURITY.md
- Code of conduct: CODE_OF_CONDUCT.md
- HID protocol notes: docs/JoyCon-HID-Protocol.md, docs/Sense-HID-Protocol.md

## Disclaimer

Nintendo, Joy-Con, PlayStation, and PS VR2 are trademarks of their respective owners. JamCon is not affiliated with or endorsed by Nintendo or Sony.

## License

MIT
