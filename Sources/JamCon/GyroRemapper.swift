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
    ///   - isLeft: Whether this is a left-side controller (only relevant for Joy-Con)
    /// - Returns: Tuple of semantic axes (pitch=vertical, yaw=horizontal, roll=rotation)
    static func remap(
        rawX: Int16,
        rawY: Int16,
        rawZ: Int16,
        controllerKind: ControllerKind,
        isLeft: Bool = true,
        profileVariant: ControllerProfileVariant = .standard
    ) -> (pitch: Int16, yaw: Int16, roll: Int16) {
        switch controllerKind {
        case .sense:
            // Sense: HID axes already match semantic axes
            // X = pitch (up/down tilt), Y = yaw (left/right), Z = roll
            return (pitch: rawX, yaw: rawY, roll: rawZ)

        case .joyCon:
            // Joy-Con: Axes are rotated compared to Sense
            // Left and Right Joy-Con are physical mirrors of each other
            let mapped: (pitch: Int16, yaw: Int16, roll: Int16)
            if isLeft {
                // Left Joy-Con (held sideways with stick at top-left):
                // HID Y = pitch (up/down), HID Z = yaw (left/right pointing)
                // Negate pitch to fix inverted up/down motion
                mapped = (pitch: -rawY, yaw: rawZ, roll: rawX)
            } else {
                // Right Joy-Con (held sideways with stick at top-right):
                // The controller is mirrored, so both pitch and yaw need to be inverted
                // relative to the left Joy-Con mapping
                mapped = (pitch: rawY, yaw: -rawZ, roll: -rawX)
            }
            // Joy-Con 2's reported cursor axes run opposite the original
            // Joy-Con convention. The right controller's comfortable JamCon
            // grip is also rotated relative to the original Joy-Con profile:
            // live isolated-axis measurements put intended vertical motion on
            // raw X, horizontal on raw Z, and the remaining roll on raw Y.
            if profileVariant == .joyCon2 {
                if !isLeft {
                    return (pitch: rawX, yaw: rawZ, roll: rawY)
                }
                // Physical Joy-Con 2 Left validation puts intended tilt on raw
                // X, horizontal pointing on raw Z, and wrist roll on raw Y.
                // Its horizontal sign matches the validated right-hand grip.
                return (pitch: rawX, yaw: rawZ, roll: rawY)
            }
            return mapped

        case .mouse:
            // Mouse has no gyro - return zeros
            return (pitch: 0, yaw: 0, roll: 0)
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
        case .mouse:
            return 0.0  // Mouse has no gyro
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
        controllerKind: ControllerKind,
        nativeScale: Double? = nil
    ) -> (pitch: Double, yaw: Double, roll: Double) {
        let scale = nativeScale ?? gyroScale(for: controllerKind)
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
    ///   - isLeft: Whether this is a left-side controller (only relevant for Joy-Con)
    /// - Returns: All three pipeline stages
    static func process(
        rawX: Int16,
        rawY: Int16,
        rawZ: Int16,
        controllerKind: ControllerKind,
        isLeft: Bool = true,
        profileVariant: ControllerProfileVariant = .standard,
        nativeScale: Double? = nil
    ) -> (
        raw: (x: Int16, y: Int16, z: Int16),
        remapped: (pitch: Int16, yaw: Int16, roll: Int16),
        normalized: (pitch: Double, yaw: Double, roll: Double)
    ) {
        let raw = (x: rawX, y: rawY, z: rawZ)
        let remapped = remap(
            rawX: rawX,
            rawY: rawY,
            rawZ: rawZ,
            controllerKind: controllerKind,
            isLeft: isLeft,
            profileVariant: profileVariant
        )
        let normalized = normalize(
            pitch: remapped.pitch,
            yaw: remapped.yaw,
            roll: remapped.roll,
            controllerKind: controllerKind,
            nativeScale: nativeScale
        )

        return (raw: raw, remapped: remapped, normalized: normalized)
    }

}
