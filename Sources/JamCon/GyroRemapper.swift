import Foundation

/// Centralizes controller-specific gyro axis remapping and scale factors.
/// This is the bridge between controller-specific HID data and the unified processing pipeline.
enum GyroRemapper {

    // MARK: - Axis Remapping

    /// Remap raw HID axes to semantic axes (pitch, yaw, roll).
    /// - Parameters:
    ///   - rawX: Raw X axis from HID report
    ///   - rawY: Raw Y axis from HID report
    ///   - rawZ: Raw Z axis from HID report
    ///   - controllerKind: The type of controller
    /// - Returns: Tuple of semantic axes (pitch=vertical, yaw=horizontal, roll=rotation)
    static func remap(
        rawX: Int16,
        rawY: Int16,
        rawZ: Int16,
        controllerKind: ControllerKind
    ) -> (pitch: Int16, yaw: Int16, roll: Int16) {
        switch controllerKind {
        case .sense:
            // Sense: HID axes already match semantic axes
            // X = pitch (up/down tilt), Y = yaw (left/right), Z = roll
            return (pitch: rawX, yaw: rawY, roll: rawZ)

        case .joyCon:
            // Joy-Con: Axes are rotated compared to Sense
            // HID X = roll (wrist twist), HID Y = pitch (up/down), HID Z = yaw (left/right pointing)
            // Negate yaw to match Sense polarity (so GyroProcessor's -yaw gives correct result)
            return (pitch: rawY, yaw: -rawZ, roll: rawX)
        }
    }

    // MARK: - Scale Factors

    /// Get the scale factor for converting raw gyro values to degrees per second.
    /// - Parameter controllerKind: The type of controller
    /// - Returns: Scale factor (multiply raw value to get °/s)
    static func gyroScale(for controllerKind: ControllerKind) -> Double {
        switch controllerKind {
        case .sense:
            return SenseHIDProtocol.defaultGyroScale  // 0.0625 (1/16)
        case .joyCon:
            return JoyConHIDProtocol.defaultGyroScale  // 0.06103
        }
    }

    // MARK: - Normalization

    /// Normalize remapped gyro values to degrees per second.
    /// - Parameters:
    ///   - pitch: Remapped pitch value (Int16)
    ///   - yaw: Remapped yaw value (Int16)
    ///   - roll: Remapped roll value (Int16)
    ///   - controllerKind: The type of controller
    /// - Returns: Tuple of normalized values in degrees per second
    static func normalize(
        pitch: Int16,
        yaw: Int16,
        roll: Int16,
        controllerKind: ControllerKind
    ) -> (pitch: Double, yaw: Double, roll: Double) {
        let scale = gyroScale(for: controllerKind)
        return (
            pitch: Double(pitch) * scale,
            yaw: Double(yaw) * scale,
            roll: Double(roll) * scale
        )
    }

    // MARK: - Full Pipeline

    /// Process raw HID gyro values through the full controller-specific pipeline.
    /// Returns all three stages: raw, remapped, and normalized.
    /// - Parameters:
    ///   - rawX: Raw X axis from HID report
    ///   - rawY: Raw Y axis from HID report
    ///   - rawZ: Raw Z axis from HID report
    ///   - controllerKind: The type of controller
    /// - Returns: All three pipeline stages
    static func process(
        rawX: Int16,
        rawY: Int16,
        rawZ: Int16,
        controllerKind: ControllerKind
    ) -> (
        raw: (x: Int16, y: Int16, z: Int16),
        remapped: (pitch: Int16, yaw: Int16, roll: Int16),
        normalized: (pitch: Double, yaw: Double, roll: Double)
    ) {
        let raw = (x: rawX, y: rawY, z: rawZ)
        let remapped = remap(rawX: rawX, rawY: rawY, rawZ: rawZ, controllerKind: controllerKind)
        let normalized = normalize(pitch: remapped.pitch, yaw: remapped.yaw, roll: remapped.roll, controllerKind: controllerKind)

        return (raw: raw, remapped: remapped, normalized: normalized)
    }

}
