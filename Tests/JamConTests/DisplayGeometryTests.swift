import XCTest
@testable import JamCon

final class DisplayGeometryTests: XCTestCase {
    func testPointAlreadyOnDisplayIsUnchanged() {
        let displays = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let point = CGPoint(x: 40, y: 60)

        XCTAssertEqual(DisplayGeometry.closestPoint(point, in: displays), point)
    }

    func testPointInUnionGapMovesToNearestRealDisplay() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 50, width: 100, height: 100),
        ]

        XCTAssertEqual(
            DisplayGeometry.closestPoint(CGPoint(x: 150, y: 25), in: displays),
            CGPoint(x: 150, y: 50)
        )
    }

    func testPointOutsideAllDisplaysUsesNearestEdge() {
        let displays = [
            CGRect(x: -200, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 100),
        ]

        XCTAssertEqual(
            DisplayGeometry.closestPoint(CGPoint(x: 140, y: 120), in: displays),
            CGPoint(x: 100, y: 100)
        )
    }

    func testEmptyDisplayListLeavesPointUnchanged() {
        let point = CGPoint(x: 12, y: 34)

        XCTAssertEqual(DisplayGeometry.closestPoint(point, in: []), point)
    }
}
