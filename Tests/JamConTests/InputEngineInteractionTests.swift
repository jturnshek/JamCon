import XCTest
import QuartzCore
@testable import JamCon

final class InputEngineInteractionTests: XCTestCase {
    func testRemappingHeldMouseButtonToGyroModeReleasesCapturedOutput() {
        for kind in ControllerKind.allCases {
            for mode: ButtonAction in [.drag, .scroll, .radialMenu] {
                let harness = ButtonLifecycleHarness(kind: kind)
                defer { harness.engine.stop() }
                harness.setActions(ButtonActions(press: .mouseClick(.left)))
                harness.process()
                harness.process(first: true)
                harness.setActions(ButtonActions(press: mode))
                harness.process()
                XCTAssertEqual(harness.backend.events, [
                    .mouseButton(.left, isPressed: true),
                    .mouseButton(.left, isPressed: false),
                ], "\(kind): remapped to \(mode)")
            }
        }
    }

    func testRemappingHeldKeyToGyroModeReleasesCapturedOutput() {
        let key = KeyCombo(keyCode: 49)
        for kind in ControllerKind.allCases {
            for mode: ButtonAction in [.drag, .scroll, .radialMenu] {
                let harness = ButtonLifecycleHarness(kind: kind)
                defer { harness.engine.stop() }
                harness.setActions(ButtonActions(press: .none, hold: .keyPress(key)))
                harness.process()
                harness.process(first: true)
                harness.engine.engineQueueSync { harness.scheduler.fireAll() }
                harness.setActions(ButtonActions(press: mode))
                harness.process()
                XCTAssertEqual(harness.backend.events, [
                    .key(key, isPressed: true),
                    .key(key, isPressed: false),
                ], "\(kind): remapped to \(mode)")
            }
        }
    }

    func testReleasingOneOfTwoGyroModeButtonsPreservesOther() {
        for kind in ControllerKind.allCases {
            for mode: ButtonAction in [.drag, .scroll] {
                let harness = ButtonLifecycleHarness(kind: kind)
                defer { harness.engine.stop() }
                harness.setActions(ButtonActions(press: mode))
                harness.setActions(ButtonActions(press: mode), second: true)
                harness.process()
                harness.process(first: true)
                harness.process(first: true, second: true)
                harness.process(first: true, second: true) // Duplicate frame
                harness.process(second: true)
                XCTAssertTrue(harness.isHeld(mode), "\(kind): \(mode)")
                harness.process()
                XCTAssertFalse(harness.isHeld(mode), "\(kind): \(mode)")
            }
        }
    }

    func testPrimedGyroModeReleaseDoesNotCancelAnotherButton() {
        for kind in ControllerKind.allCases {
            for mode: ButtonAction in [.drag, .scroll] {
                let harness = ButtonLifecycleHarness(kind: kind)
                defer { harness.engine.stop() }
                harness.setActions(ButtonActions(press: mode))
                harness.setActions(ButtonActions(press: mode), second: true)
                harness.process(first: true) // Already held at connection; no action owned
                harness.process(first: true, second: true)
                harness.process(second: true)
                XCTAssertTrue(harness.isHeld(mode), "\(kind): \(mode)")
                harness.process()
                XCTAssertFalse(harness.isHeld(mode), "\(kind): \(mode)")
            }
        }
    }

    func testGyroModeReleaseUsesCapturedMapping() {
        for kind in ControllerKind.allCases {
            let harness = ButtonLifecycleHarness(kind: kind)
            defer { harness.engine.stop() }
            harness.setActions(ButtonActions(press: .scroll))
            harness.process()
            harness.process(first: true)
            harness.setActions(ButtonActions(press: .drag))
            harness.process()
            XCTAssertFalse(harness.isHeld(.scroll), "\(kind)")
            XCTAssertFalse(harness.isHeld(.drag), "\(kind)")
        }
    }

    func testGyroModeOwnershipClearsWhenInputIsDisabled() {
        for kind in ControllerKind.allCases {
            for mode: ButtonAction in [.drag, .scroll] {
                let harness = ButtonLifecycleHarness(kind: kind)
                defer { harness.engine.stop() }
                harness.setActions(ButtonActions(press: mode))
                harness.process()
                harness.process(first: true)
                XCTAssertTrue(harness.isHeld(mode))
                harness.settings.update { $0.isEnabled = false }
                harness.engine.setInputEnabled(false)
                XCTAssertFalse(harness.isHeld(mode))
                harness.settings.update { $0.isEnabled = true }
                harness.engine.setInputEnabled(true)
                harness.process(first: true) // Re-prime without reactivating the mode
                XCTAssertFalse(harness.isHeld(mode))
                harness.process()
                harness.process(first: true)
                XCTAssertTrue(harness.isHeld(mode))
            }
        }
    }

    func testDuplicatePressAndMappingEditStillReleaseCapturedAction() {
        let harness = makeHarness(actions: ButtonActions(press: .mouseClick(.left)))

        harness.process(trigger: 0, timestamp: 1.0)   // Prime
        harness.process(trigger: 255, timestamp: 1.1)
        harness.process(trigger: 255, timestamp: 1.2) // Duplicate snapshot

        var edited = SenseButtonMappingProfile()
        edited.setActions(ButtonActions(press: .mouseClick(.right)), for: .trigger)
        harness.settings.update { $0.senseButtonMappings[.senseRight] = edited }
        harness.process(trigger: 0, timestamp: 1.3)

        XCTAssertEqual(harness.backend.events, [
            .mouseButton(.left, isPressed: true),
            .mouseButton(.left, isPressed: false),
        ])
        harness.shutdown()
    }

    func testHoldFiresDeterministicallyAndSuppressesTapAction() {
        let tap = KeyCombo(keyCode: 8)
        let hold = KeyCombo(keyCode: 9, modifiers: .maskCommand)
        let harness = makeHarness(actions: ButtonActions(press: .keyPress(tap), hold: .keyPress(hold)))

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 255, timestamp: 1.1)
        XCTAssertTrue(harness.backend.events.isEmpty)

        harness.fireScheduledHolds()
        harness.process(trigger: 0, timestamp: 1.2)

        XCTAssertEqual(harness.backend.events, [
            .key(hold, isPressed: true),
            .key(hold, isPressed: false),
        ])
        harness.shutdown()
    }

    func testShortPressProducesBalancedTap() {
        let combo = KeyCombo(keyCode: 53)
        let harness = makeHarness(actions: ButtonActions(press: .keyPress(combo), hold: .keyPress(KeyCombo(keyCode: 49))))

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 255, timestamp: 1.1)
        harness.process(trigger: 0, timestamp: 1.2)

        XCTAssertEqual(harness.backend.events, [
            .key(combo, isPressed: true),
            .key(combo, isPressed: false),
        ])
        harness.shutdown()
    }

    func testImmediateMousePressCanAlsoFireAndReleaseHoldAction() {
        let hold = KeyCombo(keyCode: 49)
        let harness = makeHarness(
            actions: ButtonActions(
                press: .mouseClick(.left),
                hold: .keyPress(hold)
            )
        )

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 255, timestamp: 1.1)
        harness.fireScheduledHolds()
        harness.process(trigger: 0, timestamp: 1.2)

        XCTAssertEqual(harness.backend.events, [
            .mouseButton(.left, isPressed: true),
            .key(hold, isPressed: true),
            .mouseButton(.left, isPressed: false),
            .key(hold, isPressed: false),
        ])
        harness.shutdown()
    }

    func testGlobalDisableReleasesMouseDownBeforeIgnoringReleaseReport() {
        let harness = makeHarness(actions: ButtonActions(press: .mouseClick(.left)))

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 255, timestamp: 1.1)
        harness.settings.update { $0.isEnabled = false }
        harness.engine.setInputEnabled(false)
        harness.process(trigger: 0, timestamp: 1.2)

        XCTAssertEqual(harness.backend.events, [
            .mouseButton(.left, isPressed: true),
            .mouseButton(.left, isPressed: false),
        ])
        harness.shutdown()
    }

    func testDeviceUnmanageReleasesOutputWhenPhysicalReleaseWasLost() {
        let harness = makeHarness(actions: ButtonActions(press: .mouseClick(.middle)))

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 255, timestamp: 1.1)
        harness.engine.setDeviceManaged(id: harness.deviceID, kind: .sense, isLeft: false, managed: false)

        XCTAssertEqual(harness.backend.events, [
            .mouseButton(.middle, isPressed: true),
            .mouseButton(.middle, isPressed: false),
        ])
        harness.shutdown()
    }

    func testEngineStopReleasesHeldOutputAndCancelsPendingHold() {
        let harness = makeHarness(
            actions: ButtonActions(
                press: .mouseClick(.right),
                hold: .keyPress(KeyCombo(keyCode: 49))
            )
        )

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 255, timestamp: 1.1)
        harness.engine.stop()
        harness.fireScheduledHolds()

        XCTAssertEqual(harness.backend.events, [
            .mouseButton(.right, isPressed: true),
            .mouseButton(.right, isPressed: false),
        ])
    }

    func testSenseTriggerHysteresisPreventsThresholdChatter() {
        let harness = makeHarness(actions: ButtonActions(press: .mouseClick(.left)))

        harness.process(trigger: 0, timestamp: 1.0)
        harness.process(trigger: 128, timestamp: 1.1)
        harness.process(trigger: 125, timestamp: 1.2)
        harness.process(trigger: 121, timestamp: 1.3)
        harness.process(trigger: 120, timestamp: 1.4)

        XCTAssertEqual(harness.backend.events, [
            .mouseButton(.left, isPressed: true),
            .mouseButton(.left, isPressed: false),
        ])
        harness.shutdown()
    }

    func testSenseJoystickScrollTimingIsReportRateIndependentAndBounded() {
        var timing = JoystickScrollTiming()

        XCTAssertEqual(timing.frameScale(at: 1, nominalRate: 60), 1)
        XCTAssertEqual(timing.frameScale(at: 1 + 1.0 / 120.0, nominalRate: 60), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(timing.frameScale(at: 1 + 1.0 / 60.0, nominalRate: 60), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(timing.frameScale(at: 2, nominalRate: 60), 3, accuracy: 0.000_001)
        XCTAssertEqual(timing.frameScale(at: 1.5, nominalRate: 60), 0)
    }

    func testPixelScrollAccumulatorPreservesSubpixelMotion() {
        var accumulator = PixelScrollAccumulator()

        let first = accumulator.consume(dx: 0.4, dy: -0.4)
        let second = accumulator.consume(dx: 0.4, dy: -0.4)
        let third = accumulator.consume(dx: 0.4, dy: -0.4)

        XCTAssertEqual(first.x, 0)
        XCTAssertEqual(first.y, 0)
        XCTAssertEqual(second.x, 0)
        XCTAssertEqual(second.y, 0)
        XCTAssertEqual(third.x, 1)
        XCTAssertEqual(third.y, -1)
    }

    func testRadialMenuActivationFailureRollsBackWithoutPublishingShow() {
        let harness = RadialEngineHarness(cursorPosition: nil)

        let opened = harness.begin(control: "radial")

        XCTAssertFalse(opened)
        XCTAssertNil(harness.engine.radialMenuOwner)
        XCTAssertNil(harness.engine.radialMenuActivationOwner)
        XCTAssertNil(harness.engine.radialMenuActiveConfiguration)
        XCTAssertFalse(harness.engine.mouseMode.radialMenuButtonHeld)
        XCTAssertTrue(harness.presentations.isEmpty)
        harness.shutdown()
    }

    func testOnlyInitiatingRadialControlCanDismissActiveMenu() {
        let harness = RadialEngineHarness()

        XCTAssertTrue(harness.begin(control: "first"))
        XCTAssertFalse(harness.begin(control: "second"))
        harness.release(control: "second")

        XCTAssertEqual(harness.engine.radialMenuOwner, harness.owner)
        XCTAssertTrue(harness.engine.mouseMode.radialMenuButtonHeld)
        XCTAssertEqual(harness.presentations.filter(\.isShow).count, 1)
        XCTAssertEqual(harness.presentations.filter(\.isHide).count, 0)

        harness.release(control: "first")
        XCTAssertNil(harness.engine.radialMenuOwner)
        XCTAssertFalse(harness.engine.mouseMode.radialMenuButtonHeld)
        XCTAssertEqual(harness.presentations.filter(\.isHide).count, 1)
        harness.shutdown()
    }

    func testRadialGestureUsesConfigurationCapturedWhenItOpened() {
        let originalAction = KeyCombo(keyCode: 8)
        let replacementAction = KeyCombo(keyCode: 9)
        let harness = RadialEngineHarness(
            configuration: .singleItem(action: originalAction)
        )

        harness.performWhileEngineQueueIsBlocked {
            XCTAssertTrue(harness.beginOnEngineQueue(control: "radial"))
            harness.settings.update {
                $0.radialMenuConfiguration = .singleItem(
                    action: replacementAction
                )
            }
            harness.engine.routeGyroMovement(
                owner: harness.owner,
                dx: 20,
                dy: 0,
                cursorEnabled: false,
                hasDragMapping: false,
                modeState: harness.engine.mouseMode
            )
            harness.releaseOnEngineQueue(control: "radial")
        }

        XCTAssertEqual(harness.backend.events, [
            .key(originalAction, isPressed: true),
            .key(originalAction, isPressed: false),
        ])
        XCTAssertNil(harness.engine.radialMenuActiveConfiguration)
        harness.shutdown()
    }

    func testRadialActionWaitsUntilHidePresentationIsApplied() {
        let action = KeyCombo(keyCode: 8)
        let harness = RadialEngineHarness(
            configuration: .singleItem(action: action),
            automaticallyApplyPresentations: false
        )

        harness.performWhileEngineQueueIsBlocked {
            XCTAssertTrue(harness.beginOnEngineQueue(control: "radial"))
            harness.engine.routeGyroMovement(
                owner: harness.owner,
                dx: 20,
                dy: 0,
                cursorEnabled: false,
                hasDragMapping: false,
                modeState: harness.engine.mouseMode
            )
            harness.releaseOnEngineQueue(control: "radial")
        }

        XCTAssertTrue(harness.backend.events.isEmpty)
        XCTAssertNotNil(harness.engine.pendingRadialMenuAction)

        harness.applyPendingPresentations()

        XCTAssertEqual(harness.backend.events, [
            .key(action, isPressed: true),
            .key(action, isPressed: false),
        ])
        XCTAssertNil(harness.engine.pendingRadialMenuAction)
        harness.shutdown()
    }

    func testDeviceCancellationDropsRadialActionWaitingForPresentation() {
        let harness = RadialEngineHarness(
            configuration: .singleItem(action: KeyCombo(keyCode: 8)),
            automaticallyApplyPresentations: false
        )

        harness.performWhileEngineQueueIsBlocked {
            XCTAssertTrue(harness.beginOnEngineQueue(control: "radial"))
            harness.engine.routeGyroMovement(
                owner: harness.owner,
                dx: 20,
                dy: 0,
                cursorEnabled: false,
                hasDragMapping: false,
                modeState: harness.engine.mouseMode
            )
            harness.releaseOnEngineQueue(control: "radial")
        }
        harness.engine.engineQueue.sync {
            harness.engine.cancelRadialMenuIfOwned(by: harness.owner)
        }
        harness.applyPendingPresentations()

        XCTAssertTrue(harness.backend.events.isEmpty)
        XCTAssertNil(harness.engine.pendingRadialMenuAction)
        harness.shutdown()
    }

    func testExternalRadialDismissalClearsPresentationAndHeldState() {
        let harness = RadialEngineHarness()

        XCTAssertTrue(harness.begin(control: "radial"))
        harness.engine.engineQueue.sync {
            harness.engine.cancelRadialMenuIfOwned(by: harness.owner)
        }

        XCTAssertNil(harness.engine.radialMenuOwner)
        XCTAssertNil(harness.engine.radialMenuActivationOwner)
        XCTAssertNil(harness.engine.radialMenuActiveConfiguration)
        XCTAssertFalse(harness.engine.mouseMode.radialMenuButtonHeld)
        XCTAssertEqual(harness.presentations.filter(\.isShow).count, 1)
        XCTAssertEqual(harness.presentations.filter(\.isHide).count, 1)
        harness.shutdown()
    }

    func testJoyCon2ControlOnlyFramesPreserveRadialPressAndReleaseEdges() {
        let settings = SettingsStore()
        var mapping = JoyConButtonMappingProfile()
        mapping.setActions(ButtonActions(press: .radialMenu), for: .a)
        settings.update {
            $0.joyConButtonMappings[.joyCon2Right] = mapping
            $0.cursorControlEnabledByProfile[.joyCon2Right] = false
        }

        let engine = InputEngine(
            settings: settings,
            debugBuffer: DebugBuffer(),
            radialMenuCursorPositionProvider: { CGPoint(x: 400, y: 300) }
        )
        let deviceID = "joycon2-right"
        var presentations: [RadialMenuPresentationEvent] = []
        engine.onRadialMenuPresentation = { event, didApply in
            presentations.append(event)
            didApply?()
        }

        engine.engineQueue.sync {
            engine.isRunning = true
            engine.joyConDevices[deviceID] = InputEngine.JoyConDeviceState(
                id: deviceID,
                profile: .joyCon2Right
            )

            processJoyCon2ControlOnlyFrame(engine: engine, deviceID: deviceID, aPressed: false)
            processJoyCon2ControlOnlyFrame(engine: engine, deviceID: deviceID, aPressed: true)
            processJoyCon2ControlOnlyFrame(engine: engine, deviceID: deviceID, aPressed: false)
        }

        XCTAssertEqual(presentations.filter(\.isShow).count, 1)
        XCTAssertEqual(presentations.filter(\.isHide).count, 1)
        XCTAssertNil(engine.radialMenuOwner)
        XCTAssertFalse(engine.joyConDevices[deviceID]?.mode.radialMenuButtonHeld ?? true)
        engine.stop()
    }

    private func makeHarness(actions: ButtonActions) -> SenseEngineHarness {
        SenseEngineHarness(actions: actions)
    }

    private func processJoyCon2ControlOnlyFrame(
        engine: InputEngine,
        deviceID: String,
        aPressed: Bool
    ) {
        var bytes = [UInt8](repeating: 0, count: 0x3F)
        bytes[4] = aPressed ? 0x08 : 0
        let timestamp = CACurrentMediaTime()
        engine.processJoyConReport(
            InputDeviceFrame(
                backend: engine.joyCon2Backend.backendDescriptor,
                deviceID: deviceID,
                reportID: 0x05,
                bytes: bytes,
                motion: .none,
                timestamp: timestamp,
                receivedTimestamp: timestamp,
                inputTimestamp: nil,
                timestampSource: .hostReceipt
            )
        )
    }
}

private extension RadialMenuPresentationEvent {
    var isShow: Bool {
        if case .show = self { return true }
        return false
    }

    var isHide: Bool {
        if case .hide = self { return true }
        return false
    }
}

private extension RadialMenuConfiguration {
    static func singleItem(action: KeyCombo) -> RadialMenuConfiguration {
        RadialMenuConfiguration(
            name: "Test",
            items: [
                RadialMenuItem(
                    label: "Test",
                    action: .keyPress(action)
                ),
            ],
            deadzoneSize: 1,
            innerRingSize: 50,
            radialMovementScale: 2
        )
    }
}

private final class RadialEngineHarness {
    let settings = SettingsStore()
    let backend = EngineRecordingBackend()
    let engine: InputEngine
    let owner = ManagedDeviceKey(kind: .mouse, id: "radial-mouse")
    private(set) var presentations: [RadialMenuPresentationEvent] = []
    private var pendingPresentationCompletions: [@Sendable () -> Void] = []
    private let automaticallyApplyPresentations: Bool

    init(
        cursorPosition: CGPoint? = CGPoint(x: 400, y: 300),
        configuration: RadialMenuConfiguration = .default,
        automaticallyApplyPresentations: Bool = true
    ) {
        self.automaticallyApplyPresentations = automaticallyApplyPresentations
        settings.update {
            $0.radialMenuConfiguration = configuration
        }
        engine = InputEngine(
            settings: settings,
            debugBuffer: DebugBuffer(),
            actionExecutor: ActionExecutor(eventBackend: backend),
            radialMenuCursorPositionProvider: { cursorPosition }
        )
        engine.onRadialMenuPresentation = { [weak self] event, didApply in
            guard let self else {
                didApply?()
                return
            }
            self.presentations.append(event)
            if self.automaticallyApplyPresentations {
                didApply?()
            } else if let didApply {
                self.pendingPresentationCompletions.append(didApply)
            }
        }
        engine.engineQueue.sync {
            engine.isRunning = true
            engine.selectedMouseID = owner.id
        }
    }

    func begin(control: String) -> Bool {
        engine.engineQueue.sync {
            beginOnEngineQueue(control: control)
        }
    }

    func beginOnEngineQueue(control: String) -> Bool {
        engine.beginRadialMenu(
            owner: owner,
            activationOwner: activation(control: control),
            pointerStyle: .systemCursor,
            modeState: &engine.mouseMode
        )
    }

    func release(control: String) {
        engine.engineQueue.sync {
            releaseOnEngineQueue(control: control)
        }
    }

    func releaseOnEngineQueue(control: String) {
        engine.handleGyroModeRelease(
            owner: owner,
            activationOwner: activation(control: control),
            action: .radialMenu,
            modeState: &engine.mouseMode
        )
    }

    func performWhileEngineQueueIsBlocked(_ work: () -> Void) {
        engine.engineQueue.sync(execute: work)
        drainEngineQueue()
    }

    func applyPendingPresentations() {
        let completions = pendingPresentationCompletions
        pendingPresentationCompletions.removeAll()
        for completion in completions {
            completion()
        }
        drainEngineQueue()
    }

    func shutdown() {
        engine.engineQueue.sync {
            engine.dismissActiveRadialMenu()
            engine.isRunning = false
        }
    }

    private func activation(control: String) -> SyntheticOutputOwner {
        SyntheticOutputOwner(
            device: owner,
            control: control,
            role: .press
        )
    }

    private func drainEngineQueue() {
        engine.engineQueue.sync {}
    }
}

private final class SenseEngineHarness {
    let settings = SettingsStore()
    let backend = EngineRecordingBackend()
    let scheduler = ManualHoldScheduler()
    let engine: InputEngine
    let deviceID = "sense-right"

    init(actions: ButtonActions) {
        var mapping = SenseButtonMappingProfile(holdThreshold: 10)
        mapping.setActions(actions, for: .trigger)
        settings.update {
            $0.senseButtonMappings[.senseRight] = mapping
            $0.cursorControlEnabledByProfile[.senseRight] = false
        }

        let executor = ActionExecutor(eventBackend: backend)
        engine = InputEngine(
            settings: settings,
            debugBuffer: DebugBuffer(),
            actionExecutor: executor,
            holdScheduler: scheduler
        )

        engine.engineQueue.sync {
            engine.isRunning = true
            engine.senseDevices[deviceID] = InputEngine.SenseDeviceState(id: deviceID, profile: .senseRight)
        }
    }

    func process(trigger: UInt8, timestamp _: TimeInterval) {
        var bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        bytes[0] = UInt8(SenseHIDProtocol.inputReportID)
        bytes[SenseHIDProtocol.Offset.triggerAnalog] = trigger
        let motion = try! SenseInputReportDecoder.decode(bytes).motion
        let timestamp = CACurrentMediaTime()
        let report = InputDeviceFrame(
            backend: engine.senseBackend.backendDescriptor,
            deviceID: deviceID,
            reportID: SenseHIDProtocol.inputReportID,
            bytes: bytes,
            motion: .single(motion),
            timestamp: timestamp,
            receivedTimestamp: timestamp,
            inputTimestamp: nil,
            timestampSource: .hostReceipt
        )

        engine.engineQueue.sync {
            engine.processSenseReport(report)
        }
    }

    func fireScheduledHolds() {
        engine.engineQueue.sync {
            scheduler.fireAll()
        }
    }

    func shutdown() {
        engine.stop()
    }
}

private final class ManualHoldScheduler: HoldScheduling {
    private var pending: [DispatchWorkItem] = []

    func schedule(_ workItem: DispatchWorkItem, after delay: TimeInterval, on queue: DispatchQueue) {
        pending.append(workItem)
    }

    func fireAll() {
        let work = pending
        pending.removeAll()
        for item in work where !item.isCancelled {
            item.perform()
        }
    }
}

private final class EngineRecordingBackend: SyntheticEventBackend {
    private(set) var events: [SyntheticOutputEvent] = []

    func post(_ event: SyntheticOutputEvent) {
        events.append(event)
    }
}

/// Exercises each family's real button edge processing with copied input frames.
private final class ButtonLifecycleHarness {
    let settings = SettingsStore()
    let backend = EngineRecordingBackend()
    let scheduler = ManualHoldScheduler()
    let engine: InputEngine
    let kind: ControllerKind
    let deviceID = "button-lifecycle-test"

    init(kind: ControllerKind) {
        self.kind = kind
        settings.update {
            $0.isEnabled = true
            $0.joystickScrollEnabled = false
            $0.cursorControlEnabledByProfile[.senseRight] = false
            $0.cursorControlEnabledByProfile[.joyConRight] = false
            $0.senseButtonMappings[.senseRight] = SenseButtonMappingProfile()
            $0.joyConButtonMappings[.joyConRight] = JoyConButtonMappingProfile()
            $0.g502xButtonMappings[.mouse] = G502XButtonMappingProfile()
        }
        engine = InputEngine(
            settings: settings,
            debugBuffer: DebugBuffer(),
            actionExecutor: ActionExecutor(eventBackend: backend),
            holdScheduler: scheduler
        )
        engine.engineQueueSync {
            engine.isRunning = true
            switch kind {
            case .sense:
                engine.senseDevices[deviceID] = InputEngine.SenseDeviceState(id: deviceID, profile: .senseRight)
            case .joyCon:
                engine.joyConDevices[deviceID] = InputEngine.JoyConDeviceState(id: deviceID, profile: .joyConRight)
            case .mouse:
                engine.selectedMouseID = deviceID
            }
        }
    }

    func setActions(_ actions: ButtonActions, second: Bool = false) {
        settings.update {
            switch kind {
            case .sense:
                $0.senseButtonMappings[.senseRight]?.setActions(actions, for: second ? .bumper : .trigger)
            case .joyCon:
                $0.joyConButtonMappings[.joyConRight]?.setActions(actions, for: second ? .r : .zr)
            case .mouse:
                $0.g502xButtonMappings[.mouse]?.setActions(actions, for: second ? .dpiUp : .dpiShift)
            }
        }
    }

    func process(first: Bool = false, second: Bool = false) {
        let descriptor: InputDeviceBackendDescriptor
        var bytes: [UInt8]
        let motion: InputDeviceMotionSamples
        switch kind {
        case .sense:
            descriptor = engine.senseBackend.backendDescriptor
            bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
            bytes[0] = UInt8(SenseHIDProtocol.inputReportID)
            bytes[SenseHIDProtocol.Offset.triggerAnalog] = first ? 255 : 0
            bytes[9] = second ? 0x20 : 0 // Right bumper
            motion = .single(try! SenseInputReportDecoder.decode(bytes).motion)
        case .joyCon:
            descriptor = engine.joyConController.backendDescriptor
            bytes = [UInt8](repeating: 0, count: JoyConInputReportDecoder.minimumReportLength)
            bytes[0] = UInt8(JoyConHIDProtocol.inputReportID)
            bytes[3] = (first ? 0x80 : 0) | (second ? 0x40 : 0) // ZR, R
            motion = .batch(try! JoyConInputReportDecoder.decode(bytes).motionSamples)
        case .mouse:
            descriptor = engine.g502xController.backendDescriptor
            bytes = [first ? 0x20 : 0, second ? 0x02 : 0] // DPI Shift, DPI Up
            motion = .none
        }
        let timestamp = CACurrentMediaTime()
        let report = InputDeviceFrame(
            backend: descriptor,
            deviceID: deviceID,
            reportID: UInt32(bytes[0]),
            bytes: bytes,
            motion: motion,
            timestamp: timestamp,
            receivedTimestamp: timestamp,
            inputTimestamp: nil,
            timestampSource: .hostReceipt
        )
        engine.engineQueueSync {
            switch kind {
            case .sense: engine.processSenseReport(report)
            case .joyCon: engine.processJoyConReport(report)
            case .mouse: engine.processG502XReport(report)
            }
        }
    }

    func isHeld(_ action: ButtonAction) -> Bool {
        engine.engineQueueSync {
            let mode: InputEngine.GyroModeState
            switch kind {
            case .sense: mode = engine.senseDevices[deviceID]!.mode
            case .joyCon: mode = engine.joyConDevices[deviceID]!.mode
            case .mouse: mode = engine.mouseMode
            }
            return action == .drag ? mode.dragButtonHeld : mode.scrollButtonHeld
        }
    }
}
