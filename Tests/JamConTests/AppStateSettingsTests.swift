import XCTest
@testable import JamCon

final class AppStateSettingsTests: XCTestCase {
    @MainActor
    func testSwitchingSidesPreservesPendingGyroEdit() async throws {
        // The test scheme uses an isolated preferences home. Restore its
        // domain after persistence completes so other tests remain independent.
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        defer { UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain) }
        let state = AppState(virtualGamepadAvailability: .missingEntitlement)
        state.configurationProfile = .joyConRight
        let edited = state.sensitivity + 17

        state.sensitivity = edited
        state.configurationProfile = .joyConLeft

        XCTAssertEqual(state.sensitivity, edited)
        XCTAssertEqual(state.settingsStore.snapshot().gyroSettings[.joyCon]?.sensitivity, edited)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(GyroSettingsState.load(for: .joyCon).sensitivity, edited)
        XCTAssertEqual(state.settingsStore.snapshot().gyroSettings[.joyCon]?.sensitivity, edited)
    }

    @MainActor
    func testQuickProfileRoundTripsPreservePendingButtonMappings() async throws {
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        defer { UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain) }
        let state = AppState(virtualGamepadAvailability: .missingEntitlement)
        let senseAction = ButtonAction.keyPress(KeyCombo(keyCode: 7))
        let joyConAction = ButtonAction.keyPress(KeyCombo(keyCode: 8))
        let mouseAction = ButtonAction.keyPress(KeyCombo(keyCode: 9))

        state.configurationProfile = .senseRight
        state.buttonMappingProfile.setPressAction(senseAction, for: .trigger)
        state.configurationProfile = .joyConRight
        state.configurationProfile = .senseRight
        XCTAssertEqual(state.buttonMappingProfile.actions(for: .trigger).press, senseAction)
        XCTAssertEqual(state.settingsStore.snapshot().senseButtonMappings[.senseRight]?.actions(for: .trigger).press, senseAction)

        state.configurationProfile = .joyConRight
        state.joyConButtonMappingProfile.setPressAction(joyConAction, for: .zr)
        state.configurationProfile = .senseRight
        state.configurationProfile = .joyConRight
        XCTAssertEqual(state.joyConButtonMappingProfile.actions(for: .zr).press, joyConAction)
        XCTAssertEqual(state.settingsStore.snapshot().joyConButtonMappings[.joyConRight]?.actions(for: .zr).press, joyConAction)

        state.configurationProfile = .mouse
        state.g502xButtonMappingProfile.setPressAction(mouseAction, for: .dpiShift)
        state.configurationProfile = .senseRight
        state.configurationProfile = .mouse
        XCTAssertEqual(state.g502xButtonMappingProfile.actions(for: .dpiShift).press, mouseAction)
        XCTAssertEqual(state.settingsStore.snapshot().g502xButtonMappings[.mouse]?.actions(for: .dpiShift).press, mouseAction)

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(SenseButtonMappingProfile.load(for: .senseRight).actions(for: .trigger).press, senseAction)
        XCTAssertEqual(JoyConButtonMappingProfile.load(for: .joyConRight).actions(for: .zr).press, joyConAction)
        XCTAssertEqual(G502XButtonMappingProfile.load(for: .mouse).actions(for: .dpiShift).press, mouseAction)
    }
}
