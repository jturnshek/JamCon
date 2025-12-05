# Gyro Wand - Hardware Requirements

A high-performance wireless gyroscopic pointing device for precision mouse control.

## Project Goals

Build a "best possible" one-handed gyro pointing device with:
- Rock-solid tracking with minimal drift
- Sub-2ms end-to-end latency
- Comprehensive button layout for productivity/gaming
- Expandable design for iteration
- 3D printable enclosures

---

## Phase 1: Core Platform (MVP)

Get tracking and connectivity working perfectly before adding complexity.

### 1.1 Microcontroller

| Requirement | Specification | Rationale |
|-------------|---------------|-----------|
| Chip | nRF52840 | Proven in gaming mice, Nordic ShockBurst, USB HID |
| Dev Board | nRF52840 DK or Adafruit Feather nRF52840 | Good GPIO count, battery charging built-in |
| Clock | 64 MHz Cortex-M4F | Sufficient for 8kHz sensor polling |
| GPIO | 20+ available | Room for 12 buttons + joystick + IMU |
| Flash | 1 MB | Plenty for firmware + calibration storage |
| RAM | 256 KB | Sufficient for sensor buffers |

**Dongle:** Seeed XIAO nRF52840 (USB-C, tiny form factor)

### 1.2 IMU Sensor

| Requirement | Specification | Rationale |
|-------------|---------------|-----------|
| Chip | ICM-45686 (primary) or BMI270 (backup) | Best drift performance per SlimeVR testing |
| Interface | SPI (not I2C) | Lower latency, ~50μs reads |
| Sample Rate | 4000 Hz minimum | Oversample and average for noise reduction |
| Gyro Range | ±2000 °/s | Covers fast wrist movements |
| Accel Range | ±16g | For sensor fusion / orientation |
| FIFO | Required | Buffer samples during radio TX |

**Breakout options:**
- SparkFun ICM-20948 (different chip but available)
- Adafruit LSM6DSOX (good alternative)
- Custom PCB with ICM-45686 (later phase)

### 1.3 Wireless Link

| Requirement | Specification | Rationale |
|-------------|---------------|-----------|
| Protocol | Nordic ShockBurst (ESB) or Gazell | Sub-1ms latency, proven |
| Frequency | 2.4 GHz | Standard, good range |
| Data Rate | 2 Mbps | Plenty for HID data |
| Polling Rate | 1000 Hz minimum | Match gaming mice |
| Payload | 12-32 bytes | dx, dy, buttons, battery, etc. |
| Range | 5+ meters | Desk to couch |

### 1.4 Power

| Requirement | Specification | Rationale |
|-------------|---------------|-----------|
| Battery | LiPo 400-600 mAh | Balance of weight and runtime |
| Runtime | 20+ hours | Multi-day use between charges |
| Charging | USB-C, 500mA | Fast enough, standard connector |
| Sleep Mode | <10 μA | Weeks of standby |
| Low Battery | LED or vibration warning | User feedback |

### 1.5 Phase 1 Buttons (Minimal)

| Button | Location | Purpose |
|--------|----------|---------|
| Trigger | Index finger (top) | Primary click / clutch |
| Secondary | Index finger (side) | Right click |
| Power | Recessed | On/off/pairing |

### 1.6 Phase 1 Deliverables

- [ ] IMU reading at 4kHz, averaged to 1kHz output
- [ ] Gyro-to-mouse-delta conversion on device
- [ ] Wireless link at 1000Hz polling
- [ ] USB HID mouse on dongle
- [ ] Basic calibration (store bias in flash)
- [ ] 2-3 buttons working
- [ ] Breadboard/dev-kit prototype
- [ ] Latency measurement (<2ms target)

---

## Phase 2: Full Button Layout

Expand to complete input device.

### 2.1 Button Map

```
                    ┌─────────────────────┐
                    │    TOP VIEW         │
                    │                     │
   Index finger ───►│  [TRIGGER]          │
                    │  [SECONDARY]        │
                    │                     │
                    │         ┌───┐       │
                    │    ┌───┐│ D │┌───┐  │◄─── D-pad or
                    │    │ L ││PAD││ R │  │     8-way hat
                    │    └───┘│   │└───┘  │
                    │         └───┘       │
                    │                     │
                    │  [A] [B] [C] [D]    │◄─── Thumb buttons
                    │                     │
                    └─────────────────────┘
                           ▲
                           │
                    Thumb rest area
```

### 2.2 Input Count

| Type | Count | Interface |
|------|-------|-----------|
| Trigger buttons | 2 | GPIO direct |
| Thumb buttons | 4-6 | GPIO direct |
| D-pad / 8-way | 1 (4-8 switches) | GPIO or matrix |
| Analog stick (optional) | 1 | 2x ADC |
| **Total GPIO** | 12-16 | nRF52840 has 48 GPIO |

### 2.3 Phase 2 Deliverables

- [ ] Full button layout implemented
- [ ] D-pad or 8-way hat switch
- [ ] Button debouncing (<5ms)
- [ ] Configurable button mapping (stored in flash)
- [ ] First 3D printed enclosure
- [ ] Ergonomic grip testing

---

## Phase 3: Polish & Optimization

### 3.1 Advanced Features

| Feature | Description |
|---------|-------------|
| Sensor fusion | Use accelerometer to reduce gyro drift |
| Auto-calibration | Calibrate while moving (like GamepadMotionHelpers) |
| Haptic feedback | Small vibration motor for button feedback |
| On-device filtering | One Euro or similar adaptive filter |
| Profile switching | Multiple button maps, switch via combo |
| Battery gauge | Accurate fuel gauge IC |

### 3.2 Enclosure Iterations

| Version | Focus |
|---------|-------|
| v0.1 | Fit components, test grip |
| v0.2 | Button placement refinement |
| v0.3 | Weight balance, cable routing |
| v1.0 | Production-quality print |

### 3.3 Custom PCB (Optional)

If the project succeeds, design a single PCB with:
- nRF52840 module (Raytac MDBT50Q or similar)
- ICM-45686 on-board
- Battery management
- USB-C
- All button connections
- Compact form factor

---

## Technical Specifications

### Data Packet Format (Wand → Dongle)

```
Byte  0-1:  dx (int16, mouse delta X)
Byte  2-3:  dy (int16, mouse delta Y)
Byte    4:  buttons_low (8 buttons)
Byte    5:  buttons_high (8 buttons)
Byte    6:  dpad_state (4 bits) + flags (4 bits)
Byte    7:  battery_percent (0-100)
Byte  8-9:  sequence_number (for latency measurement)
Byte 10-11: reserved / checksum
```

Total: 12 bytes (fits in single ShockBurst packet)

### Latency Budget

| Stage | Target | Notes |
|-------|--------|-------|
| IMU read | 50 μs | SPI at 8 MHz |
| Processing | 100 μs | Gyro→delta, filtering |
| Radio TX | 260 μs | ShockBurst 12-byte |
| Radio RX | 50 μs | Dongle receive |
| USB HID | 1000 μs | 1ms USB polling |
| **Total** | **<1.5 ms** | Before OS processing |

### Gyro Processing (On-Device)

```
1. Read raw gyro (int16 x3) from IMU FIFO
2. Apply factory calibration coefficients
3. Subtract runtime bias estimate
4. Convert to degrees/second
5. Extract yaw (Z) and pitch (Y) for mouse
6. Apply soft deadzone (~0.5 °/s)
7. Apply acceleration curve
8. Scale to mouse deltas (sensitivity)
9. Accumulate fractional pixels
10. Pack integer deltas into packet
```

### Calibration Storage (Flash)

```
Offset 0x00: Magic (0xCAFE)
Offset 0x02: Version (1)
Offset 0x04: Gyro bias X (float)
Offset 0x08: Gyro bias Y (float)
Offset 0x0C: Gyro bias Z (float)
Offset 0x10: Sensitivity (float)
Offset 0x14: Deadzone (float)
Offset 0x18: Button mapping table (64 bytes)
```

---

## Bill of Materials (Phase 1)

| Component | Part Number | Quantity | Source | Est. Price |
|-----------|-------------|----------|--------|------------|
| nRF52840 Feather | Adafruit 4062 | 1 | Adafruit | $25 |
| XIAO nRF52840 (USB-C) | Seeed XIAO BLE | 1 | Seeed Studio | $10 |
| IMU Breakout | Adafruit LSM6DSOX | 1 | Adafruit | $12 |
| LiPo Battery | 3.7V 500mAh | 1 | Adafruit | $8 |
| Tactile Buttons | 6x6mm | 5 | Amazon | $3 |
| Wires/Headers | Various | 1 set | Amazon | $5 |
| USB-C Cable | Data + Power | 1 | Any | $5 |
| **Phase 1 Total** | | | | **~$78** |

### Phase 2 Additions

| Component | Part Number | Quantity | Source | Est. Price |
|-----------|-------------|----------|--------|------------|
| 8-way Hat Switch | ALPS RKJXT | 1 | DigiKey | $8 |
| Additional Buttons | Kailh low-profile | 8 | Various | $10 |
| 3D Print Filament | PETG | 1 roll | Amazon | $25 |
| Vibration Motor | 3V coin type | 1 | Adafruit | $4 |
| **Phase 2 Total** | | | | **~$47** |

---

## Development Environment

### Toolchain

| Tool | Purpose |
|------|---------|
| nRF Connect SDK | Firmware development |
| Zephyr RTOS | Real-time OS (included in SDK) |
| VS Code + nRF Extensions | IDE |
| J-Link (on DK) or Black Magic Probe | Debugging |
| Nordic Power Profiler Kit | Power measurement |
| Logic Analyzer | Protocol debugging |

### Firmware Structure

```
gyro-wand-firmware/
├── src/
│   ├── main.c                 # Entry point, init
│   ├── imu/
│   │   ├── imu_driver.c       # ICM-45686/BMI270 driver
│   │   ├── calibration.c      # Bias estimation
│   │   └── fusion.c           # Sensor fusion (later)
│   ├── input/
│   │   ├── buttons.c          # Button scanning/debounce
│   │   ├── gyro_mouse.c       # Gyro → mouse delta
│   │   └── filtering.c        # One Euro filter
│   ├── radio/
│   │   ├── esb_link.c         # ShockBurst protocol
│   │   └── pairing.c          # Device pairing
│   └── power/
│       ├── battery.c          # Fuel gauge
│       └── sleep.c            # Power management
├── dongle/
│   ├── main.c                 # Dongle firmware
│   ├── usb_hid.c              # USB HID mouse
│   └── esb_receiver.c         # Radio receiver
└── config/
    ├── prj.conf               # Zephyr config
    └── boards/                # Board overlays
```

---

## Open Questions

1. **IMU Choice:** ICM-45686 vs BMI270 vs LSM6DSV - need to verify breakout availability
2. **Enclosure Style:** Wiimote-like vs pen-grip vs TV-remote style?
3. **Analog Stick:** Include from start or add in Phase 2?
4. **Host Software:** Use existing JamCon app or standalone HID?
5. **Pairing Method:** Button combo or USB cable for initial pair?

---

## References

- [Nordic nRF52840 Product Page](https://www.nordicsemi.com/Products/nRF52840)
- [nRF Connect SDK Documentation](https://developer.nordicsemi.com/nRF_Connect_SDK/doc/latest/)
- [SlimeVR IMU Comparison](https://docs.slimevr.dev/diy/imu-comparison.html)
- [GamepadMotionHelpers](https://github.com/JibbSmart/GamepadMotionHelpers)
- [Wireless Latency Benchmarks](https://hackaday.com/2024/02/11/benchmarking-latency-across-common-wireless-links-for-mcus/)
- [juskim's DIY Mouse](https://www.hackster.io/news/building-a-homemade-wireless-gaming-mouse-with-the-new-nrf54-4a62ab33f4d1)

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-04 | Initial requirements document |
