import Foundation

struct IMUSample: Codable, Equatable, Sendable {
    let accelX: Int16
    let accelY: Int16
    let accelZ: Int16
    let gyroX: Int16
    let gyroY: Int16
    let gyroZ: Int16
}

enum HIDReportDecodeError: Error, Equatable {
    case reportTooShort(expectedAtLeast: Int, actual: Int)
}

struct SenseDecodedInputReport: Equatable, Sendable {
    let motion: IMUSample
}

enum SenseInputReportDecoder {
    static func decode(_ bytes: [UInt8]) throws -> SenseDecodedInputReport {
        guard bytes.count >= SenseHIDProtocol.minimumReportLength else {
            throw HIDReportDecodeError.reportTooShort(
                expectedAtLeast: SenseHIDProtocol.minimumReportLength,
                actual: bytes.count
            )
        }

        return SenseDecodedInputReport(
            motion: IMUSample(
                accelX: readInt16LE(bytes, at: SenseHIDProtocol.Offset.accelXLow),
                accelY: readInt16LE(bytes, at: SenseHIDProtocol.Offset.accelYLow),
                accelZ: readInt16LE(bytes, at: SenseHIDProtocol.Offset.accelZLow),
                gyroX: readInt16LE(bytes, at: SenseHIDProtocol.Offset.gyroXLow),
                gyroY: readInt16LE(bytes, at: SenseHIDProtocol.Offset.gyroYLow),
                gyroZ: readInt16LE(bytes, at: SenseHIDProtocol.Offset.gyroZLow)
            )
        )
    }
}

struct JoyConDecodedInputReport: Equatable, Sendable {
    let motionSamples: [IMUSample]

    var latest: IMUSample { motionSamples[motionSamples.count - 1] }

    var averagedGyro: (x: Int16, y: Int16, z: Int16) {
        guard !motionSamples.isEmpty else { return (0, 0, 0) }
        let count = Int32(motionSamples.count)
        let sums = motionSamples.reduce(into: (x: Int32(0), y: Int32(0), z: Int32(0))) { result, sample in
            result.x += Int32(sample.gyroX)
            result.y += Int32(sample.gyroY)
            result.z += Int32(sample.gyroZ)
        }
        return (
            x: Int16(sums.x / count),
            y: Int16(sums.y / count),
            z: Int16(sums.z / count)
        )
    }
}

enum JoyConInputReportDecoder {
    static let minimumReportLength = JoyConHIDProtocol.Offset.imuSample2 + 12

    static func decode(_ bytes: [UInt8]) throws -> JoyConDecodedInputReport {
        guard bytes.count >= minimumReportLength else {
            throw HIDReportDecodeError.reportTooShort(
                expectedAtLeast: minimumReportLength,
                actual: bytes.count
            )
        }

        let bases = [
            JoyConHIDProtocol.Offset.imuSample0,
            JoyConHIDProtocol.Offset.imuSample1,
            JoyConHIDProtocol.Offset.imuSample2,
        ]

        return JoyConDecodedInputReport(
            motionSamples: bases.map { base in
                IMUSample(
                    accelX: readInt16LE(bytes, at: base),
                    accelY: readInt16LE(bytes, at: base + 2),
                    accelZ: readInt16LE(bytes, at: base + 4),
                    gyroX: readInt16LE(bytes, at: base + 6),
                    gyroY: readInt16LE(bytes, at: base + 8),
                    gyroZ: readInt16LE(bytes, at: base + 10)
                )
            }
        )
    }
}

private func readInt16LE(_ bytes: [UInt8], at offset: Int) -> Int16 {
    Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
}
