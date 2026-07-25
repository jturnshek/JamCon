import Foundation

enum VirtualGamepadAxisNormalizer {
    /// Converts a calibrated raw stick axis directly to the signed 16-bit HID
    /// range. The symmetric output deliberately avoids Int16.min so inversion
    /// is exact and cannot overflow.
    static func normalize(
        raw: UInt16,
        center: Double,
        negativeRange: Double,
        positiveRange: Double,
        deadzone: Double,
        inverted: Bool = false
    ) -> Int16 {
        guard center.isFinite,
              negativeRange.isFinite,
              positiveRange.isFinite,
              deadzone.isFinite else { return 0 }

        let delta = Double(raw) - center
        let safeDeadzone = max(0, deadzone)
        guard abs(delta) > safeDeadzone else { return 0 }

        let range = delta < 0 ? negativeRange : positiveRange
        let usableRange = max(1, range - safeDeadzone)
        let magnitude = min(1, (abs(delta) - safeDeadzone) / usableRange)
        let signedMagnitude = Int16((magnitude * Double(Int16.max)).rounded())
        let value = delta < 0 ? -signedMagnitude : signedMagnitude
        return inverted ? -value : value
    }
}
