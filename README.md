# JamCon

JamCon is a macOS menu bar app that lets you use Nintendo Switch Joy-Con and PlayStation VR2 Sense controllers as a mouse and keyboard.

It includes a custom Joy-Con HID implementation, low-latency gyro mouse control, and flexible button mappings for macOS.

## What it does

- Gyro mouse control with adaptive smoothing
- Joy-Con and PS VR2 Sense controller support
- Button mapping for clicks, shortcuts, and system actions
- Dual controller mode (primary + secondary)
- Clutch, scroll, zoom, and radial menu modes

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (arm64) Mac
- Joy-Con or PS VR2 Sense controllers
- Bluetooth
- Accessibility permission for input control

## Install

### Homebrew (recommended)

```bash
brew tap jturnshek/tap
brew install --cask jamcon
```

### Direct download

Download the latest `JamCon-<version>.dmg` from the GitHub Releases page and drag the app to `/Applications`.

## Quick start

1. Pair your controller in System Settings > Bluetooth.
2. Launch JamCon and grant Accessibility permission when prompted.
3. Use the menu bar icon to configure mappings and settings.

## Development

```bash
git clone https://github.com/jturnshek/JamCon
cd JamCon
xcodegen generate
./dev.sh
```

See docs/DEVELOPMENT.md for full setup details.

## Documentation

- Usage: docs/USAGE.md
- Development: docs/DEVELOPMENT.md
- Architecture: docs/ARCHITECTURE.md
- Troubleshooting: docs/TROUBLESHOOTING.md
- Releasing: RELEASING.md
- HID protocol notes: docs/JoyCon-HID-Protocol.md, docs/Sense-HID-Protocol.md

## Disclaimer

Nintendo, Joy-Con, PlayStation, and PS VR2 are trademarks of their respective owners. JamCon is not affiliated with or endorsed by Nintendo or Sony.

## License

MIT
