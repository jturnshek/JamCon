# Joy-Con 2 Bluetooth Production Profile

## Scope

JamCon supports a single Joy-Con 2 as a wireless, one-handed controller through
Nintendo's proprietary Bluetooth Low Energy service. The production path uses
common input report `0x05` because it is the only known format with a validated
controls and IMU decoder.

The right Joy-Con 2 (`057E:2066`) has been validated end to end on macOS:

- discovery, management, connection, and reconnect;
- player LED control and idle connection behavior;
- independent Joy-Con 2 button mappings, including the C button;
- analog-stick scrolling and radial-menu input;
- gyro cursor axes, direction, physical scale, filtering, and acceleration; and
- sustained decoded input at approximately 66 reports/second.

The left Joy-Con 2 (`057E:2067`) shares the discovery, transport, report, and
profile infrastructure. Its physical cursor orientation should receive its own
acceptance pass before being described as equally hardware-validated.

## User flow

1. Open JamCon's Devices screen.
2. Hold the Joy-Con 2 SYNC button until its player LEDs chase.
3. Mark the discovered Joy-Con 2 as managed.
4. Hold the controller still briefly while automatic gyro neutral calibration
   settles.

Joy-Con 2 uses a proprietary BLE service and command protocol. It does not
depend on the original Joy-Con HID backend or share the original Joy-Con's
persisted button profile.

## Identity and GATT transport

Nintendo manufacturer data embeds the USB vendor and product IDs:

| Field | Value |
| --- | --- |
| Nintendo vendor ID | `0x057E` |
| Right Joy-Con 2 product ID | `0x2066` |
| Left Joy-Con 2 product ID | `0x2067` |
| Service | `AB7DE9BE-89FE-49AD-828F-118F09DF7FD0` |
| Common input | `AB7DE9BE-89FE-49AD-828F-118F09DF7FD2` |
| Report-rate descriptor | `679D5510-5A24-4DEE-9557-95DF80486ECB` |
| Command write | `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005` |
| Command response | `C765A961-D9D8-4D36-A20A-5315B111836A` |

All CoreBluetooth objects and mutable connection state stay on the dedicated
`JamCon.JoyCon2.BLE` queue. The backend forwards copied bytes and timestamps
through the common `InputDeviceFrame` boundary.

## Initialization

After service and characteristic discovery, JamCon:

1. subscribes to command responses;
2. enables only buttons, analog stick, and IMU (`featureMask = 0x07`);
3. selects player LED one, stopping the pairing-light chase;
4. writes report-rate descriptor value `0x0085`; and
5. subscribes to common input report `0x05`.

Commands are serialized and matched to their responses. Each command and the
report-rate request have bounded retries. Connection attempts back off to avoid
the Joy-Con 2 firmware's reconnect cooldown.

Do not add arbitrary controller commands to this sequence. Production enables
only the features JamCon consumes and deliberately leaves the optical sensor,
magnetometer, current telemetry, and unknown feature bits disabled.

## Common report `0x05`

CoreBluetooth delivers the report payload without a USB report-ID byte.

| Offset | Size | Meaning |
| ---: | ---: | --- |
| `0x04` | 4 | Buttons |
| `0x0A` | 3 | Left analog stick |
| `0x0D` | 3 | Right analog stick |
| `0x30` | 2 | Accel X |
| `0x32` | 2 | Accel Y |
| `0x34` | 2 | Accel Z |
| `0x36` | 2 | Gyro X |
| `0x38` | 2 | Gyro Y |
| `0x3A` | 2 | Gyro Z |

Motion fields are little-endian signed 16-bit integers. A single zero-filled
startup report is ignored while the IMU becomes active.

`JoyCon2BLEProtocol.controlBytes` converts the common button and stick fields to
the established Joy-Con family layout consumed by application-level mappings.
The original BLE bytes remain attached to the frame for bounded live
diagnostics.

## Gyro profile

The Joy-Con 2 IMU operates at an approximately ±2,000 degrees/second range.
Production converts raw gyro counts with:

```text
34.8 radians/second × 180/π ÷ 32767
= 0.0608506463 degrees/second/count
```

This agrees with current SDL and `everything-imu` implementations. A physical
360-degree reference turn integrated to 339.6 degrees with this coefficient,
within 5.7% of the hand-executed target. The earlier provisional coefficient
integrated the same turn to only 41.9 degrees and was removed along with its
2× cursor-sensitivity compensation.

For the validated right-hand grip:

| Cursor semantic | Raw gyro axis |
| --- | --- |
| Vertical pitch | X |
| Horizontal yaw | Z |
| Roll | Y |

With the physical coefficient fixed, the normal Joy-Con gyro defaults work
without Joy-Con 2-specific sensitivity tuning. Transport cadence changes must
not change cursor distance for the same physical motion.

## Measured cadence and latency

The controller's `0x0085` descriptor value is a request, not proof of 133
outward reports/second. On the validated Joy-Con 2/macOS combination:

- the initial CoreBluetooth override value `6` negotiates a 15 ms BLE link;
- common report `0x05` delivers one notification per connection event;
- observed delivery stabilizes around 66–67 reports/second;
- input-engine queue latency is normally about 0.05–0.08 ms; and
- processing is normally about 0.03–0.07 ms.

Bluetooth profile logs proved the 15 ms link is the limiting boundary. The
decoder, engine queue, and mouse-event path are not withholding a second sample.
Production therefore reports its measured motion sample rate instead of
pretending the requested descriptor value is the delivered rate.

## Rejected production paths

Native report `0x07`/`0x08` contains a 40-byte packed motion block with no
validated public decoder. Native and common input are controller-global,
mutually exclusive formats even when both notification descriptors are
enabled. Native delivery also remained approximately 66 reports/second on the
tested macOS link.

CoreBluetooth's post-connection low-latency preset offered a broad interval
range and allowed the controller to select 30 ms, reducing delivery to roughly
33 reports/second. Updating private connection options after connection did not
issue an HCI parameter update. Neither behavior belongs in production.

An ordinary Bluetooth dongle still controlled by macOS would use the same
CoreBluetooth policy and is not expected to improve this. A future wireless
higher-rate experiment would need either:

- a separately owned BLE central that requests an exact 7.5 ms connection and
  forwards decoded common reports to JamCon; or
- a trustworthy decoder for the native packed motion block.

Neither experiment is part of the production application.

## Code map

- `Devices/JoyCon2BLEProtocol.swift`: identity, commands, report decoding,
  physical constants, rate policy, and cadence estimation.
- `Devices/JoyCon2BLESession.swift`: CoreBluetooth lifecycle, initialization,
  report-rate request, reconnect policy, and notification delivery.
- `Devices/JoyCon2BLEInputDeviceBackend.swift`: managed-device state and common
  `InputDeviceFrame` emission.
- `Engine/InputEngine+JoyCon.swift`: shared application mappings, gyro policy,
  cursor routing, and bounded live diagnostics.
- `JoyConButtonMapping.swift`: independent Joy-Con 2 profile mappings.
- `Tests/JamConTests/JoyCon2BLEInputDeviceBackendTests.swift`: protocol,
  profile, cadence, decoder, and backend-contract coverage.

## External protocol references

- [Switch 2 controller protocol research](https://github.com/ndeadly/switch2_controller_research)
- [SDL Switch 2 driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch2.c)
- [everything-imu Joy-Con 2 driver](https://github.com/matiaspalmac/everything-imu/blob/main/crates/device-joycon/src/jc2.rs)
