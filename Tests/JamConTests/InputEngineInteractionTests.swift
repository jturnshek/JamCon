import XCTest
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

    private func makeHarness(actions: ButtonActions) -> SenseEngineHarness {
        SenseEngineHarness(actions: actions)
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

    func process(trigger: UInt8, timestamp: TimeInterval) {
        var bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        bytes[0] = UInt8(SenseHIDProtocol.inputReportID)
        bytes[SenseHIDProtocol.Offset.triggerAnalog] = trigger
        let motion = try! SenseInputReportDecoder.decode(bytes).motion
        let report = SenseController.InputReport(
            controllerID: deviceID,
            bytes: bytes,
            length: bytes.count,
            gyroX: motion.gyroX,
            gyroY: motion.gyroY,
            gyroZ: motion.gyroZ,
            accelX: motion.accelX,
            accelY: motion.accelY,
            accelZ: motion.accelZ,
            timestamp: timestamp,
            receivedTimestamp: timestamp,
            inputTimestamp: nil,
            timestampSource: .hostReceipt,
            motionSamples: [motion]
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
