# PlayStation Sense Controller HID Protocol

This document describes the HID report structure for the PlayStation Sense Controller (from PSVR2) when connected via Bluetooth to macOS.

## Device Identification

| Property | Value |
|----------|-------|
| Vendor ID | 0x054C (Sony) |
| Product ID (Left) | 0x0E45 |
| Product ID (Right) | 0x0E46 |
| Report ID | 0x31 |
| Report Length | 78 bytes |
| Report Rate | ~60 Hz |

## Report Structure

### Byte Map

| Byte(s) | Function | Notes |
|---------|----------|-------|
| 0-1 | Unknown | Header/sequence? |
| 2 | Joystick X | Analog position |
| 3 | Joystick Y | Analog position |
| 4 | Primary Trigger | Analog + digital |
| 5 | Trigger Proximity | Proximity sensor on trigger (0-255, detects finger before touch) |
| 6 | Grip Capacitive | Touch sensor on grip (0-255) |
| 7-8 | Unknown | |
| 9 | Face Buttons | Circle, X, Grip (bit-packed) |
| 10 | System Buttons | Joystick click, Start/Share, PlayStation button |
| 11 | Touch States | Bit-packed: Joystick touch (bit 2), Grip touch (bit 3) |
| 12-16 | Unknown | |
| **17-22** | **Gyroscope** | **CONFIRMED: 3× signed Int16 LE (X, Y, Z)** |
| **23-28** | **Accelerometer** | **CONFIRMED: 3× signed Int16 LE (X, Y, Z), ~4096/g** |
| 29-30 | Unknown | Part of IMU cluster |
| 31-42 | Unknown | |
| **43** | **Battery Level** | **CONFIRMED: Lower nibble × 10 = percentage (0-100%)** |
| 44 | Unknown | Possibly charger-related |
| 45-77 | Unknown | May include additional sensors |

### Byte 4 - Trigger (R2)

Analog value: 0-255 (0x00-0xFF)
- 0 = not pressed
- 255 = fully pressed

### Byte 9 - Face Buttons (Bit-packed)

Buttons differ by controller side:

| Bit | Mask | Right Controller | Left Controller |
|-----|------|------------------|-----------------|
| 0 | 0x01 | - | Square |
| 1 | 0x02 | X | - |
| 2 | 0x04 | Circle | - |
| 3 | 0x08 | - | Triangle |
| 4 | 0x10 | - | Grip (L1) |
| 5 | 0x20 | Grip (R1) | - |

### Byte 10 - System Buttons (Bit-packed)

Buttons differ by controller side:

| Bit | Mask | Right Controller | Left Controller |
|-----|------|------------------|-----------------|
| 0 | 0x01 | - | Create |
| 1 | 0x02 | Options | - |
| 2 | 0x04 | - | L3 (Stick Click) |
| 3 | 0x08 | R3 (Stick Click) | - |
| 4 | 0x10 | PlayStation ⚠️ | PlayStation ⚠️ |

Note: Values are additive when multiple buttons pressed.

**Warning**: The PlayStation button (0x10) triggers Apple Arcade on macOS. The HID report shows the button press, but macOS also intercepts it at the system level.

### Bytes 17-28 - IMU Data (CONFIRMED)

The IMU data is encoded as signed 16-bit little-endian integers:

#### Gyroscope (Bytes 17-22) - CONFIRMED

| Bytes | Axis | Notes |
|-------|------|-------|
| 17-18 | X | Angular velocity |
| 19-20 | Y | Angular velocity |
| 21-22 | Z | Angular velocity |

**Validation:** At rest, gyroscope values read near zero (typically -5 to +5).

#### Accelerometer (Bytes 23-28) - CONFIRMED

| Bytes | Axis | Notes |
|-------|------|-------|
| 23-24 | X | Linear acceleration |
| 25-26 | Y | Linear acceleration |
| 27-28 | Z | Linear acceleration |

**Scaling:** ~4096 per g (different from DualSense which uses ~8192/g)

**Validation:** At rest on a flat surface, one axis shows ~4000 (gravity), others near zero. Flipping the controller inverts the gravity axis sign.

Example readings:
- Controller upright: Z ≈ -3120 (gravity pointing down)
- Controller flipped: Z ≈ +3880 (gravity pointing up)

These bytes are used for motion/pointing control.

### Capacitive / Proximity Sensors

The PSVR2 Sense Controller has capacitive and proximity sensors:
- **Byte 5**: Trigger proximity (0-255) - Can detect finger before touching
- **Byte 6**: Grip capacitive (0-255) - How much of the grip is covered
- **Byte 11**: Binary touch states (bit-packed)
  - Bit 2 (0x04): Joystick touch
  - Bit 3 (0x08): Grip touch

Bytes 5 and 6 are analog values. Byte 11 is digital on/off states.

### Byte 43 - Battery Level (CONFIRMED)

The battery level is encoded in the lower nibble of byte 43:

```
Battery % = (byte43 & 0x0F) × 10
```

| Lower Nibble | Battery Level |
|--------------|---------------|
| 0x00 | 0% |
| 0x05 | 50% |
| 0x09 | 90% |
| 0x0A | 100% |

The upper nibble (byte43 >> 4) may contain charging status flags, but this is unconfirmed.

## Byte Activity Observations

### Bytes Changing When Controller is Moving

When the controller is physically moved/rotated, these bytes show activity:

```
1, 13, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
49, 50, 51, 57, 58, 59, 60, 61, 62, 63, 64, 74, 75, 76, 77
```

### Bytes Changing When Controller is Completely Still

Even when the controller is stationary, these bytes continue to change:

```
1, 13, 19, 21, 23, 25, 27, 29, 30, 31, 33,
49, 50, 51, 57, 58, 59, 60, 61, 62, 63, 64, 74, 75, 76, 77
```

### Analysis

**IMU Layout (CONFIRMED):**
- Bytes 17-22: **Gyroscope** (angular velocity, near-zero at rest)
- Bytes 23-28: **Accelerometer** (shows gravity ~4096/g at rest)

**Byte Activity Explanation:**
- The gyroscope bytes (17-22) show slight noise/drift even at rest due to sensor characteristics
- The accelerometer bytes (23-28) show stable gravity readings when still, change with movement
- Other noisy bytes (49-64, 74-77) may be a second IMU or other sensors

**Observations:**
- Byte 1: Possibly a sequence counter or timestamp
- Byte 13: Unknown - always noisy
- Bytes 49-51, 57-64: Unknown sensor cluster - possibly second IMU or other sensors
- Bytes 74-77: Unknown - possibly checksums (CRC32 claim not confirmed)
- Byte 33: Only appears in "still" list - may be touch/capacitive related

**Static bytes** (never change - reserved/unused):
- 0, 7, 8, 12, 15, 16
- 34-48 (entire range)
- 53-56
- 65-73 (entire range)

These are likely padding, reserved for future use, or features only active when connected to the VR headset.

**Active input bytes** (confirmed button/analog input):
- 2, 3: Joystick X/Y (0-255, center ~128)
- 4: Trigger analog (0-255)
- 5: Trigger proximity (0-255, detects finger before touch)
- 6: Grip capacitive (0-255)
- 9: Face buttons (Circle bit 2, X bit 1, Grip bit 5)
- 10: System buttons (Joystick click bit 3, Start bit 1, PS bit 4)
- 11: Touch states (Joystick bit 2, Grip bit 3)

### Connection Timer Bytes

Some bytes increment slowly and reset when Bluetooth reconnects:

| Byte | Initial Value | Notes |
|------|---------------|-------|
| 14 | ~48 | Increments slowly, starts at offset |
| 32 | 0 | Increments from 0 on connection |
| 52 | 0 | Increments from 0 on connection |

These are likely connection uptime counters or session timers, not battery status.

## Timestamps

The HID driver exposes a vendor-defined input element that carries the 0x31 IMU report:
- Usage page: `0xFF00`
- Usage: `0x003B`
- Report ID: `0x31`
- Length: 77 bytes

Registering an input value callback (`IOHIDDeviceRegisterInputValueCallback`) surfaces this element with a kernel-provided monotonic timestamp via `IOHIDValueGetTimeStamp(value)`. That timestamp belongs to the value callback, however, while JamCon consumes the separate raw-report callback. The two callback streams have no sequence identifier that can associate a value timestamp with one specific raw report safely.

Time conversion: `IOHIDValueGetTimeStamp` returns mach absolute ticks. Convert using `mach_timebase_info` (e.g., numer=125, denom=3 on Apple Silicon) and `ticksToSeconds = ticks * numer/denom / 1e9` for accurate per-report timing.

JamCon therefore timestamps Sense reports at raw callback entry with `CACurrentMediaTime()`. This is an honest host-receipt timestamp: it is suitable for gyro `dt` and queue/processing measurements, but it is not presented as device input age. A future Game Controller backend may provide an unambiguously associated event timestamp.

## JamCon Transport Lifecycle

- The IOKit manager uses independent-device discovery and does not open every enumerated controller.
- JamCon registers as a background Game Controller client before starting HID discovery and activates native motion sensors when the framework requires it. This gives the macOS PS VR2 service plugin ownership of device initialization, input delivery, and Bluetooth session policy.
- IOKit is used only to discover Sense hardware and retain its stable serial-derived identity. JamCon does not open the raw device: testing confirmed that both exclusive and non-exclusive raw opens terminate the Sense Bluetooth session after a few seconds.
- Native motion, buttons, thumbstick, trigger, and battery values are normalized into JamCon's existing Sense input-frame representation before entering the shared engine pipeline.
- Queued activation revalidates both managed state and the current transport handle, so an unmanage or removal event cannot reopen a stale device.
- Input callbacks, raw IOKit references, scheduling, and close operations stay on the dedicated Sense HID thread.
- Manager startup failure tears down partial resources and leaves the backend stopped and retryable.
- Device identity prefers the existing serial-number format, then the physical-device unique ID. Location and registry identifiers are collision-resistant fallbacks when neither is available.

### Raw report bytes vs timestamps

- Bytes 0–1: fast 16-bit counter (~265k ticks/sec inferred when reconstructed across wraps). Wraps every ~15 ms and is noisy; not suitable as a `dt` source without heavy reconstruction. JamCon uses raw callback-entry time.
- Bytes 14/32/52 and other “unknown” bytes (29–31, 74–77, 49–64) show noisy deltas and frequent wraps; no clean per-report sequence or timer found.
- Conclusion: use raw callback-entry time for `dt`; treat the separately delivered HID value timestamp and byte-level counters as diagnostic only unless a reliable report association is discovered.

## Known Issues

1. **PlayStation Button**: Opens Apple Arcade on macOS instead of being available to the application. May require:
   - System-level key remapping
   - Disabling the Apple Arcade shortcut
   - Accepting this button is unavailable

2. **Output Reports (Haptics/LEDs)**: DualSense-style output reports do not work over Bluetooth. Guessed output support is intentionally not shipped; reintroduce it only through a verified protocol or a framework-provided capability.

## Unconfirmed Claims (from other projects)

The following claims from PSVR2-controller-explorer and similar projects were tested but **NOT confirmed**:

| Claim | Bytes | Result |
|-------|-------|--------|
| CRC32 checksum | 74-77 | Never matched computed CRC |
| Trigger feedback motor | 41 | No activity observed |
| Adaptive trigger mode | 42 | No activity observed |
| Haptic output reports | - | No effect over Bluetooth |
| LED control | - | No effect over Bluetooth |

These features may only work when connected via USB or to the VR headset.

## TODO

- [ ] Determine exact bit positions for buttons in bytes 9 and 10
- [x] Map accelerometer data bytes - **CONFIRMED at bytes 23-28**
- [x] Map gyroscope data bytes - **CONFIRMED at bytes 17-22**
- [ ] Investigate bytes 31-77 for additional features
- [ ] Test with both left and right controllers
- [ ] Document any differences between left/right controller reports
- [ ] Investigate output reports for haptics/LEDs (not working over Bluetooth)

## References

- DualSense controller protocol (similar Sony controller)
- IOKit HID documentation
