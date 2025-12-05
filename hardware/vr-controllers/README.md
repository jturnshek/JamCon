# VR Controllers for Desktop Pointing

Exploration of using VR ecosystem controllers as high-quality gyro pointing devices for desktop mouse control.

## Why VR Controllers?

VR controllers solve the core problems with consumer air mice:

1. **No hardcoded presentation buttons** - Standard gamepad inputs, fully remappable
2. **High-quality IMUs** - Gyro + accelerometer with sensor fusion
3. **Proven ecosystems** - Valve's gyro-to-mouse implementation is excellent
4. **Good ergonomics** - Designed for extended use
5. **Rich inputs** - Triggers, thumbsticks, buttons, touchpads

## Paths Explored

| Path | Status | Pros | Cons |
|------|--------|------|------|
| [Index + Lighthouse](#valve-index--lighthouse) | Available now | Best tracking, proven | Needs base station, expensive |
| [Steam Frame Controllers](#steam-frame-controllers) | Q1 2026 | Gamepad layout, modern | Not released yet |

---

## Valve Index + Lighthouse

Use Index "Knuckles" controllers with Lighthouse base stations and libsurvive.

### How It Works

```
Base Station (wall) ──IR laser sweeps──► Index Controller (hand)
                                              │
        No PC connection needed               │ 2.4GHz wireless
        Just emits IR light                   │
                                              ▼
                                         USB Dongle ──► Mac
```

- Base stations emit IR laser sweeps (standalone, just need power)
- Controller photodiodes detect sweeps, calculate position
- Controller sends pose + inputs via 2.4GHz to USB dongle
- **libsurvive** reads from dongle without SteamVR

### Sensors

| Sensor | Purpose | Rate |
|--------|---------|------|
| Gyroscope | Fast rotation tracking | ~1000Hz |
| Accelerometer | Gravity reference | ~1000Hz |
| Lighthouse photodiodes | Absolute position | ~60-120Hz |

Sensor fusion combines all three: IMU provides fast response, Lighthouse corrects drift.

### Software Stack

- [libsurvive](https://github.com/collabora/libsurvive) - Open source Lighthouse tracking (no SteamVR needed)
- Custom app to convert pose → mouse input
- Or: SteamVR + Steam Input for gyro-to-mouse

### Hardware Required

| Item | New Price | Used Price | Notes |
|------|-----------|------------|-------|
| Base Station 2.0 | $150 | ~$100 | Only 1 needed for basic tracking |
| Index Controller (single) | N/A (pairs only) | ~$100-150 | Either hand works |
| USB Dongle | Included | Included | Comes with controller |

**Total: ~$200-300 used**

### Purchasing

- **eBay**: [Index Controllers](https://www.ebay.com/shop/valve-index-controller) - Single controllers available
- **Tundra Labs**: [Refurbished accessories](https://tundra-labs.com/collections/valve-index-accessories)
- **r/hardwareswap**: Community marketplace

### Index Controller Inputs

- Trigger (analog)
- Grip (force-sensing)
- Thumbstick (clickable)
- A/B buttons
- System button
- Trackpad (touch + click)
- Finger tracking (capacitive)

### Considerations

- **Pro**: Sub-millimeter tracking, no drift, excellent build quality
- **Pro**: Finger tracking for additional input possibilities
- **Con**: Requires line-of-sight to base station
- **Con**: Not portable (fixed room setup)
- **Con**: Index discontinued, prices may rise as Steam Frame releases

---

## Steam Frame Controllers

Valve's next-generation VR controllers, announced November 2025, launching Q1 2026.

### Key Features

- **Designed for non-VR games** - Full gamepad layout (D-pad, ABXY, thumbsticks, triggers)
- **6-DOF tracking** - Via headset cameras (inside-out tracking)
- **Internal IMU** - Gyro + accelerometer for sensor fusion
- **Magnetic thumbsticks** - Resistant to drift
- **Capacitive finger sensing**
- **40-hour battery** - AA batteries
- **Four programmable grip buttons**

### Form Factor

```
      ┌─────────────┐
      │   D-pad /   │  ← Left: D-pad + thumbstick
      │   ABXY      │  ← Right: ABXY + thumbstick
      │  thumbstick │
      │   ◉    ◉    │  ← Triggers underneath
      └──────┬──────┘
             │
             │  ← Grip handle (wand-style)
             │
             └
```

Ergonomic "lollipop" shape - perfect for one-handed wand use.

### For Desktop Use (Speculation)

If Steam Frame controllers work like Steam Controller:

1. Connect via 2.4GHz USB dongle (likely included or sold separately)
2. Appear as standard gamepad to system
3. Gyro exposed via Steam Input
4. Use JoyShockMapper or Steam Input for gyro-to-mouse

**This would be ideal** - standard gamepad with high-quality gyro, no weird button mappings, Valve's proven gyro implementation.

### Unknown Factors

- Will controllers be sold separately?
- Will they work without the headset for 6DOF? (Probably not - inside-out tracking needs headset cameras)
- Will gyro work standalone? (Almost certainly yes - IMU is onboard)
- Price?

### Recommendation

**Wait for Q1 2026 launch details.** If controllers work standalone with gyro, this is likely the cleanest solution.

---

## Comparison

| Factor | Index + Lighthouse | Steam Frame | DIY Gyro Wand |
|--------|-------------------|-------------|---------------|
| **Availability** | Now (used) | Q1 2026 | Build yourself |
| **Cost** | ~$200-300 | TBD | ~$84 |
| **Tracking** | 6DOF (optical + IMU) | 6DOF w/ headset, 3DOF without | 3DOF (gyro only) |
| **Drift** | None (optical corrects) | None w/ headset, minimal w/o | Needs recalibration |
| **Portability** | Fixed room | Unknown | Anywhere |
| **Inputs** | Excellent | Excellent (gamepad layout) | Custom |
| **Software** | libsurvive + custom | Steam Input (likely) | Custom firmware |
| **Setup Complexity** | Medium (mount base station) | Low (expected) | High (build + code) |

---

## Next Steps

1. **Monitor Steam Frame launch** (Q1 2026) for controller standalone functionality
2. **Consider Index controller** if immediate solution needed
3. **Continue DIY wand** as fallback / portable option

---

## References

- [libsurvive - GitHub](https://github.com/collabora/libsurvive)
- [Valve Index Controllers](https://www.valvesoftware.com/en/index/controllers)
- [Steam Frame Announcement - PC Gamer](https://www.pcgamer.com/hardware/vr-hardware/steam-frame-specs-availability/)
- [Steam Frame Controllers - UploadVR](https://www.uploadvr.com/valve-steam-frame-official-announcement-features-details/)
- [How to Use Vive Tracker Without Headset - Road to VR](https://www.roadtovr.com/how-to-use-the-htc-vive-tracker-without-a-vive-headset/)

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-04 | Initial exploration document |
