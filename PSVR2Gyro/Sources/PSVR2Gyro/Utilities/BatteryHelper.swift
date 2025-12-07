import SwiftUI

/// Centralized battery display logic for PSVR2 controllers
enum BatteryHelper {

    /// Extract battery percentage from raw report byte
    /// - Parameter rawByte: The raw byte from HID report (byte 43)
    /// - Returns: Battery percentage (0-100)
    static func level(from rawByte: UInt8) -> Int {
        PSVR2HIDProtocol.batteryPercentage(from: rawByte)
    }

    /// Map Joy-Con battery header byte (upper nibble) to a coarse percentage.
    static func joyConLevel(from rawByte: UInt8) -> Int {
        let levelNibble = (rawByte >> 4) & 0x0F
        switch levelNibble {
        case 0x0: return 0
        case 0x1: return 20
        case 0x2: return 35
        case 0x4: return 50
        case 0x6: return 65
        case 0x8: return 80
        case 0xA: return 90
        case 0xC, 0xE: return 100
        default: return min(100, Int(levelNibble) * 10)
        }
    }

    /// Get display color for battery level
    /// - Parameter level: Battery percentage (0-100)
    /// - Returns: Color appropriate for the battery level
    static func color(for level: Int) -> Color {
        if level > 50 { return .green }
        if level > 20 { return .yellow }
        return .red
    }

    /// Get SF Symbol icon name for battery level
    /// - Parameter level: Battery percentage (0-100)
    /// - Returns: SF Symbol name for battery icon
    static func icon(for level: Int) -> String {
        if level >= 75 { return "battery.100" }
        if level >= 50 { return "battery.75" }
        if level >= 25 { return "battery.50" }
        if level > 0 { return "battery.25" }
        return "battery.0"
    }
}
