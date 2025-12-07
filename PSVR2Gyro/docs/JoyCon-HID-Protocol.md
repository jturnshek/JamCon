# Joy-Con HID Protocol (Bluetooth, Standard Full 0x30)

Observations captured from a right Joy-Con on macOS (Bluetooth), report ID 0x30 (~49 bytes). This is a working notebook; masks/values to be confirmed.

## High-Level State
- Report length observed: 49 bytes
- Always-ticking (changes even when idle on table): 1, 9, 10, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 35, 37, 39, 41, 43, 45, 47 (likely sequence/timers/IMU samples)
- Stable in all observations so far: 0, 2, 5, 6, 7, 8, 12
- When moving controller (gyro/accel): all bytes except 0, 2, 3, 4, 5, 6, 7, 8, 11, 12 update at high rate
- Right stick movement: byte 11 updates continuously

## Inputs Mapped (Right Joy-Con)
- Byte 3 (bits confirmed):
  - Y = 0x01
  - X = 0x02
  - B = 0x04
  - A = 0x08
  - SR (right) = 0x10
  - SL (right) = 0x20
  - R bumper = 0x40
  - ZR trigger = 0x80
- Byte 4 (bits confirmed):
  - Plus = 0x02
  - Stick click (R3) = 0x04
  - Home/Menu = 0x0A  (observed; implies bits 0x02 + 0x08 set)
- Bytes 9, 10, 11: right stick (all three participate; 9/10 flicker, 11 shows clear movement)
  - Center jitter (byte 11): ~0x48–0x4A (72–74)
  - Center jitter (byte 9): ~0x60–0x79 (samples seen: 0x65, 0x5E, 0x7A, 0x7E, 0x78, 0x79, 0x70)
  - Center jitter (byte 10): ~0x80–0x98 (samples seen: 0x98, 0x68, 0x58, 0x78, 0x8A, 0x8C, 0x83, 0x82, 0x80)
  - Full up (byte 11): ~0xBE–0xBF
  - Full down (byte 11): ~0x2D–0x2E
  - Full left (byte 11): ~0x80 (approx)
  - Full right (byte 11): ~0x7E (approx)
  - Hypothesis: standard Joy-Con 12-bit packing shifted by +1 byte (i.e., X = byte9 | ((byte10 & 0x0F) << 8), Y = (byte10 >> 4) | (byte11 << 4)). Observed values (up/down/left/right) fit this pattern roughly.

## TBD / Needs Masking
- Bit masks for byte 3 (A/B/X/Y/R/ZR/stick click)
- Bit masks for byte 4 (Plus, Home) → masks now observed; need to disambiguate Home exact bit (currently 0x0A observed)
- Stick center/min/max values (byte 11 packing)
- Confirm no action on bytes 0, 2, 5, 6, 7, 8, 12 across more scenarios

## Battery
- Battery byte (offset 2) upper nibble encodes level; current mapping in code uses coarse nibble mapping.
