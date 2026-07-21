import XCTest
@testable import JamCon

final class RadialMenuGeometryTests: XCTestCase {
    func testArrowMenuDirectionsMatchVisualOrder() {
        let configuration = RadialMenuConfiguration.arrowKeys

        XCTAssertEqual(resolve(CGPoint(x: 0, y: -60), configuration), .inner(0))
        XCTAssertEqual(resolve(CGPoint(x: 60, y: 0), configuration), .inner(1))
        XCTAssertEqual(resolve(CGPoint(x: 0, y: 60), configuration), .inner(2))
        XCTAssertEqual(resolve(CGPoint(x: -60, y: 0), configuration), .inner(3))
    }

    func testDeadzoneHasNoSelection() {
        XCTAssertNil(resolve(CGPoint(x: 10, y: 10), .arrowKeys))
    }

    func testOffsetIsClampedToVisibleGhostRadius() {
        let configuration = RadialMenuConfiguration.arrowKeys
        let result = RadialMenuGeometry.resolve(
            offset: CGPoint(x: 1_000, y: 0),
            configuration: configuration
        )

        XCTAssertEqual(result.clampedOffset.x, configuration.menuRadius - 10, accuracy: 0.001)
        XCTAssertEqual(result.clampedOffset.y, 0, accuracy: 0.001)
    }

    private func resolve(
        _ point: CGPoint,
        _ configuration: RadialMenuConfiguration
    ) -> RadialMenuSelection? {
        RadialMenuGeometry.resolve(offset: point, configuration: configuration).selection
    }
}
