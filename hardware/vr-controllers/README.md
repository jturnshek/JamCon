# VR Controllers for Desktop Pointing

Exploration of using VR ecosystem controllers as high-quality gyro pointing devices for desktop mouse control.

## Why VR Controllers?

VR controllers solve the core problems with consumer air mice:

1. **No hardcoded presentation buttons** - Standard gamepad inputs, fully remappable
2. **High-quality IMUs** - Gyro + accelerometer with sensor fusion
3. **Proven ecosystems** - Valve's gyro-to-mouse implementation is excellent
4. **Good ergonomics** - Designed for extended use
5. **Rich inputs** - Triggers, thumbsticks, buttons, touchpads

## Requirements for Our Use Case

| Requirement | Must Have | Nice to Have |
|-------------|-----------|--------------|
| Internal IMU (gyro + accel) | Yes | - |
| Works without VR headset | Yes | - |
| Connects to PC via dongle/Bluetooth | Yes | - |
| Exposes gyro data to software | Yes | - |
| Standard/remappable buttons | Yes | - |
| Low latency | Yes | - |
| Good ergonomics for one-handed use | - | Yes |
| Positional tracking (6DoF) | - | Yes |
| Finger tracking | - | Yes |

---

## Controller Evaluation

### ✅ VIABLE - Works for Our Use Case

#### Valve Index Controllers ("Knuckles")
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (Lighthouse) + IMU |
| **Connection** | 2.4GHz USB dongle |
| **Works without headset** | ✅ Yes, via libsurvive |
| **IMU** | Gyro + Accel (sensor fusion) |
| **Inputs** | Trigger, grip, thumbstick, A/B, trackpad, finger tracking |
| **Price** | ~$100-150 used (single) |
| **Software** | libsurvive (open source) |
| **Notes** | Requires Lighthouse base station (~$100-150) for 6DoF. Gyro works standalone. |

#### HTC Vive Wand Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (Lighthouse) + IMU |
| **Connection** | 2.4GHz USB dongle |
| **Works without headset** | ✅ Yes, via libsurvive |
| **IMU** | Gyro + Accel |
| **Inputs** | Trigger, grip, trackpad, menu buttons |
| **Price** | ~$50-80 used (single) |
| **Software** | libsurvive (open source) |
| **Notes** | Older design, less ergonomic. Cheaper than Index. |

#### Vive Tracker (Puck)
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (Lighthouse) + IMU |
| **Connection** | 2.4GHz USB dongle or USB direct |
| **Works without headset** | ✅ Yes, via libsurvive |
| **IMU** | Gyro + Accel |
| **Inputs** | None (tracking only) |
| **Price** | ~$80-130 |
| **Software** | libsurvive, ROS packages |
| **Notes** | No buttons - would need to attach to custom grip with buttons. Good for robotics/DIY. |

#### Tundra Tracker
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (Lighthouse) + IMU |
| **Connection** | 2.4GHz USB dongle |
| **Works without headset** | ✅ Yes, via libsurvive |
| **IMU** | Gyro + Accel (18 optical sensors) |
| **Inputs** | None (tracking only) |
| **Price** | ~$100 |
| **Software** | libsurvive, SteamVR |
| **Notes** | Smaller than Vive Tracker. 9-hour battery. No buttons. |

#### Pimax Sword Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (Lighthouse) + IMU |
| **Connection** | 2.4GHz (SteamVR compatible) |
| **Works without headset** | ✅ Yes, via libsurvive (likely) |
| **IMU** | Gyro + Accel |
| **Inputs** | Trigger, grip, thumbstick, buttons |
| **Price** | ~$269 (often out of stock) |
| **Software** | SteamVR, likely libsurvive |
| **Notes** | Compatible with Lighthouse ecosystem. Limited availability. |

#### etee Controllers (3DoF mode)
| Attribute | Value |
|-----------|-------|
| **Tracking** | 3DoF (IMU only) or 6DoF (with Lighthouse) |
| **Connection** | USB dongle |
| **Works without headset** | ✅ Yes, in 3DoF mode |
| **IMU** | Gyro + Accel |
| **Inputs** | Finger tracking, configurable thumbpad (trackpad/joystick/D-pad) |
| **Price** | ~$300-400 (kit) |
| **Software** | eteeConnect, SteamVR |
| **Notes** | Button-free design with full finger tracking. Can work standalone for "virtual mouse" use case. |

---

### ⏳ UPCOMING - Potentially Viable

#### Steam Frame Controllers (Q1 2026)
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out, needs headset) + IMU |
| **Connection** | Likely 2.4GHz dongle for non-VR use |
| **Works without headset** | ⏳ Unknown - likely yes for gyro/3DoF |
| **IMU** | Gyro + Accel (confirmed) |
| **Inputs** | D-pad, ABXY, thumbstick, triggers, bumpers, grip buttons |
| **Price** | TBD |
| **Software** | Steam Input (expected) |
| **Notes** | Designed explicitly for non-VR games. Best button layout. Wait for launch details. |

---

### ❌ CANNOT CONNECT TO PC - Headset-Only Communication

These controllers have no way to communicate with a PC at all. They only pair with their specific headset.

#### Meta Quest Controllers (Touch, Touch Plus)
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out, needs headset cameras) |
| **Connection** | Bluetooth to headset only |
| **Can connect to PC?** | ❌ **No** - Pairs exclusively to Quest headset |
| **IMU** | Gyro + Accel (inaccessible) |
| **Why Not** | Controllers use proprietary Bluetooth pairing that only works with Quest headsets. There is no dongle, no PC pairing mode, no way to access any data. |

#### Meta Quest Pro Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (self-tracking via onboard cameras) |
| **Connection** | Bluetooth to headset only |
| **Can connect to PC?** | ❌ **No** - Pairs exclusively to Quest headset |
| **IMU** | Gyro + Accel (inaccessible) |
| **Why Not** | Despite having self-tracking cameras, still requires Quest headset pairing. No standalone PC mode exists. |

#### Pico 4 Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out, needs headset) |
| **Connection** | Bluetooth to headset only |
| **Can connect to PC?** | ❌ **No** - Pairs exclusively to Pico headset |
| **IMU** | Gyro + Accel (inaccessible) |
| **Why Not** | Same as Quest - proprietary Bluetooth pairing to headset only. Cannot connect to anything else. |

#### HTC Vive Focus 3 Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out, needs headset) |
| **Connection** | Proprietary wireless to headset |
| **Can connect to PC?** | ❌ **No** - Proprietary protocol, headset only |
| **IMU** | Gyro + Accel (inaccessible) |
| **Why Not** | Enterprise standalone headset with proprietary controller protocol. No PC connectivity whatsoever. |

#### HTC Vive XR Elite Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out) |
| **Connection** | Proprietary wireless to headset |
| **Can connect to PC?** | ❌ **No** - Proprietary protocol, headset only |
| **IMU** | Gyro + Accel (inaccessible) |
| **Why Not** | Same as Focus 3 - proprietary controller protocol with no PC connectivity. |

---

### ❌ CAN CONNECT BUT USELESS - Requires Full VR Stack

These controllers can technically pair with a PC via Bluetooth, but you cannot access the gyro data without running the full VR software stack with a headset connected.

#### PlayStation VR2 Sense Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out, needs headset) |
| **Connection** | Bluetooth (can pair to PC) |
| **Can connect to PC?** | ⚠️ **Yes, but...** - Pairs via Bluetooth, data inaccessible |
| **IMU** | 6-axis (3-axis gyro, 3-axis accel) |
| **Why Not** | Can pair to PC via Bluetooth, but gyro data is not exposed through any standard protocol. Requires SteamVR + PSVR2 headset connected to access any sensor data. Pairing is also unreliable. |

#### Windows Mixed Reality Controllers
| Attribute | Value |
|-----------|-------|
| **Tracking** | 6DoF (inside-out, needs headset) |
| **Connection** | Bluetooth 4.0 (can pair to PC) |
| **Can connect to PC?** | ⚠️ **Yes, but...** - Pairs via Bluetooth, gyro not exposed |
| **IMU** | Gyro + Accel (used internally for prediction) |
| **Why Not** | Can pair to PC via standard Bluetooth, but the gyro/accel data is only used internally for motion prediction when controllers leave camera view. No API exposes raw sensor data. Also, platform deprecated by Microsoft (removed in Windows 11 24H2). |

---

## Summary Comparison

| Controller | Connects to PC? | Standalone Gyro? | Has Buttons? | Price (used) | Status |
|------------|-----------------|------------------|--------------|--------------|--------|
| **Valve Index** | ✅ USB dongle | ✅ | ✅ Excellent | ~$100-150 | ⭐ **Best Option** |
| **HTC Vive Wand** | ✅ USB dongle | ✅ | ✅ Good | ~$50-80 | ✅ Budget option |
| **Vive Tracker** | ✅ USB dongle | ✅ | ❌ None | ~$80-130 | For DIY only |
| **Tundra Tracker** | ✅ USB dongle | ✅ | ❌ None | ~$100 | For DIY only |
| **Pimax Sword** | ✅ USB dongle | ✅ | ✅ Good | ~$269 | Limited availability |
| **etee** | ✅ USB dongle | ✅ | ✅ Finger tracking | ~$300-400 | Unique but expensive |
| **Steam Frame** | ⏳ TBD | ⏳ TBD | ✅ Excellent | TBD | Wait for Q1 2026 |
| Meta Quest | ❌ **No** | N/A | ✅ | N/A | Cannot connect to PC |
| Quest Pro | ❌ **No** | N/A | ✅ | N/A | Cannot connect to PC |
| Pico 4 | ❌ **No** | N/A | ✅ | N/A | Cannot connect to PC |
| Focus 3 | ❌ **No** | N/A | ✅ | N/A | Cannot connect to PC |
| XR Elite | ❌ **No** | N/A | ✅ | N/A | Cannot connect to PC |
| PSVR2 Sense | ⚠️ BT (useless) | ❌ | ✅ | N/A | Gyro data inaccessible |
| WMR | ⚠️ BT (useless) | ❌ | ✅ | N/A | Deprecated, gyro hidden |

---

## Recommendations

### Best Overall: Valve Index Controller + Lighthouse
- **Why**: Proven ecosystem, excellent ergonomics, finger tracking, works with libsurvive
- **Cost**: ~$200-300 total (1 controller + 1 base station, used)
- **Tradeoff**: Requires base station setup, not portable

### Best Budget: HTC Vive Wand + Lighthouse
- **Why**: Cheaper, same ecosystem, libsurvive support
- **Cost**: ~$150-200 total (1 wand + 1 base station, used)
- **Tradeoff**: Less ergonomic, older design

### Best Potential: Steam Frame Controller (Wait for Q1 2026)
- **Why**: Designed for non-VR, excellent button layout, Valve gyro implementation
- **Cost**: TBD
- **Tradeoff**: Not released yet, may require headset for full functionality

### For DIY Projects: Vive/Tundra Tracker
- **Why**: Pure tracking puck, attach to custom hardware
- **Cost**: ~$100 + custom grip/buttons
- **Tradeoff**: No built-in buttons

---

## Key Insight: Inside-Out vs Outside-In Tracking

**Inside-Out (Quest, Pico, WMR, PSVR2):**
- Cameras on headset track controllers
- Controllers cannot work without headset
- ❌ Not viable for our use case

**Outside-In / Lighthouse (Index, Vive, Pimax):**
- External base stations emit IR
- Controllers track themselves using photodiodes
- Controllers connect directly to PC via dongle
- ✅ Works without headset via libsurvive

This is the key differentiator. Only Lighthouse-based controllers can work standalone.

---

## Software Stack for Viable Controllers

### libsurvive (Recommended)
- Open source Lighthouse tracking
- Works without SteamVR
- Provides pose data + button inputs
- GitHub: [collabora/libsurvive](https://github.com/collabora/libsurvive)

### SteamVR + Steam Input
- Official Valve stack
- Gyro-to-mouse via Steam Input
- Requires SteamVR running

### Custom Integration
- Read from libsurvive
- Convert pose → mouse movement
- Map buttons → clicks/actions
- Similar to existing JamCon InputProcessor

---

## Hardware Sources

| Item | Where to Buy |
|------|--------------|
| Index Controller (single) | [eBay](https://www.ebay.com/shop/valve-index-controller), r/hardwareswap |
| Vive Wand | [eBay](https://www.ebay.com/sch/i.html?_nkw=htc+vive+controller), [Amazon](https://www.amazon.com/HTC-Vive-Controller-PC/dp/B01LYELB1S) |
| Base Station 2.0 | [Steam Store](https://store.steampowered.com/app/1059570/Valve_Index_Base_Station/), eBay |
| Vive Tracker | [Vive Store](https://www.vive.com/us/accessory/tracker3/), eBay |
| Tundra Tracker | [Tundra Labs](https://tundra-labs.com/) |
| SteamVR Dongle | [VRDongles](https://vrdongles.com/), [Tundra Labs](https://tundra-labs.com/products/steamvr-dongle) |
| etee Controllers | [eteexr.com](https://eteexr.com/products/etee-steamvr) |

---

## References

- [libsurvive - GitHub](https://github.com/collabora/libsurvive)
- [Valve Index Controllers](https://www.valvesoftware.com/en/index/controllers)
- [Steam Frame Announcement](https://www.pcgamer.com/hardware/vr-hardware/steam-frame-specs-availability/)
- [VRDongles - SteamVR Dongles](https://vrdongles.com/)
- [Tundra Labs](https://tundra-labs.com/)
- [etee Controllers](https://eteexr.com/)
- [Road to VR - Vive Tracker Without Headset](https://www.roadtovr.com/how-to-use-the-htc-vive-tracker-without-a-vive-headset/)

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-04 | Initial exploration document |
| 2025-12-04 | Added comprehensive controller evaluation |
