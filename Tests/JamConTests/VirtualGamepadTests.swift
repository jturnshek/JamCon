import XCTest
import QuartzCore
@testable import JamCon

final class VirtualGamepadTests: XCTestCase {
    func testNeutralReportEncoding() {
        let report = VirtualGamepadHIDReport(state: VirtualGamepadState())

        XCTAssertEqual(report.bytes.count, VirtualGamepadHIDDescriptor.reportLength)
        XCTAssertEqual(
            report.bytes,
            [1, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
    }

    func testReportEncodingPreservesBitsAxesAndTriggers() {
        let state = VirtualGamepadState(
            buttons: [.button(.south), .button(.rightStick), .button(.auxiliary)],
            hat: .southWest,
            leftX: -32_767,
            leftY: 32_767,
            rightX: -12_345,
            rightY: 12_345,
            leftTrigger: 1,
            rightTrigger: 255
        )

        let report = VirtualGamepadHIDReport(state: state)

        XCTAssertEqual(report.bytes[0], 1)
        XCTAssertEqual(readUInt16(report.bytes, at: 1), 0x1081)
        XCTAssertEqual(report.bytes[3], VirtualGamepadHat.southWest.rawValue)
        XCTAssertEqual(readInt16(report.bytes, at: 4), -32_767)
        XCTAssertEqual(readInt16(report.bytes, at: 6), 32_767)
        XCTAssertEqual(readInt16(report.bytes, at: 8), -12_345)
        XCTAssertEqual(readInt16(report.bytes, at: 10), 12_345)
        XCTAssertEqual(report.bytes[12], 1)
        XCTAssertEqual(report.bytes[13], 255)
    }

    func testComposerRequiresBothHalvesAndStopsWhenOneIsRemoved() {
        var composer = LinkedJoyConGamepadComposer()

        XCTAssertNil(composer.update(JoyConGamepadHalfState(side: .left), timestamp: 1))
        XCTAssertNotNil(composer.update(JoyConGamepadHalfState(side: .right), timestamp: 1))
        XCTAssertNil(composer.remove(.left))
    }

    func testComposerMapsPhysicalControlsWithoutReducingStickResolution() throws {
        var composer = LinkedJoyConGamepadComposer()
        composer.update(
            JoyConGamepadHalfState(
                side: .left,
                stickX: -30_001,
                stickY: 29_999,
                pressedButtons: [
                    .dpadUp, .dpadRight, .l, .zl, .minus, .capture, .stickClick,
                ]
            ),
            timestamp: 1
        )

        let state = try XCTUnwrap(
            composer.update(
                JoyConGamepadHalfState(
                    side: .right,
                    stickX: 24_321,
                    stickY: -23_456,
                    pressedButtons: [
                        .a, .b, .x, .y, .r, .zr, .plus, .home, .stickClick, .c,
                    ]
                ),
                timestamp: 1
            )
        )

        XCTAssertEqual(state.leftX, -30_001)
        XCTAssertEqual(state.leftY, 29_999)
        XCTAssertEqual(state.rightX, 24_321)
        XCTAssertEqual(state.rightY, -23_456)
        XCTAssertEqual(state.hat, .northEast)
        XCTAssertEqual(state.leftTrigger, 255)
        XCTAssertEqual(state.rightTrigger, 255)

        for button in VirtualGamepadButton.allCases {
            XCTAssertTrue(
                state.buttons.contains(.button(button)),
                "Expected \(button) to be pressed"
            )
        }
    }

    func testOpposingDPadDirectionsCancelPerAxis() throws {
        var composer = LinkedJoyConGamepadComposer()
        composer.update(
            JoyConGamepadHalfState(
                side: .left,
                pressedButtons: [.dpadUp, .dpadDown, .dpadLeft]
            ),
            timestamp: 1
        )

        let state = try XCTUnwrap(
            composer.update(JoyConGamepadHalfState(side: .right), timestamp: 1)
        )

        XCTAssertEqual(state.hat, .west)
    }

    func testEachHalfUpdateImmediatelyUsesLatestOtherHalf() throws {
        var composer = LinkedJoyConGamepadComposer()
        composer.update(
            JoyConGamepadHalfState(side: .left, stickX: 100, stickY: 200),
            timestamp: 1
        )
        let initial = try XCTUnwrap(
            composer.update(
                JoyConGamepadHalfState(side: .right, stickX: 300, stickY: 400),
                timestamp: 1
            )
        )
        XCTAssertEqual(initial.leftX, 100)
        XCTAssertEqual(initial.rightX, 300)

        let updated = try XCTUnwrap(
            composer.update(
                JoyConGamepadHalfState(side: .left, stickX: 500, stickY: 600),
                timestamp: 2
            )
        )
        XCTAssertEqual(updated.leftX, 500)
        XCTAssertEqual(updated.rightX, 300)
    }

    func testComposerRejectsAStaleHalf() {
        var composer = LinkedJoyConGamepadComposer()
        composer.update(
            JoyConGamepadHalfState(side: .left, stickX: 100),
            timestamp: 10
        )
        composer.update(
            JoyConGamepadHalfState(side: .right, stickX: 200),
            timestamp: 10.1
        )

        XCTAssertNotNil(composer.freshState(at: 10.2, timeout: 0.25))
        XCTAssertNil(composer.freshState(at: 10.26, timeout: 0.25))
    }

    func testOriginalJoyConFactoryCalibrationDecodingAndFallback() throws {
        XCTAssertEqual(
            JoyConHIDProtocol.factoryStickCalibrationReadPayload(isLeft: true),
            [0x3D, 0x60, 0x00, 0x00, 0x09]
        )
        XCTAssertEqual(
            JoyConHIDProtocol.factoryStickCalibrationReadPayload(isLeft: false),
            [0x46, 0x60, 0x00, 0x00, 0x09]
        )

        let center: (UInt16, UInt16) = (2_000, 2_100)
        let negative: (UInt16, UInt16) = (1_500, 1_400)
        let positive: (UInt16, UInt16) = (1_600, 1_500)
        var reply = [UInt8](repeating: 0, count: 29)
        reply[0] = UInt8(JoyConHIDProtocol.subcommandReplyReportID)
        reply[13] = 0x90
        reply[14] = JoyConHIDProtocol.spiReadSubcommand
        reply.replaceSubrange(15...18, with: [0x46, 0x60, 0x00, 0x00])
        reply[19] = 9
        writePackedPair(center, to: &reply, at: 20)
        writePackedPair(negative, to: &reply, at: 23)
        writePackedPair(positive, to: &reply, at: 26)

        let calibration = try XCTUnwrap(
            JoyConHIDProtocol.decodeFactoryStickCalibrationReply(reply, isLeft: false)
        )
        XCTAssertEqual(calibration.centerX, center.0)
        XCTAssertEqual(calibration.centerY, center.1)
        XCTAssertEqual(calibration.negativeRangeX, negative.0)
        XCTAssertEqual(calibration.negativeRangeY, negative.1)
        XCTAssertEqual(calibration.positiveRangeX, positive.0)
        XCTAssertEqual(calibration.positiveRangeY, positive.1)
        XCTAssertEqual(
            JoyConHIDProtocol.conservativeStickCalibration.positiveRangeX,
            1_600
        )
    }

    func testAxisNormalizerPreservesCenterDeadzoneAndFullRange() {
        XCTAssertEqual(
            VirtualGamepadAxisNormalizer.normalize(
                raw: 2_048,
                center: 2_048,
                negativeRange: 2_048,
                positiveRange: 2_047,
                deadzone: 100
            ),
            0
        )
        XCTAssertEqual(
            VirtualGamepadAxisNormalizer.normalize(
                raw: 2_148,
                center: 2_048,
                negativeRange: 2_048,
                positiveRange: 2_047,
                deadzone: 100
            ),
            0
        )
        XCTAssertEqual(
            VirtualGamepadAxisNormalizer.normalize(
                raw: 0,
                center: 2_048,
                negativeRange: 2_048,
                positiveRange: 2_047,
                deadzone: 100
            ),
            -32_767
        )
        XCTAssertEqual(
            VirtualGamepadAxisNormalizer.normalize(
                raw: 4_095,
                center: 2_048,
                negativeRange: 2_048,
                positiveRange: 2_047,
                deadzone: 100
            ),
            32_767
        )
    }

    func testAxisNormalizerHandlesAsymmetricRangesAndExactInversion() {
        let normal = VirtualGamepadAxisNormalizer.normalize(
            raw: 2_800,
            center: 2_000,
            negativeRange: 1_700,
            positiveRange: 2_000,
            deadzone: 100
        )
        let inverted = VirtualGamepadAxisNormalizer.normalize(
            raw: 2_800,
            center: 2_000,
            negativeRange: 1_700,
            positiveRange: 2_000,
            deadzone: 100,
            inverted: true
        )

        XCTAssertGreaterThan(normal, 0)
        XCTAssertEqual(inverted, -normal)
    }

    func testLinkedConfigurationRoundTripsAndPreservesOfflineSelections() throws {
        let suiteName = "VirtualGamepadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LinkedGamepadConfigurationStore(defaults: defaults)
        let configuration = LinkedGamepadConfiguration(
            isEnabled: true,
            left: LinkedJoyConSelection(controller: controller(
                id: "left-id",
                handedness: .left,
                variant: .standard
            )),
            right: LinkedJoyConSelection(controller: controller(
                id: "right-id",
                handedness: .right,
                variant: .joyCon2
            ))
        )

        store.save(configuration)

        XCTAssertEqual(store.load(), configuration)
        XCTAssertTrue(store.load().isComplete)
        XCTAssertEqual(store.load().side(for: "left-id"), .left)
        XCTAssertEqual(store.load().side(for: "right-id"), .right)
    }

    func testOutputCoordinatorPublishesNewestReportAndDeactivates() async throws {
        let sink = RecordingVirtualGamepadSink(sendDelay: .milliseconds(20))
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )

        coordinator.activate()
        let didActivate = await eventually { await sink.activationCount == 1 }
        XCTAssertTrue(didActivate)

        for sequence in 1...100 {
            coordinator.submit(
                VirtualGamepadHIDReport(state: VirtualGamepadState(
                    leftX: Int16(sequence)
                )),
                sequence: UInt64(sequence)
            )
        }

        let didPublishNewest = await eventually { await sink.lastLeftX == 100 }
        XCTAssertTrue(didPublishNewest)
        let deliveredAxes = await sink.deliveredLeftAxes()
        XCTAssertEqual(deliveredAxes, deliveredAxes.sorted())
        XCTAssertLessThan(deliveredAxes.count, 100)

        coordinator.deactivate()
        let didDeactivate = await eventually { await sink.deactivationCount == 1 }
        XCTAssertTrue(didDeactivate)
    }

    func testOutputCoordinatorPreservesDigitalTransitionsDuringBackpressure() async {
        let sink = RecordingVirtualGamepadSink(sendDelay: .milliseconds(80))
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )
        coordinator.activate()
        let activated = await eventually { await sink.activationCount == 1 }
        XCTAssertTrue(activated)

        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(leftX: 1)),
            sequence: 1
        )
        let firstSendStarted = await eventually { await sink.inFlightSendCount == 1 }
        XCTAssertTrue(firstSendStarted)
        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(
                buttons: [.button(.south)],
                leftX: 2
            )),
            sequence: 2
        )
        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(
                buttons: [.button(.south)],
                leftX: 3
            )),
            sequence: 3
        )
        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(leftX: 4)),
            sequence: 4
        )

        let releaseDelivered = await eventually(timeout: .seconds(3)) {
            await sink.lastLeftX == 4
        }
        XCTAssertTrue(releaseDelivered)
        let signatures = await sink.deliveredDigitalSignatures()
        XCTAssertTrue(
            signatures.contains(VirtualGamepadHIDReport(
                state: VirtualGamepadState(buttons: [.button(.south)])
            ).digitalSignature)
        )
        XCTAssertEqual(signatures.last, VirtualGamepadHIDReport(
            state: VirtualGamepadState()
        ).digitalSignature)
    }

    func testOutputCoordinatorDeliversRapidDigitalEdgesInSubmissionOrder() async {
        let sink = RecordingVirtualGamepadSink(sendDelay: .milliseconds(20))
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )
        coordinator.activate()
        let activated = await eventually { await sink.activationCount == 1 }
        XCTAssertTrue(activated)

        let expected = (1...12).map { sequence in
            VirtualGamepadHIDReport(state: VirtualGamepadState(
                buttons: sequence.isMultiple(of: 2) ? [] : [.button(.south)]
            ))
        }
        for (index, report) in expected.enumerated() {
            coordinator.submit(report, sequence: UInt64(index + 1))
        }

        let allDelivered = await eventually(timeout: .seconds(3)) {
            await sink.reports.count == expected.count
        }
        XCTAssertTrue(allDelivered)
        let deliveredSignatures = await sink.deliveredDigitalSignatures()
        XCTAssertEqual(
            deliveredSignatures,
            expected.map(\.digitalSignature)
        )
    }

    func testOldDrainCannotStartConcurrentWorkInANewerGeneration() async {
        let first = RecordingVirtualGamepadSink(sendDelay: .milliseconds(200))
        let second = RecordingVirtualGamepadSink(sendDelay: .milliseconds(400))
        let pool = VirtualGamepadSinkPool(sinks: [first, second])
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory {
                try await pool.make()
            }
        )

        coordinator.activate()
        let firstActivated = await eventually { await first.activationCount == 1 }
        XCTAssertTrue(firstActivated)
        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(leftX: 1)),
            sequence: 1
        )
        let firstGenerationStarted = await eventually {
            await first.inFlightSendCount == 1
        }
        XCTAssertTrue(firstGenerationStarted)

        coordinator.deactivate()
        coordinator.activate()
        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(leftX: 2)),
            sequence: 2
        )
        let secondGenerationStarted = await eventually {
            await second.inFlightSendCount == 1
        }
        XCTAssertTrue(secondGenerationStarted)

        try? await Task.sleep(for: .milliseconds(250))
        coordinator.submit(
            VirtualGamepadHIDReport(state: VirtualGamepadState(leftX: 3)),
            sequence: 3
        )
        try? await Task.sleep(for: .milliseconds(40))
        let maximumConcurrentSends = await second.maximumConcurrentSendCount
        XCTAssertEqual(maximumConcurrentSends, 1)
        let newestDelivered = await eventually(timeout: .seconds(3)) {
            await second.lastLeftX == 3
        }
        XCTAssertTrue(newestDelivered)
    }

    func testLinkedEnginePathConsumesAppMappingsAndNeutralizesOnUnmanage() async throws {
        let sink = RecordingVirtualGamepadSink()
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )
        let syntheticBackend = VirtualGamepadSyntheticEventBackend()
        let settings = SettingsStore()
        let engine = InputEngine(
            settings: settings,
            debugBuffer: DebugBuffer(),
            actionExecutor: ActionExecutor(eventBackend: syntheticBackend),
            virtualGamepadOutput: coordinator
        )
        let leftID = "linked-left"
        let rightID = "linked-right"

        engine.engineQueue.sync {
            engine.isRunning = true
            engine.joyConDevices[leftID] = InputEngine.JoyConDeviceState(
                id: leftID,
                profile: .joyConLeft
            )
            engine.joyConDevices[rightID] = InputEngine.JoyConDeviceState(
                id: rightID,
                profile: .joyConRight
            )
        }
        engine.setLinkedGamepadConfiguration(LinkedGamepadConfiguration(
            isEnabled: true,
            left: LinkedJoyConSelection(controller: controller(
                id: leftID,
                handedness: .left,
                variant: .standard
            )),
            right: LinkedJoyConSelection(controller: controller(
                id: rightID,
                handedness: .right,
                variant: .standard
            ))
        ))

        var leftBytes = neutralJoyConReport(isLeft: true)
        leftBytes[5] = 0x02 // D-pad up
        writePackedStick(
            x: 1_000,
            y: 3_000,
            to: &leftBytes,
            at: JoyConHIDProtocol.Offset.leftStickStart
        )
        var rightBytes = neutralJoyConReport(isLeft: false)
        rightBytes[3] = 0x08 // A
        writePackedStick(
            x: 3_000,
            y: 1_000,
            to: &rightBytes,
            at: JoyConHIDProtocol.Offset.rightStickStart
        )

        engine.engineQueue.sync {
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: leftID,
                bytes: leftBytes
            ))
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: rightID,
                bytes: rightBytes
            ))
        }

        let didPublish = await eventually {
            guard let report = await sink.lastReport else { return false }
            return report.bytes[3] == VirtualGamepadHat.north.rawValue
                && (UInt16(report.bytes[1]) | (UInt16(report.bytes[2]) << 8)) & (1 << 1) != 0
                && Int16(
                    bitPattern: UInt16(report.bytes[4]) | (UInt16(report.bytes[5]) << 8)
                ) < 0
        }
        XCTAssertTrue(didPublish)
        let lastReport = await sink.lastReport
        let report = try XCTUnwrap(lastReport)
        XCTAssertEqual(report.bytes[3], VirtualGamepadHat.north.rawValue)
        XCTAssertNotEqual(readUInt16(report.bytes, at: 1) & (1 << 1), 0)
        XCTAssertLessThan(readInt16(report.bytes, at: 4), 0)
        XCTAssertLessThan(readInt16(report.bytes, at: 6), 0)
        XCTAssertGreaterThan(readInt16(report.bytes, at: 8), 0)
        XCTAssertGreaterThan(readInt16(report.bytes, at: 10), 0)
        XCTAssertTrue(syntheticBackend.events.isEmpty)

        engine.setDeviceManaged(
            id: rightID,
            kind: .joyCon,
            isLeft: false,
            managed: false
        )
        let neutralBytes = VirtualGamepadHIDReport(state: VirtualGamepadState()).bytes
        let didNeutralize = await eventually { await sink.lastReport?.bytes == neutralBytes }
        XCTAssertTrue(didNeutralize)
        let deactivationCount = await sink.deactivationCount
        XCTAssertEqual(deactivationCount, 0)
        engine.stop()
    }

    func testLinkedEngineActivatesOnceAndNeutralizesASilentHalf() async throws {
        let sink = RecordingVirtualGamepadSink()
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )
        let engine = configuredLinkedEngine(coordinator: coordinator)
        let activated = await eventually { await sink.activationCount == 1 }
        XCTAssertTrue(activated)

        var left = neutralJoyConReport(isLeft: true)
        left[5] = 0x02
        writePackedStick(
            x: 1_000,
            y: 3_000,
            to: &left,
            at: JoyConHIDProtocol.Offset.leftStickStart
        )
        let right = neutralJoyConReport(isLeft: false)
        engine.engineQueue.sync {
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: "linked-left",
                bytes: left
            ))
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: "linked-right",
                bytes: right
            ))
        }

        let activeStateDelivered = await eventually {
            guard let report = await sink.lastReport else { return false }
            let leftX = Int16(
                bitPattern: UInt16(report.bytes[4]) | (UInt16(report.bytes[5]) << 8)
            )
            return report.bytes[3] == VirtualGamepadHat.north.rawValue
                && leftX != 0
        }
        XCTAssertTrue(activeStateDelivered)
        let neutralBytes = VirtualGamepadHIDReport(state: VirtualGamepadState()).bytes
        let neutralDelivered = await eventually(timeout: .seconds(2)) {
            await sink.lastReport?.bytes == neutralBytes
        }
        XCTAssertTrue(neutralDelivered)
        let activationCount = await sink.activationCount
        let deactivationCount = await sink.deactivationCount
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(deactivationCount, 0)
        engine.stop()
    }

    func testLinkedEngineKeepsInvalidCalibrationAxesNeutralButButtonsLive() async throws {
        let sink = RecordingVirtualGamepadSink()
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )
        let engine = configuredLinkedEngine(coordinator: coordinator)
        var left = neutralJoyConReport(isLeft: true)
        left[5] = 0x02
        writePackedStick(
            x: 1_000,
            y: 3_000,
            to: &left,
            at: JoyConHIDProtocol.Offset.leftStickStart
        )

        engine.engineQueue.sync {
            engine.joyConDevices["linked-left"]?.mapping.calibration.reset(
                requireNeutralValidation: true
            )
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: "linked-left",
                bytes: left
            ))
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: "linked-right",
                bytes: neutralJoyConReport(isLeft: false)
            ))
        }

        let invalidCalibrationStateDelivered = await eventually {
            guard let report = await sink.lastReport else { return false }
            let leftX = Int16(
                bitPattern: UInt16(report.bytes[4]) | (UInt16(report.bytes[5]) << 8)
            )
            let leftY = Int16(
                bitPattern: UInt16(report.bytes[6]) | (UInt16(report.bytes[7]) << 8)
            )
            return report.bytes[3] == VirtualGamepadHat.north.rawValue
                && leftX == 0
                && leftY == 0
        }
        XCTAssertTrue(invalidCalibrationStateDelivered)
        engine.stop()
    }

    func testPersistentActivationFailureIsLatchedUntilExplicitRetry() async {
        let attempts = VirtualGamepadActivationAttemptCounter()
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory {
                await attempts.increment()
                throw VirtualGamepadTestError.expectedFailure
            }
        )
        let engine = configuredLinkedEngine(coordinator: coordinator)
        let failedOnce = await eventually { await attempts.count == 1 }
        XCTAssertTrue(failedOnce)

        let left = neutralJoyConReport(isLeft: true)
        let right = neutralJoyConReport(isLeft: false)
        for _ in 0..<20 {
            engine.engineQueue.sync {
                engine.processJoyConReport(frame(
                    engine: engine,
                    deviceID: "linked-left",
                    bytes: left
                ))
                engine.processJoyConReport(frame(
                    engine: engine,
                    deviceID: "linked-right",
                    bytes: right
                ))
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 1)

        engine.retryLinkedGamepadOutput()
        let explicitRetryRan = await eventually { await attempts.count == 2 }
        XCTAssertTrue(explicitRetryRan)
        engine.stop()
    }

    func testChangingPairAfterActivationFailureRestartsOutput() async {
        let attempts = VirtualGamepadActivationAttemptCounter()
        let recoveredSink = RecordingVirtualGamepadSink()
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory {
                let attempt = await attempts.increment()
                if attempt == 1 {
                    throw VirtualGamepadTestError.expectedFailure
                }
                return recoveredSink
            }
        )
        let engine = configuredLinkedEngine(coordinator: coordinator)
        let failed = await eventually {
            engine.engineQueue.sync {
                if case .failed = engine.virtualGamepadRuntimeStatus {
                    return true
                }
                return false
            }
        }
        XCTAssertTrue(failed)

        var changedConfiguration = engine.engineQueue.sync {
            engine.linkedGamepadConfiguration
        }
        changedConfiguration.right = LinkedJoyConSelection(controller: controller(
            id: "replacement-right",
            handedness: .right,
            variant: .joyCon2
        ))
        engine.setLinkedGamepadConfiguration(changedConfiguration)

        let restarted = await eventually {
            await recoveredSink.activationCount == 1
        }
        XCTAssertTrue(restarted)
        let statusRecovered = await eventually {
            engine.engineQueue.sync {
                engine.virtualGamepadRuntimeStatus == .waitingForControllers
            }
        }
        XCTAssertTrue(statusRecovered)
        engine.stop()
    }

    func testSameConfigurationRestartsOutputAfterEngineStop() async {
        let first = RecordingVirtualGamepadSink()
        let second = RecordingVirtualGamepadSink()
        let pool = VirtualGamepadSinkPool(sinks: [first, second])
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory {
                try await pool.make()
            }
        )
        let engine = configuredLinkedEngine(coordinator: coordinator)
        let firstActivated = await eventually { await first.activationCount == 1 }
        XCTAssertTrue(firstActivated)
        let configuration = engine.engineQueue.sync {
            engine.linkedGamepadConfiguration
        }

        engine.stop()
        let firstDeactivated = await eventually { await first.deactivationCount == 1 }
        XCTAssertTrue(firstDeactivated)
        engine.engineQueue.sync {
            engine.isRunning = true
        }
        engine.setLinkedGamepadConfiguration(configuration)

        let secondActivated = await eventually { await second.activationCount == 1 }
        XCTAssertTrue(secondActivated)
        engine.stop()
    }

    func testEnablingLinkedModeReleasesExistingJamConOutputs() {
        let sink = RecordingVirtualGamepadSink()
        let coordinator = VirtualGamepadOutputCoordinator(
            factory: VirtualGamepadReportSinkFactory { sink }
        )
        let syntheticBackend = VirtualGamepadSyntheticEventBackend()
        let settings = SettingsStore()
        var mapping = JoyConButtonMappingProfile()
        mapping.setActions(
            ButtonActions(press: .mouseClick(.left)),
            for: .a
        )
        settings.update {
            $0.joyConButtonMappings[.joyConRight] = mapping
            $0.cursorControlEnabledByProfile[.joyConRight] = false
        }
        let engine = InputEngine(
            settings: settings,
            debugBuffer: DebugBuffer(),
            actionExecutor: ActionExecutor(eventBackend: syntheticBackend),
            virtualGamepadOutput: coordinator
        )
        let rightID = "transition-right"
        engine.engineQueue.sync {
            engine.isRunning = true
            engine.joyConDevices[rightID] = InputEngine.JoyConDeviceState(
                id: rightID,
                profile: .joyConRight
            )

            let neutral = neutralJoyConReport(isLeft: false)
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: rightID,
                bytes: neutral,
                motion: .single(zeroMotion)
            ))
            var pressed = neutral
            pressed[3] = 0x08 // A
            engine.processJoyConReport(frame(
                engine: engine,
                deviceID: rightID,
                bytes: pressed,
                motion: .single(zeroMotion)
            ))
        }
        XCTAssertEqual(syntheticBackend.events, [
            .mouseButton(.left, isPressed: true),
        ])

        engine.setLinkedGamepadConfiguration(LinkedGamepadConfiguration(
            isEnabled: true,
            left: LinkedJoyConSelection(controller: controller(
                id: "transition-left",
                handedness: .left,
                variant: .standard
            )),
            right: LinkedJoyConSelection(controller: controller(
                id: rightID,
                handedness: .right,
                variant: .standard
            ))
        ))

        XCTAssertEqual(syntheticBackend.events, [
            .mouseButton(.left, isPressed: true),
            .mouseButton(.left, isPressed: false),
        ])
        engine.stop()
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readInt16(_ bytes: [UInt8], at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(bytes, at: offset))
    }

    private func controller(
        id: String,
        handedness: ControllerHandedness,
        variant: ControllerProfileVariant
    ) -> ControllerInfo {
        ControllerInfo(
            id: id,
            name: "DeviceName",
            productID: 0,
            kind: .joyCon,
            handedness: handedness,
            profileVariant: variant
        )
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func neutralJoyConReport(isLeft: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: JoyConHIDProtocol.reportLength)
        bytes[0] = UInt8(JoyConHIDProtocol.inputReportID)
        writePackedStick(
            x: 2_048,
            y: 2_048,
            to: &bytes,
            at: isLeft
                ? JoyConHIDProtocol.Offset.leftStickStart
                : JoyConHIDProtocol.Offset.rightStickStart
        )
        return bytes
    }

    private func writePackedStick(
        x: Int,
        y: Int,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(x & 0xFF)
        bytes[offset + 1] = UInt8(((x >> 8) & 0x0F) | ((y & 0x0F) << 4))
        bytes[offset + 2] = UInt8((y >> 4) & 0xFF)
    }

    private func writePackedPair(
        _ pair: (UInt16, UInt16),
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: pair.0)
        bytes[offset + 1] = UInt8((pair.0 >> 8) & 0x0F)
            | UInt8((pair.1 & 0x0F) << 4)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: pair.1 >> 4)
    }

    private func configuredLinkedEngine(
        coordinator: VirtualGamepadOutputCoordinator
    ) -> InputEngine {
        let engine = InputEngine(
            settings: SettingsStore(),
            debugBuffer: DebugBuffer(),
            virtualGamepadOutput: coordinator
        )
        engine.engineQueue.sync {
            engine.isRunning = true
            engine.joyConDevices["linked-left"] = InputEngine.JoyConDeviceState(
                id: "linked-left",
                profile: .joyConLeft
            )
            engine.joyConDevices["linked-right"] = InputEngine.JoyConDeviceState(
                id: "linked-right",
                profile: .joyConRight
            )
        }
        engine.setLinkedGamepadConfiguration(LinkedGamepadConfiguration(
            isEnabled: true,
            left: LinkedJoyConSelection(controller: controller(
                id: "linked-left",
                handedness: .left,
                variant: .standard
            )),
            right: LinkedJoyConSelection(controller: controller(
                id: "linked-right",
                handedness: .right,
                variant: .standard
            ))
        ))
        return engine
    }

    private func frame(
        engine: InputEngine,
        deviceID: String,
        bytes: [UInt8],
        motion: InputDeviceMotionSamples = .none
    ) -> InputDeviceFrame {
        let timestamp = CACurrentMediaTime()
        return InputDeviceFrame(
            backend: engine.joyConController.backendDescriptor,
            deviceID: deviceID,
            reportID: JoyConHIDProtocol.inputReportID,
            bytes: bytes,
            motion: motion,
            timestamp: timestamp,
            receivedTimestamp: timestamp,
            inputTimestamp: nil,
            timestampSource: .hostReceipt,
            analogStickCalibration: InputDeviceAnalogStickCalibration(
                centerX: 2_048,
                centerY: 2_048,
                positiveRangeX: 2_047,
                positiveRangeY: 2_047,
                negativeRangeX: 2_048,
                negativeRangeY: 2_048
            )
        )
    }

    private var zeroMotion: IMUSample {
        IMUSample(
            accelX: 0,
            accelY: 0,
            accelZ: 0,
            gyroX: 0,
            gyroY: 0,
            gyroZ: 0
        )
    }
}

private actor RecordingVirtualGamepadSink: VirtualGamepadReportSink {
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0
    private(set) var reports: [VirtualGamepadHIDReport] = []
    private(set) var inFlightSendCount = 0
    private(set) var maximumConcurrentSendCount = 0
    let sendDelay: Duration

    init(sendDelay: Duration = .zero) {
        self.sendDelay = sendDelay
    }

    func activate() async throws {
        activationCount += 1
    }

    func send(_ report: VirtualGamepadHIDReport) async throws {
        inFlightSendCount += 1
        maximumConcurrentSendCount = max(maximumConcurrentSendCount, inFlightSendCount)
        defer { inFlightSendCount -= 1 }
        if sendDelay > .zero {
            try await Task.sleep(for: sendDelay)
        }
        reports.append(report)
    }

    func deactivate() async {
        deactivationCount += 1
    }

    var lastReport: VirtualGamepadHIDReport? {
        reports.last
    }

    var lastLeftX: Int16? {
        guard let bytes = reports.last?.bytes else { return nil }
        return Int16(bitPattern: UInt16(bytes[4]) | (UInt16(bytes[5]) << 8))
    }

    func deliveredLeftAxes() -> [Int16] {
        reports.map { report in
            Int16(bitPattern: UInt16(report.bytes[4]) | (UInt16(report.bytes[5]) << 8))
        }
    }

    func deliveredDigitalSignatures() -> [UInt64] {
        reports.map(\.digitalSignature)
    }
}

private actor VirtualGamepadSinkPool {
    private var sinks: [any VirtualGamepadReportSink]

    init(sinks: [any VirtualGamepadReportSink]) {
        self.sinks = sinks
    }

    func make() throws -> any VirtualGamepadReportSink {
        guard !sinks.isEmpty else {
            throw VirtualGamepadTestError.expectedFailure
        }
        return sinks.removeFirst()
    }
}

private actor VirtualGamepadActivationAttemptCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

private enum VirtualGamepadTestError: Error {
    case expectedFailure
}

private final class VirtualGamepadSyntheticEventBackend: SyntheticEventBackend {
    private(set) var events: [SyntheticOutputEvent] = []

    func post(_ event: SyntheticOutputEvent) {
        events.append(event)
    }
}
