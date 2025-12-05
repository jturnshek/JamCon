# Gyro Wand

A DIY high-performance wireless gyroscopic pointing device.

## Overview

This project aims to build the "best possible" one-handed gyro mouse with:
- Sub-2ms latency (vs ~15-30ms for Joy-Con Bluetooth)
- 1000Hz+ polling rate
- Rock-solid tracking with minimal drift
- Comprehensive button layout
- 3D printable enclosures

## Project Structure

```
hardware/gyro-wand/
├── README.md           # This file
├── REQUIREMENTS.md     # Detailed specifications
├── firmware/           # nRF52840 firmware (TBD)
├── dongle/             # USB dongle firmware (TBD)
├── enclosures/         # 3D printable designs (TBD)
└── docs/               # Additional documentation (TBD)
```

## Quick Start

See [REQUIREMENTS.md](./REQUIREMENTS.md) for:
- Bill of materials
- Technical specifications
- Development phases
- Architecture overview

## Status

**Phase 1: Core Platform** - Planning

## Related

- [JamCon](../../) - The macOS app that will receive input from this device
- [JoyConSwift](../../Packages/JoyConSwift/) - Reference for gyro processing
