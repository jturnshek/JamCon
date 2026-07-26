import CoreGraphics

enum RadialMenuSelection: Equatable {
    case inner(Int)
    case outer(Int)
}

/// Tracks radial boundary crossings without coupling geometry to a device
/// transport. Entering a segment, changing segments, and returning to the
/// deadzone each produce one acknowledgement.
struct RadialMenuHapticTracker {
    private(set) var isActive = false
    private var selection: RadialMenuSelection?

    mutating func begin() {
        isActive = true
        selection = nil
    }

    mutating func update(_ next: RadialMenuSelection?) -> Bool {
        guard isActive, next != selection else { return false }
        selection = next
        return true
    }

    mutating func end() {
        isActive = false
        selection = nil
    }
}

struct RadialMenuGeometryResult: Equatable {
    let clampedOffset: CGPoint
    let selection: RadialMenuSelection?
}

enum RadialMenuGeometry {
    static func resolve(
        offset: CGPoint,
        configuration: RadialMenuConfiguration
    ) -> RadialMenuGeometryResult {
        let magnitude = hypot(offset.x, offset.y)
        let maximumRadius = max(0, configuration.menuRadius - 10)

        let clampedOffset: CGPoint
        if magnitude > maximumRadius, magnitude > 0 {
            let scale = maximumRadius / magnitude
            clampedOffset = CGPoint(x: offset.x * scale, y: offset.y * scale)
        } else {
            clampedOffset = offset
        }

        let clampedMagnitude = min(magnitude, maximumRadius)
        guard clampedMagnitude >= configuration.deadzoneSize else {
            return RadialMenuGeometryResult(clampedOffset: clampedOffset, selection: nil)
        }

        let angle = atan2(clampedOffset.y, clampedOffset.x)
        let outerRingEnabled = configuration.outerRingEnabled && !configuration.outerRingItems.isEmpty
        let outerRingStart = configuration.deadzoneSize + configuration.innerRingSize

        if outerRingEnabled, clampedMagnitude >= outerRingStart {
            return RadialMenuGeometryResult(
                clampedOffset: clampedOffset,
                selection: .outer(index(for: angle, count: configuration.outerRingItems.count, rotation: configuration.outerRingRotation))
            )
        }

        guard !configuration.items.isEmpty else {
            return RadialMenuGeometryResult(clampedOffset: clampedOffset, selection: nil)
        }
        return RadialMenuGeometryResult(
            clampedOffset: clampedOffset,
            selection: .inner(index(for: angle, count: configuration.items.count, rotation: configuration.innerRingRotation))
        )
    }

    private static func index(for angle: Double, count: Int, rotation: Double) -> Int {
        guard count > 0 else { return 0 }

        let rotationRadians = -rotation * Double.pi / 180
        let twoPi = Double.pi * 2
        var normalizedAngle = fmod(angle + Double.pi / 2 - rotationRadians, twoPi)
        if normalizedAngle < 0 { normalizedAngle += twoPi }

        return min(Int(normalizedAngle / (twoPi / Double(count))), count - 1)
    }
}
