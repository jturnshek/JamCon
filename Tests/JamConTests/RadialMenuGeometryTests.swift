import XCTest
import CoreGraphics
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

    func testProductionDefaultMatchesTheProvenConfiguration() {
        let configuration = RadialMenuConfiguration.default

        XCTAssertEqual(configuration.deadzoneSize, 30)
        XCTAssertEqual(configuration.innerRingSize, 35)
        XCTAssertEqual(configuration.innerRingRotation, 45)
        XCTAssertTrue(configuration.outerRingEnabled)
        XCTAssertEqual(configuration.outerRingSize, 50)
        XCTAssertEqual(configuration.outerRingRotation, 22.5)
        XCTAssertEqual(configuration.radialMovementScale, 2)
        XCTAssertEqual(configuration.items.map(\.action), [
            .keyPress(KeyCombo(keyCode: 126)),
            .keyPress(KeyCombo(keyCode: 124)),
            .keyPress(KeyCombo(keyCode: 125)),
            .keyPress(KeyCombo(keyCode: 123)),
        ])
        XCTAssertEqual(configuration.outerRingItems.map(\.action), [
            .systemAction(.missionControl),
            .keyPress(KeyCombo(keyCode: 17, modifiers: .maskCommand)),
            .keyPress(KeyCombo(keyCode: 123, modifiers: .maskControl)),
            .keyPress(KeyCombo(keyCode: 48, modifiers: .maskShift)),
            .keyPress(KeyCombo(keyCode: 13, modifiers: .maskCommand)),
            .systemAction(.playPause),
            .keyPress(KeyCombo(keyCode: 124, modifiers: .maskControl)),
            .keyPress(KeyCombo(
                keyCode: 17,
                modifiers: [.maskCommand, .maskShift]
            )),
        ])
    }

    func testLegacyStockDefaultMigratesWithoutOverwritingCustomMenus() throws {
        let suiteName = "RadialMenuGeometryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = RadialMenuConfiguration(
            name: "Arrow Keys",
            items: [
                RadialMenuItem(
                    label: "Up",
                    icon: "arrow.up",
                    action: .keyPress(KeyCombo(keyCode: 126))
                ),
                RadialMenuItem(
                    label: "Right",
                    icon: "arrow.right",
                    action: .keyPress(KeyCombo(keyCode: 124))
                ),
                RadialMenuItem(
                    label: "Down",
                    icon: "arrow.down",
                    action: .keyPress(KeyCombo(keyCode: 125))
                ),
                RadialMenuItem(
                    label: "Left",
                    icon: "arrow.left",
                    action: .keyPress(KeyCombo(keyCode: 123))
                ),
            ]
        )
        legacy.save(defaults: defaults)

        let migrated = RadialMenuConfiguration.load(defaults: defaults)

        XCTAssertTrue(migrated.outerRingEnabled)
        XCTAssertEqual(migrated.outerRingItems.count, 8)

        var custom = legacy
        custom.deadzoneSize = 45
        custom.save(defaults: defaults)
        XCTAssertEqual(
            RadialMenuConfiguration.load(defaults: defaults).deadzoneSize,
            45
        )
    }

    private func resolve(
        _ point: CGPoint,
        _ configuration: RadialMenuConfiguration
    ) -> RadialMenuSelection? {
        RadialMenuGeometry.resolve(offset: point, configuration: configuration).selection
    }
}
