import Foundation
import os

/// Thread-safe ring buffer for debug/visualization data
/// Engine writes samples, UI polls when needed
/// This is the ONE-WAY bridge: Engine → UI (debug data flows up via polling)
final class DebugBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()

    // MARK: - Types

    /// A single debug sample from the controller with all pipeline stages
    struct Sample {
        let timestamp: Date
        let reportBytes: [UInt8]
        let reportLength: Int

        // Pipeline Stage 1: Raw (direct from HID)
        let rawGyro: (x: Int16, y: Int16, z: Int16)

        // Pipeline Stage 2: Remapped (semantic axes)
        let remappedGyro: (pitch: Int16, yaw: Int16, roll: Int16)

        // Pipeline Stage 3: Normalized (degrees per second)
        let normalizedGyro: (pitch: Double, yaw: Double, roll: Double)

        let accel: (x: Int16, y: Int16, z: Int16)
        let buttonStates: [Bool]
        let controllerKind: ControllerKind
        let gyroDebug: GyroDebug?

        // Backwards compatibility alias
        var gyro: (x: Int16, y: Int16, z: Int16) { rawGyro }

        static let empty = Sample(
            timestamp: .distantPast,
            reportBytes: [],
            reportLength: 0,
            rawGyro: (0, 0, 0),
            remappedGyro: (0, 0, 0),
            normalizedGyro: (0, 0, 0),
            accel: (0, 0, 0),
            buttonStates: [],
            controllerKind: .psvr2,
            gyroDebug: nil
        )
    }

    struct GyroDebug {
        let biasX: Double
        let biasY: Double
        let biasZ: Double
        let calibrated: Bool
        let observedSampleRate: Double
        let lastNeutralUpdate: TimeInterval?
    }

    /// Aggregated statistics for display
    struct Stats {
        var reportCount: Int = 0
        var lastReportTime: Date = .distantPast
        var reportsPerSecond: Double = 0
    }

    // MARK: - State

    /// Ring buffer of samples
    private var samples: [Sample]
    private var writeIndex: Int = 0
    private let capacity: Int

    /// Byte change tracking for visualization
    private var byteLastChanged: [Date]
    private var bitLastChanged: [[Date]]
    private var previousBytes: [UInt8]

    /// Statistics
    private var _stats = Stats()
    private var reportTimestamps: [Date] = []

    /// Whether recording is enabled (UI can disable to save CPU)
    private var _isRecording: Bool = false

    // MARK: - Initialization

    init(capacity: Int = 120, maxReportLength: Int = 64) {
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)

        self.byteLastChanged = Array(repeating: .distantPast, count: maxReportLength)
        self.bitLastChanged = Array(repeating: Array(repeating: .distantPast, count: 8), count: maxReportLength)
        self.previousBytes = Array(repeating: 0, count: maxReportLength)
    }

    // MARK: - Recording Control

    var isRecording: Bool {
        get { lock.withLock { _isRecording } }
        set { lock.withLock { _isRecording = newValue } }
    }

    func startRecording() {
        lock.withLock {
            _isRecording = true
        }
    }

    func stopRecording() {
        lock.withLock {
            _isRecording = false
        }
    }

    // MARK: - Writing (Called from HID thread)

    /// Record a new sample with all pipeline stages - fast, non-blocking write
    func record(
        bytes: [UInt8],
        length: Int,
        rawGyro: (x: Int16, y: Int16, z: Int16),
        remappedGyro: (pitch: Int16, yaw: Int16, roll: Int16),
        normalizedGyro: (pitch: Double, yaw: Double, roll: Double),
        accel: (x: Int16, y: Int16, z: Int16),
        buttonStates: [Bool],
        controllerKind: ControllerKind,
        gyroDebug: GyroDebug? = nil
    ) {
        let now = Date()

        lock.withLock {
            guard _isRecording else { return }

            // Track byte/bit changes
            let maxIndex = min(length, previousBytes.count)
            for i in 0..<maxIndex {
                if bytes[i] != previousBytes[i] {
                    byteLastChanged[i] = now

                    // Track individual bit changes
                    let changedBits = bytes[i] ^ previousBytes[i]
                    for bit in 0..<8 where (changedBits >> bit) & 1 == 1 {
                        bitLastChanged[i][bit] = now
                    }
                    previousBytes[i] = bytes[i]
                }
            }

            // Create sample with all pipeline stages
            let sample = Sample(
                timestamp: now,
                reportBytes: Array(bytes.prefix(maxIndex)),
                reportLength: length,
                rawGyro: rawGyro,
                remappedGyro: remappedGyro,
                normalizedGyro: normalizedGyro,
                accel: accel,
                buttonStates: buttonStates,
                controllerKind: controllerKind,
                gyroDebug: gyroDebug
            )

            // Write to ring buffer
            if samples.count < capacity {
                samples.append(sample)
            } else {
                samples[writeIndex] = sample
            }
            writeIndex = (writeIndex + 1) % capacity

            // Update statistics
            _stats.reportCount += 1
            _stats.lastReportTime = now

            // Track reports per second (rolling window)
            reportTimestamps.append(now)
            let cutoff = now.addingTimeInterval(-1.0)
            reportTimestamps.removeAll { $0 < cutoff }
            _stats.reportsPerSecond = Double(reportTimestamps.count)
        }
    }

    // MARK: - Reading (Called from main thread)

    /// Get the most recent sample
    func latest() -> Sample? {
        lock.withLock {
            guard !samples.isEmpty else { return nil }
            let index = (writeIndex - 1 + samples.count) % samples.count
            return samples[index]
        }
    }

    /// Get the latest gyro debug snapshot (if available)
    func latestGyroDebug() -> GyroDebug? {
        lock.withLock {
            guard !samples.isEmpty else { return nil }
            let index = (writeIndex - 1 + samples.count) % samples.count
            return samples[index].gyroDebug
        }
    }

    /// Get all recent samples (for visualization)
    func recentSamples() -> [Sample] {
        lock.withLock {
            // Return samples in chronological order
            guard !samples.isEmpty else { return [] }

            if samples.count < capacity {
                return samples
            }

            // Ring buffer is full - reconstruct order
            var result: [Sample] = []
            result.reserveCapacity(capacity)
            for i in 0..<capacity {
                let index = (writeIndex + i) % capacity
                result.append(samples[index])
            }
            return result
        }
    }

    /// Get current statistics
    func stats() -> Stats {
        lock.withLock { _stats }
    }

    /// Get byte change timestamps (for heat map visualization)
    func getByteLastChanged() -> [Date] {
        lock.withLock { byteLastChanged }
    }

    /// Get bit change timestamps (for detailed visualization)
    func getBitLastChanged() -> [[Date]] {
        lock.withLock { bitLastChanged }
    }

    /// Get current report bytes (for byte inspector)
    func getCurrentBytes() -> [UInt8] {
        lock.withLock { previousBytes }
    }

    // MARK: - Log Messages

    private var logMessages: [String] = []
    private let logCapacity: Int = 500

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Add a log message (thread-safe, called from any thread)
    func log(_ message: String) {
        let timestamped = "[\(Self.timeFormatter.string(from: Date()))] \(message)"
        lock.withLock {
            logMessages.append(timestamped)
            if logMessages.count > logCapacity {
                logMessages.removeFirst(logMessages.count - logCapacity)
            }
        }
    }

    /// Get all log messages (thread-safe, called from main thread)
    func getLogMessages() -> [String] {
        lock.withLock { logMessages }
    }

    /// Clear all log messages
    func clearLog() {
        lock.withLock { logMessages.removeAll() }
    }

    // MARK: - Utility

    /// Clear all recorded data
    func clear() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            writeIndex = 0
            _stats = Stats()
            reportTimestamps.removeAll()
            byteLastChanged = Array(repeating: .distantPast, count: byteLastChanged.count)
            bitLastChanged = Array(repeating: Array(repeating: .distantPast, count: 8), count: bitLastChanged.count)
            previousBytes = Array(repeating: 0, count: previousBytes.count)
        }
    }
}
