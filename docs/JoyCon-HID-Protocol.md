# Joy-Con HID Protocol (Bluetooth, Standard Full 0x30)

Observations captured from Joy-Con controllers on macOS (Bluetooth), report ID 0x30 (~49 bytes).

## Transport Lifecycle

- Discovery uses an independent-device `IOHIDManager`; enumeration alone does not open or schedule a controller.
- A Joy-Con is seized and scheduled only after the user marks its stable device identity as managed.
- Queued activation revalidates both the managed selection and the exact discovered transport handle before and after opening, so removal or replacement cannot activate a stale device.
- Startup failure returns the backend to a stopped state and can be retried. Stop unregisters callbacks, unschedules devices, closes each active registration once, and retains the user's managed selections for the next start.
- Raw IOKit objects and report buffers stay inside `IOKitJoyConHIDTransport`; the controller and tests use opaque shared HID handles.

## Initialization

After a managed device is opened, JamCon sends output report `0x01` subcommands in this order:

1. `0x40 0x01` — enable IMU
2. `0x03 0x30` — select standard full input mode
3. `0x48 0x01` — enable vibration
4. `0x30 0x01` — set player light 1

The four reports use packet counters 0 through 3 and a neutral rumble payload.

## Report Structure

- Report length: 49 bytes
- Byte 0: Report ID (0x30)
- Byte 1: Packet counter/timer
- Byte 2: Battery level (upper nibble)
- Bytes 3-5: Button data (layout differs by controller side)
- Bytes 6-8: Left stick (12-bit packed)
- Bytes 9-11: Right stick (12-bit packed)
- Bytes 13-48: IMU data (3 samples × 12 bytes each: accel XYZ + gyro XYZ, all int16 LE)

## Right Joy-Con (Product ID 0x2007)

### Buttons - Byte 3
| Bit | Mask | Button |
|-----|------|--------|
| 0   | 0x01 | Y      |
| 1   | 0x02 | X      |
| 2   | 0x04 | B      |
| 3   | 0x08 | A      |
| 4   | 0x10 | SR     |
| 5   | 0x20 | SL     |
| 6   | 0x40 | R      |
| 7   | 0x80 | ZR     |

### Buttons - Byte 4
| Bit | Mask | Button      |
|-----|------|-------------|
| 1   | 0x02 | Plus        |
| 2   | 0x04 | Stick click |
| 4   | 0x10 | Home        |

### Stick
- Bytes 9-11: 12-bit packed values
- X = byte9 | ((byte10 & 0x0F) << 8)
- Y = (byte10 >> 4) | (byte11 << 4)
- Center: ~2048, Range: 0-4095

## Left Joy-Con (Product ID 0x2006)

### Buttons - Byte 4
| Bit | Mask | Button      |
|-----|------|-------------|
| 0   | 0x01 | Minus       |
| 3   | 0x08 | Stick click |
| 5   | 0x20 | Capture     |

### Buttons - Byte 5
| Bit | Mask | Button   |
|-----|------|----------|
| 0   | 0x01 | D-pad Down  |
| 1   | 0x02 | D-pad Up    |
| 2   | 0x04 | D-pad Right |
| 3   | 0x08 | D-pad Left  |
| 4   | 0x10 | SR       |
| 5   | 0x20 | SL       |
| 6   | 0x40 | L        |
| 7   | 0x80 | ZL       |

### Stick
- Bytes 6-8: 12-bit packed values
- X = byte6 | ((byte7 & 0x0F) << 8)
- Y = (byte7 >> 4) | (byte8 << 4)
- Center: ~2048, Range: 0-4095

## IMU Data

Each report contains 3 IMU samples (oldest to newest). Each sample is 12 bytes:
- Bytes 0-1: Accel X (int16 LE)
- Bytes 2-3: Accel Y (int16 LE)
- Bytes 4-5: Accel Z (int16 LE)
- Bytes 6-7: Gyro X (int16 LE)
- Bytes 8-9: Gyro Y (int16 LE)
- Bytes 10-11: Gyro Z (int16 LE)

Sample offsets: 13, 25, 37 (use sample at 37 for latest data)

### Axis Mapping (for mouse control)
- Gyro X → Roll (wrist twist)
- Gyro Y → Pitch (up/down tilt) - **negate for correct direction**
- Gyro Z → Yaw (left/right pointing)

Gyro scale: 0.06103 °/s per LSB

## Battery
Upper nibble of byte 2 encodes battery level:
- 0x8: Full
- 0x6: Medium
- 0x4: Low
- 0x2: Critical
