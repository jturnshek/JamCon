import Foundation

/// Joy-Con HID protocol constants (Bluetooth)
enum JoyConHIDProtocol {
    // Device identification
    static let nintendoVendorID: Int = 0x057E
    static let leftProductID: Int = 0x2006
    static let rightProductID: Int = 0x2007

    // Input report
    static let inputReportID: UInt32 = 0x30
    static let subcommandReplyReportID: UInt32 = 0x21
    static let spiReadSubcommand: UInt8 = 0x10
    static let factoryStickCalibrationLength: UInt8 = 9
    static let leftFactoryStickCalibrationAddress: UInt32 = 0x0000_603D
    static let rightFactoryStickCalibrationAddress: UInt32 = 0x0000_6046

    /// A fixed, deliberately conservative range used immediately if the
    /// controller has not answered the factory-memory request yet. Unlike the
    /// old live-extrema learning, this never turns the user's newest position
    /// into a moving full-scale endpoint.
    static let conservativeStickCalibration = InputDeviceAnalogStickCalibration(
        centerX: 2_048,
        centerY: 2_048,
        positiveRangeX: 1_600,
        positiveRangeY: 1_600,
        negativeRangeX: 1_600,
        negativeRangeY: 1_600
    )

    /// Original Joy-Con reports only four documented charge bands, not an
    /// exact state of charge. Representative percentages keep the existing UI
    /// useful while `isEstimated` makes that limitation explicit.
    static func batteryState(from bytes: [UInt8]) -> InputDeviceBatteryState? {
        guard bytes.indices.contains(Offset.battery) else { return nil }
        let level = (bytes[Offset.battery] >> 4) & 0x0F
        let percentage: Int
        switch level {
        case 0x08:
            percentage = 100
        case 0x06:
            percentage = 60
        case 0x04:
            percentage = 30
        case 0x02:
            percentage = 10
        default:
            return nil
        }
        return InputDeviceBatteryState(
            percentage: percentage,
            isEstimated: true
        )
    }

    // MARK: - IMU Constants

    /// Gyroscope scale factor (raw units to degrees/second)
    /// Joy-Con: 0.06103 °/s per LSB (from JoyConSwift library)
    /// Nearly identical to Sense's 0.0625 (1/16)
    static let defaultGyroScale: Double = 0.06103

    /// Accelerometer scale factor (units per g)
    static let accelerometerScale: Double = 4096.0
    /// Standard full input reports are 49 bytes over Bluetooth. Some stacks may deliver a byte more; we cap at this length.
    static let reportLength: Int = 49

    /// Offsets into the latest IMU sample (report contains 3 samples; newest is the last block)
    /// NOTE: Report ID (0x30) is included at byte 0, so all offsets are +1 from documentation
    enum Offset {
        // Header / metadata (byte 0 = report ID 0x30)
        static let reportID: Int = 0
        static let timer: Int = 1      // Packet counter
        static let battery: Int = 2    // Upper nibble encodes battery level; lower nibble connection flags

        // Buttons (layout differs by side; these are raw bytes)
        static let buttonByteRight1: Int = 3
        static let buttonByteRight2: Int = 4
        static let buttonByteLeft1: Int = 4
        static let buttonByteLeft2: Int = 5

        // Sticks
        static let leftStickStart: Int = 6   // 3 bytes packed
        static let rightStickStart: Int = 9  // 3 bytes packed

        // IMU samples (12 bytes each: accel XYZ int16 LE, then gyro XYZ int16 LE)
        // Byte 13 is where IMU data starts (after report ID + header + buttons + sticks)
        static let imuSample0: Int = 13
        static let imuSample1: Int = imuSample0 + 12
        static let imuSample2: Int = imuSample1 + 12

        // Use the latest (third) sample for live display / processing
        static let latestSample: Int = imuSample2
        static let accelXLow: Int = latestSample + 0
        static let accelXHigh: Int = latestSample + 1
        static let accelYLow: Int = latestSample + 2
        static let accelYHigh: Int = latestSample + 3
        static let accelZLow: Int = latestSample + 4
        static let accelZHigh: Int = latestSample + 5

        static let gyroXLow: Int = latestSample + 6
        static let gyroXHigh: Int = latestSample + 7
        static let gyroYLow: Int = latestSample + 8
        static let gyroYHigh: Int = latestSample + 9
        static let gyroZLow: Int = latestSample + 10
        static let gyroZHigh: Int = latestSample + 11
    }

    static func factoryStickCalibrationAddress(isLeft: Bool) -> UInt32 {
        isLeft ? leftFactoryStickCalibrationAddress : rightFactoryStickCalibrationAddress
    }

    static func factoryStickCalibrationReadPayload(isLeft: Bool) -> [UInt8] {
        let address = factoryStickCalibrationAddress(isLeft: isLeft)
        return [
            UInt8(address & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 24) & 0xFF),
            factoryStickCalibrationLength,
        ]
    }

    /// Decodes the 0x21 reply to subcommand 0x10. Nintendo stores the same
    /// packed values in different orders for left and right Joy-Cons.
    static func decodeFactoryStickCalibrationReply(
        _ bytes: [UInt8],
        isLeft: Bool
    ) -> InputDeviceAnalogStickCalibration? {
        let dataOffset = 20
        guard bytes.count >= dataOffset + Int(factoryStickCalibrationLength),
              UInt32(bytes[0]) == subcommandReplyReportID,
              bytes[13] & 0x80 != 0,
              bytes[14] == spiReadSubcommand,
              uint32LE(bytes, at: 15) == factoryStickCalibrationAddress(isLeft: isLeft),
              bytes[19] >= factoryStickCalibrationLength else {
            return nil
        }

        let data = Array(bytes[dataOffset..<(dataOffset + Int(factoryStickCalibrationLength))])
        func unpack(_ offset: Int) -> (UInt16, UInt16) {
            let byte0 = UInt16(data[offset])
            let byte1 = UInt16(data[offset + 1])
            let byte2 = UInt16(data[offset + 2])
            return (
                byte0 | ((byte1 & 0x0F) << 8),
                (byte1 >> 4) | (byte2 << 4)
            )
        }

        let center: (UInt16, UInt16)
        let positive: (UInt16, UInt16)
        let negative: (UInt16, UInt16)
        if isLeft {
            positive = unpack(0)
            center = unpack(3)
            negative = unpack(6)
        } else {
            center = unpack(0)
            negative = unpack(3)
            positive = unpack(6)
        }

        let calibration = InputDeviceAnalogStickCalibration(
            centerX: center.0,
            centerY: center.1,
            positiveRangeX: positive.0,
            positiveRangeY: positive.1,
            negativeRangeX: negative.0,
            negativeRangeY: negative.1
        )
        return isPlausible(calibration) ? calibration : nil
    }

    private static func uint32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func isPlausible(
        _ calibration: InputDeviceAnalogStickCalibration
    ) -> Bool {
        let centers = [calibration.centerX, calibration.centerY]
        let ranges = [
            calibration.positiveRangeX,
            calibration.positiveRangeY,
            calibration.negativeRangeX,
            calibration.negativeRangeY,
        ]
        guard centers.allSatisfy({ $0 > 0 && $0 < 4_095 }),
              ranges.allSatisfy({ $0 >= 200 && $0 <= 4_095 }) else {
            return false
        }
        return Int(calibration.centerX) + Int(calibration.positiveRangeX) <= 4_095
            && Int(calibration.centerY) + Int(calibration.positiveRangeY) <= 4_095
            && Int(calibration.centerX) - Int(calibration.negativeRangeX) >= 0
            && Int(calibration.centerY) - Int(calibration.negativeRangeY) >= 0
    }

    // MARK: - Button Mappings

    /// Button locations for Right Joy-Con (product ID 0x2007)
    /// Byte offsets include the report ID at byte 0
    enum RightButton {
        // Byte 3: Face and shoulder buttons
        static let y = (byte: 3, bit: 0)       // 0x01
        static let x = (byte: 3, bit: 1)       // 0x02
        static let b = (byte: 3, bit: 2)       // 0x04
        static let a = (byte: 3, bit: 3)       // 0x08
        static let sr = (byte: 3, bit: 4)      // 0x10 (side rail)
        static let sl = (byte: 3, bit: 5)      // 0x20 (side rail)
        static let r = (byte: 3, bit: 6)       // 0x40
        static let zr = (byte: 3, bit: 7)      // 0x80

        // Byte 4: System buttons
        static let minus = (byte: 4, bit: 0)   // 0x01 (only in grip mode)
        static let plus = (byte: 4, bit: 1)    // 0x02
        static let rStick = (byte: 4, bit: 2)  // 0x04 (stick click)
        static let lStick = (byte: 4, bit: 3)  // 0x08 (only in grip mode)
        static let home = (byte: 4, bit: 4)    // 0x10
        static let capture = (byte: 4, bit: 5) // 0x20 (only in grip mode)
    }

    /// Button locations for Left Joy-Con (product ID 0x2006)
    /// Byte offsets include the report ID at byte 0
    enum LeftButton {
        // Byte 4: System buttons
        static let minus = (byte: 4, bit: 0)   // 0x01
        static let capture = (byte: 4, bit: 5) // 0x20

        // Byte 5: D-pad, shoulder, and side rail buttons
        static let down = (byte: 5, bit: 0)    // 0x01
        static let up = (byte: 5, bit: 1)      // 0x02
        static let right = (byte: 5, bit: 2)   // 0x04
        static let left = (byte: 5, bit: 3)    // 0x08
        static let sr = (byte: 5, bit: 4)      // 0x10 (side rail)
        static let sl = (byte: 5, bit: 5)      // 0x20 (side rail)
        static let l = (byte: 5, bit: 6)       // 0x40
        static let zl = (byte: 5, bit: 7)      // 0x80

        // Stick click
        static let lStick = (byte: 4, bit: 3)  // 0x08

        // Grip mode only (not available in standalone mode)
        static let plus = (byte: 4, bit: 1)    // 0x02
        static let home = (byte: 4, bit: 4)    // 0x10
        static let rStick = (byte: 4, bit: 2)  // 0x04
    }
}
