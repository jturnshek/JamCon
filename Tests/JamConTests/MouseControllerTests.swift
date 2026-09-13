import CoreGraphics
import XCTest
@testable import JamCon

final class MouseControllerTests: XCTestCase {
    func testGyroResumesAtLiveCursorPositionBeforeDisplayRefresh() {
        let backend = CursorTestBackend()
        let mouse = backend.makeController()
        mouse.moveRelative(dx: 10, dy: 5)
        XCTAssertEqual(backend.position, CGPoint(x: 110, y: 105))

        // A physical mouse moves between consecutive gyro frames.
        backend.position = CGPoint(x: 400, y: 300)
        mouse.moveRelative(dx: 3, dy: -2)

        XCTAssertEqual(backend.position, CGPoint(x: 403, y: 298))
        XCTAssertEqual(backend.events.last?.location, backend.position)
        XCTAssertEqual(backend.displayReads, 1, "Cursor tracking must not refresh display geometry every frame")
    }

    func testZeroGyroMotionDoesNotPostCursorMovement() {
        let backend = CursorTestBackend()
        let mouse = backend.makeController()
        backend.position = CGPoint(x: 400, y: 300)

        mouse.moveRelative(dx: 0, dy: 0)

        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertEqual(backend.position, CGPoint(x: 400, y: 300))
    }

    func testFractionalGyroMotionAccumulatesAcrossRoundedCursorReads() {
        let backend = CursorTestBackend()
        let mouse = backend.makeController()
        for _ in 0..<10 {
            mouse.moveRelative(dx: 0.25, dy: -0.25)
        }
        XCTAssertEqual(backend.position, CGPoint(x: 102, y: 98))
        XCTAssertEqual(backend.events.count, 2)

        backend.position = CGPoint(x: 400, y: 300)
        mouse.moveRelative(dx: 0.5, dy: -0.5)
        XCTAssertEqual(backend.position, CGPoint(x: 401, y: 299))
    }

    func testDragUsesLivePositionAndRetainsButtonState() {
        let backend = CursorTestBackend()
        let mouse = backend.makeController()
        mouse.mouseDown(button: .left)
        backend.position = CGPoint(x: 400, y: 300)

        mouse.moveRelative(dx: 3, dy: -2)
        mouse.mouseUp(button: .left)

        XCTAssertEqual(backend.events.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(backend.events[1].location, CGPoint(x: 403, y: 298))
        XCTAssertEqual(backend.events[2].location, CGPoint(x: 403, y: 298))
    }

    func testDisplayEdgeDoesNotRetainBlockedFractionalMovement() {
        let backend = CursorTestBackend()
        let mouse = backend.makeController()
        backend.position = CGPoint(x: 990, y: 100)
        mouse.moveRelative(dx: 20.75, dy: 0)
        XCTAssertEqual(backend.position.x, 1000)

        mouse.moveRelative(dx: -1, dy: 0)
        XCTAssertEqual(backend.position.x, 999)
    }
}

private final class CursorTestBackend {
    var position = CGPoint(x: 100, y: 100)
    var events: [CGEvent] = []
    var displayReads = 0

    func makeController() -> MouseController {
        MouseController(
            displayRefreshInterval: 3600,
            cursorPositionProvider: { self.position },
            displayBoundsProvider: {
                self.displayReads += 1
                return [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
            },
            postEvent: { event in
                self.events.append(event)
                // Emulate the system's point-resolution cursor observation.
                self.position = CGPoint(x: event.location.x.rounded(), y: event.location.y.rounded())
            }
        )
    }
}
