import XCTest
@testable import JamCon

final class SyntheticOutputCoordinatorTests: XCTestCase {
    func testDuplicateReportsFromSameOwnerAreIdempotent() {
        let backend = RecordingSyntheticEventBackend()
        let coordinator = SyntheticOutputCoordinator(backend: backend)
        let owner = makeOwner(deviceID: "joycon", control: "a")

        coordinator.set(.mouseButton(.left), pressed: true, owner: owner)
        coordinator.set(.mouseButton(.left), pressed: true, owner: owner)
        coordinator.set(.mouseButton(.left), pressed: false, owner: owner)
        coordinator.set(.mouseButton(.left), pressed: false, owner: owner)

        XCTAssertEqual(backend.events, [
            .mouseButton(.left, isPressed: true),
            .mouseButton(.left, isPressed: false),
        ])
    }

    func testTwoDevicesCanOwnSameOutputWithoutPrematureRelease() {
        let backend = RecordingSyntheticEventBackend()
        let coordinator = SyntheticOutputCoordinator(backend: backend)
        let first = makeOwner(deviceID: "joycon", control: "a")
        let second = makeOwner(deviceID: "sense", control: "trigger")
        let output = SyntheticOutput.key(KeyCombo(keyCode: 53))

        coordinator.set(output, pressed: true, owner: first)
        coordinator.set(output, pressed: true, owner: second)
        coordinator.set(output, pressed: false, owner: first)
        XCTAssertEqual(backend.events, [.key(KeyCombo(keyCode: 53), isPressed: true)])

        coordinator.set(output, pressed: false, owner: second)
        XCTAssertEqual(backend.events, [
            .key(KeyCombo(keyCode: 53), isPressed: true),
            .key(KeyCombo(keyCode: 53), isPressed: false),
        ])
    }

    func testDeviceDisconnectReleasesOnlyThatDevicesOutputs() {
        let backend = RecordingSyntheticEventBackend()
        let coordinator = SyntheticOutputCoordinator(backend: backend)
        let joyCon = ManagedDeviceKey(kind: .joyCon, id: "joycon")
        let sense = ManagedDeviceKey(kind: .sense, id: "sense")
        let sharedKey = SyntheticOutput.key(KeyCombo(keyCode: 49))

        coordinator.set(sharedKey, pressed: true, owner: makeOwner(device: joyCon, control: "a"))
        coordinator.set(sharedKey, pressed: true, owner: makeOwner(device: sense, control: "trigger"))
        coordinator.set(.mouseButton(.right), pressed: true, owner: makeOwner(device: joyCon, control: "b"))

        coordinator.releaseAll(for: joyCon)

        XCTAssertEqual(backend.events, [
            .key(KeyCombo(keyCode: 49), isPressed: true),
            .mouseButton(.right, isPressed: true),
            .mouseButton(.right, isPressed: false),
        ])
        XCTAssertEqual(coordinator.ownerCount(for: sharedKey), 1)

        coordinator.releaseAll()
        XCTAssertEqual(backend.events.last, .key(KeyCombo(keyCode: 49), isPressed: false))
    }

    func testRadialTapPulsesAlreadyHeldOutputAndPreservesHold() {
        let backend = RecordingSyntheticEventBackend()
        let executor = ActionExecutor(eventBackend: backend)
        let heldOwner = makeOwner(deviceID: "joycon", control: "a")
        let radialOwner = SyntheticOutputOwner(
            device: ManagedDeviceKey(kind: .joyCon, id: "joycon"),
            control: "radialMenu.selection",
            role: .radialMenu
        )
        let action = ButtonAction.keyPress(KeyCombo(keyCode: 36))

        executor.execute(action, isPressed: true, owner: heldOwner)
        executor.tap(action, owner: radialOwner)
        executor.execute(action, isPressed: false, owner: heldOwner)

        XCTAssertEqual(backend.events, [
            .key(KeyCombo(keyCode: 36), isPressed: true),
            .key(KeyCombo(keyCode: 36), isPressed: false),
            .key(KeyCombo(keyCode: 36), isPressed: true),
            .key(KeyCombo(keyCode: 36), isPressed: false),
        ])
    }

    func testHoldIsReleasedWhenDeviceStateIsLost() {
        let backend = RecordingSyntheticEventBackend()
        let executor = ActionExecutor(eventBackend: backend)
        let device = ManagedDeviceKey(kind: .sense, id: "sense")
        let holdOwner = makeOwner(device: device, control: "trigger", role: .hold)
        let action = ButtonAction.keyPress(KeyCombo(keyCode: 8, modifiers: .maskCommand))

        executor.execute(action, isPressed: true, owner: holdOwner)
        executor.releaseAll(for: device)

        XCTAssertEqual(backend.events, [
            .key(KeyCombo(keyCode: 8, modifiers: .maskCommand), isPressed: true),
            .key(KeyCombo(keyCode: 8, modifiers: .maskCommand), isPressed: false),
        ])
    }

    func testReleaseUsesMappingCapturedAtButtonDown() {
        let backend = RecordingSyntheticEventBackend()
        let executor = ActionExecutor(eventBackend: backend)
        let device = ManagedDeviceKey(kind: .joyCon, id: "joycon")
        let capturedState = InputEngine.ButtonPressState(
            actions: ButtonActions(press: .mouseClick(.left)),
            device: device,
            control: "a"
        )
        let editedMapping = ButtonActions(press: .mouseClick(.right))

        executor.execute(capturedState.actions.press, isPressed: true, owner: capturedState.pressOwner)
        XCTAssertNotEqual(capturedState.actions, editedMapping)
        executor.execute(capturedState.actions.press, isPressed: false, owner: capturedState.pressOwner)

        XCTAssertEqual(backend.events, [
            .mouseButton(.left, isPressed: true),
            .mouseButton(.left, isPressed: false),
        ])
    }

    func testSystemShortcutUsesCoordinatedTap() {
        let backend = RecordingSyntheticEventBackend()
        let executor = ActionExecutor(eventBackend: backend)
        let owner = makeOwner(deviceID: "joycon", control: "home")
        let combo = KeyCombo(keyCode: 126, modifiers: .maskControl)

        executor.execute(.systemAction(.missionControl), isPressed: true, owner: owner)

        XCTAssertEqual(backend.events, [
            .key(combo, isPressed: true),
            .key(combo, isPressed: false),
        ])
    }

    private func makeOwner(
        deviceID: String,
        control: String,
        role: SyntheticOutputRole = .press
    ) -> SyntheticOutputOwner {
        makeOwner(device: ManagedDeviceKey(kind: .joyCon, id: deviceID), control: control, role: role)
    }

    private func makeOwner(
        device: ManagedDeviceKey,
        control: String,
        role: SyntheticOutputRole = .press
    ) -> SyntheticOutputOwner {
        SyntheticOutputOwner(device: device, control: control, role: role)
    }
}

private final class RecordingSyntheticEventBackend: SyntheticEventBackend {
    private(set) var events: [SyntheticOutputEvent] = []

    func post(_ event: SyntheticOutputEvent) {
        events.append(event)
    }
}
