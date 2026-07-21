import XCTest
@testable import JamCon

final class InputHealthAggregatorTests: XCTestCase {
    func testEmitsOneAggregateAfterInterval() throws {
        let device = ManagedDeviceKey(kind: .joyCon, id: "right")
        var aggregator = InputHealthAggregator(interval: 5)

        XCTAssertNil(aggregator.record(
            device: device,
            inputTimestamp: 9.97,
            timestampSource: .hostReceipt,
            receivedTimestamp: 9.98,
            engineStartTimestamp: 9.99,
            engineEndTimestamp: 10
        ))

        let summary = try XCTUnwrap(aggregator.record(
            device: device,
            inputTimestamp: 15.06,
            timestampSource: .hostReceipt,
            receivedTimestamp: 15.07,
            engineStartTimestamp: 15.08,
            engineEndTimestamp: 15.1
        ))

        XCTAssertEqual(summary.reportCount, 2)
        XCTAssertEqual(summary.duration, 5.1, accuracy: 0.0001)
        XCTAssertEqual(summary.reportRate, 2 / 5.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageInputAgeMilliseconds), 35, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.maximumInputAgeMilliseconds), 40, accuracy: 0.0001)
        XCTAssertEqual(summary.inputAgeSampleCount, 2)
        XCTAssertEqual(summary.averageQueueDelayMilliseconds, 10, accuracy: 0.0001)
        XCTAssertEqual(summary.averageProcessingMilliseconds, 15, accuracy: 0.0001)
        XCTAssertEqual(summary.maximumProcessingMilliseconds, 20, accuracy: 0.0001)
        XCTAssertTrue(summary.logMessage.contains("reports=2"))
    }

    func testFlushReturnsPartialWindowsAndResetsState() {
        let device = ManagedDeviceKey(kind: .sense, id: "left")
        var aggregator = InputHealthAggregator(interval: 5)
        _ = aggregator.record(
            device: device,
            inputTimestamp: nil,
            timestampSource: .hostReceipt,
            receivedTimestamp: 1,
            engineStartTimestamp: 1,
            engineEndTimestamp: 1.001
        )

        XCTAssertEqual(aggregator.flush(at: 2).map(\.reportCount), [1])
        XCTAssertTrue(aggregator.flush(at: 3).isEmpty)
    }

    func testDoesNotInventInputAgeFromReceiptTimestamp() throws {
        let device = ManagedDeviceKey(kind: .joyCon, id: "right")
        var aggregator = InputHealthAggregator(interval: 0.1)

        _ = aggregator.record(
            device: device,
            inputTimestamp: nil,
            timestampSource: .hostReceipt,
            receivedTimestamp: 1,
            engineStartTimestamp: 1.001,
            engineEndTimestamp: 1.002
        )
        let summary = try XCTUnwrap(aggregator.flush(at: 1.1).first)

        XCTAssertNil(summary.averageInputAgeMilliseconds)
        XCTAssertNil(summary.maximumInputAgeMilliseconds)
        XCTAssertEqual(summary.inputAgeSampleCount, 0)
        XCTAssertEqual(summary.timestampSourceCounts[.hostReceipt], 1)
        XCTAssertTrue(summary.logMessage.contains("inputAge=n/a"))
    }
}

final class GyroResponseAggregatorTests: XCTestCase {
    func testEmitsBoundedResponseAggregateAfterInterval() throws {
        let device = ManagedDeviceKey(kind: .joyCon, id: "right")
        var aggregator = GyroResponseAggregator(interval: 5)

        XCTAssertNil(aggregator.record(
            device: device,
            timestamp: 10,
            sample: sample(
                deltaTime: 0.015,
                rawSpeed: 10,
                filteredSpeed: 8,
                accelerationSpeed: 6,
                accelerationGain: 2,
                computedCursorSpeed: 80,
                biasX: 1,
                filterEnabled: true,
                didAutoNeutralUpdate: false
            )
        ))

        let summary = try XCTUnwrap(aggregator.record(
            device: device,
            timestamp: 15.1,
            sample: sample(
                deltaTime: 0.025,
                rawSpeed: 20,
                filteredSpeed: 18,
                accelerationSpeed: 12,
                accelerationGain: 4,
                computedCursorSpeed: 180,
                biasX: 4,
                filterEnabled: false,
                didAutoNeutralUpdate: true
            )
        ))

        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(summary.activeSampleCount, 2)
        XCTAssertEqual(summary.filterEnabledSampleCount, 1)
        XCTAssertEqual(summary.filterDisabledSampleCount, 1)
        XCTAssertEqual(summary.averageDeltaTimeMilliseconds, 20, accuracy: 0.0001)
        XCTAssertEqual(summary.maximumDeltaTimeMilliseconds, 25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageRawSpeed), 15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageFilteredSpeed), 13, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageAccelerationSpeed), 9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageAccelerationGain), 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageComputedCursorSpeed), 130, accuracy: 0.0001)
        XCTAssertEqual(summary.endingBiasMagnitude, 4, accuracy: 0.0001)
        XCTAssertEqual(summary.biasChangeMagnitude, 3, accuracy: 0.0001)
        XCTAssertEqual(summary.autoNeutralUpdateCount, 1)
        XCTAssertTrue(summary.logMessage.contains("filter.on=1 filter.off=1"))
        XCTAssertTrue(summary.logMessage.contains("autoNeutralUpdates=1"))
    }

    func testInactiveWindowDoesNotInventMotionStatistics() throws {
        let device = ManagedDeviceKey(kind: .sense, id: "sense")
        var aggregator = GyroResponseAggregator(interval: 5)

        _ = aggregator.record(
            device: device,
            timestamp: 1,
            sample: sample(rawSpeed: 0.5)
        )
        let summary = try XCTUnwrap(aggregator.flush(at: 2).first)

        XCTAssertEqual(summary.activeSampleCount, 0)
        XCTAssertNil(summary.averageRawSpeed)
        XCTAssertNil(summary.averageComputedCursorSpeed)
        XCTAssertTrue(summary.logMessage.contains("motion=n/a"))
        XCTAssertTrue(aggregator.flush(at: 3).isEmpty)
    }

    private func sample(
        deltaTime: TimeInterval = 1.0 / 60.0,
        rawSpeed: Double = 10,
        filteredSpeed: Double = 10,
        accelerationSpeed: Double = 10,
        accelerationGain: Double = 1,
        computedCursorSpeed: Double = 10,
        biasX: Double = 0,
        filterEnabled: Bool = false,
        didAutoNeutralUpdate: Bool = false
    ) -> GyroResponseSample {
        GyroResponseSample(
            deltaTime: deltaTime,
            rawSpeed: rawSpeed,
            filteredSpeed: filteredSpeed,
            accelerationSpeed: accelerationSpeed,
            accelerationGain: accelerationGain,
            computedCursorSpeed: computedCursorSpeed,
            biasX: biasX,
            biasY: 0,
            biasZ: 0,
            filterEnabled: filterEnabled,
            didAutoNeutralUpdate: didAutoNeutralUpdate
        )
    }
}
