# PSVR2 Sense Controller HID Protocol

This document describes the HID report structure for the PlayStation VR2 Sense Controller when connected via Bluetooth to macOS.

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
| 5 | Trigger Capacitive | Touch sensor on trigger |
| 6-8 | Unknown | |
| 9 | Face Buttons | Circle, X, Grip (bit-packed) |
| 10 | System Buttons | Joystick click, Start/Share, PlayStation button |
| 11 | Joystick Capacitive | Touch sensor on joystick |
| 12-16 | Unknown | |
| 17-30 | IMU Data | Accelerometer + Gyroscope (constantly changing) |
| 31-77 | Unknown | May include additional sensors, battery, etc. |

### Byte 4 - Trigger (R2)

Analog value: 0-255 (0x00-0xFF)
- 0 = not pressed
- 255 = fully pressed

### Byte 9 - Face Buttons (Bit-packed)

| Bit | Mask | Button |
|-----|------|--------|
| 5 | 0x20 | Grip (R1) |
| 2 | 0x04 | Circle |
| 1 | 0x02 | X |

### Byte 10 - System Buttons (Bit-packed)

| Bit | Mask | Button |
|-----|------|--------|
| 1 | 0x02 | Start/Options |
| ? | ? | Joystick Click (L3/R3) |
| ? | ? | PlayStation |

Note: Values are additive when multiple buttons pressed.

**Warning**: The PlayStation button triggers Apple Arcade on macOS. This may require system-level handling or may be incompatible with our use case.

### Bytes 17-30 - IMU Data

The gyroscope data is read as signed 16-bit little-endian integers:
- Gyro X: Bytes 17-18
- Gyro Y: Bytes 19-20
- Gyro Z: Bytes 21-22
- Accelerometer data likely in bytes 23-30

These bytes change constantly and are used for motion/pointing control.

### Capacitive Sensors

The PSVR2 Sense Controller has capacitive touch sensors:
- **Byte 5**: Trigger finger presence detection
- **Byte 11**: Thumb presence on joystick

These detect whether the user is touching the control without necessarily pressing it.

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

**Movement-only bytes** (change when moving, stable when still):
- 17, 18, 20, 22, 24, 26, 28
- These are likely **accelerometer** data (responds to physical movement/gravity changes)

**Always-noisy bytes** (change even when still):
- 1, 13, 19, 21, 23, 25, 27, 29, 30, 31, 33
- 49, 50, 51, 57, 58, 59, 60, 61, 62, 63, 64
- 74, 75, 76, 77
- These likely include **gyroscope** data (has inherent drift/noise) and possibly other sensors

**Observations:**
- Byte 1: Possibly a sequence counter or timestamp
- Byte 13: Unknown - always noisy
- Bytes 17-31: IMU cluster (mix of accel/gyro)
- Bytes 49-51, 57-64: Unknown sensor cluster - possibly second IMU or other sensors
- Bytes 74-77: Unknown - tail of report, possibly checksums or additional sensor data
- Byte 33: Only appears in "still" list - may be touch/capacitive related

**Static bytes** (never change - reserved/unused):
- 0, 7, 8, 12, 15, 16
- 34-48 (entire range)
- 53-56
- 65-73 (entire range)

These are likely padding, reserved for future use, or features only active when connected to the VR headset.

**Active input bytes** (confirmed button/analog input):
- 2, 3: Joystick X/Y
- 4: Trigger analog
- 5: Trigger capacitive
- 6: Unknown (possibly grip analog?)
- 9: Face buttons (Circle, X, Grip)
- 10: System buttons (Joystick click, Start, PS)
- 11: Joystick capacitive

### Periodic/Pulsing Bytes

Some bytes pulse at regular intervals rather than changing continuously:

| Byte | Pulse Rate | Possible Function |
|------|------------|-------------------|
| 14 | Every few seconds | Battery status? Heartbeat? |
| 32 | Every few seconds | Status/sync signal? |
| 52 | Every few seconds | Status/sync signal? |
| 17 | ~1 Hz (once per second) | Timing signal? Low-frequency sensor? |

These periodic bytes likely represent:
- Battery level updates
- Connection keepalive/heartbeat signals
- Temperature or other slow-changing sensors
- Timing synchronization data

## Known Issues

1. **PlayStation Button**: Opens Apple Arcade on macOS instead of being available to the application. May require:
   - System-level key remapping
   - Disabling the Apple Arcade shortcut
   - Accepting this button is unavailable

## TODO

- [ ] Determine exact bit positions for buttons in bytes 9 and 10
- [ ] Map accelerometer data bytes
- [ ] Investigate bytes 31-77 for additional features
- [ ] Test with both left and right controllers
- [ ] Document any differences between left/right controller reports

## References

- DualSense controller protocol (similar Sony controller)
- IOKit HID documentation
