import SwiftUI

/// Centralized battery presentation logic.
enum BatteryHelper {
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
