import CoreGraphics

enum DisplayGeometry {
    /// Returns the closest valid cursor point on any active display.
    ///
    /// Clamping to the union of display rectangles can place the cursor in an
    /// unreachable gap when displays have different sizes or vertical offsets.
    static func closestPoint(_ point: CGPoint, in displays: [CGRect]) -> CGPoint {
        let validDisplays = displays.filter { !$0.isNull && !$0.isEmpty }
        guard !validDisplays.isEmpty else { return point }

        if validDisplays.contains(where: { containsInclusive($0, point: point) }) {
            return point
        }

        var closest = clamped(point, to: validDisplays[0])
        var closestDistance = squaredDistance(from: point, to: closest)

        for display in validDisplays.dropFirst() {
            let candidate = clamped(point, to: display)
            let distance = squaredDistance(from: point, to: candidate)
            if distance < closestDistance {
                closest = candidate
                closestDistance = distance
            }
        }

        return closest
    }

    private static func containsInclusive(_ rect: CGRect, point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    private static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}
