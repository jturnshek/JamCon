import AppKit
import CoreGraphics

/// Centralizes conversion between Quartz global display coordinates and AppKit screen coordinates.
enum DisplayCoordinateConverter {

    /// Convert a Quartz global cursor point (origin at the top-left of each display) into an
    /// AppKit screen point suitable for NSWindow placement.
    static func appKitScreenPoint(fromQuartz point: CGPoint) -> CGPoint {
        guard let screen = screen(containingQuartzPoint: point),
              let displayID = displayID(for: screen) else {
            return NSEvent.mouseLocation
        }

        let bounds = CGDisplayBounds(displayID)
        let localX = point.x - bounds.minX
        let localYFromTop = point.y - bounds.minY

        return CGPoint(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localYFromTop
        )
    }

    private static func screen(containingQuartzPoint point: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            if CGDisplayBounds(displayID).contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
