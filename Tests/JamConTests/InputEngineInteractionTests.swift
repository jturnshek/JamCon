import XCTest
import QuartzCore
@testable import JamCon

final class InputEngineInteractionTests: XCTestCase {
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
