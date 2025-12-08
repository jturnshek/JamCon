import Foundation

/// Joy-Con HID protocol constants (Bluetooth)
enum JoyConHIDProtocol {
    // Device identification
    static let nintendoVendorID: Int = 0x057E
    static let leftProductID: Int = 0x2006
    static let rightProductID: Int = 0x2007

    // Input report
    static let inputReportID: UInt32 = 0x30

    // MARK: - IMU Constants

    /// Gyroscope scale factor (raw units to degrees/second)
    /// Joy-Con: 0.06103 °/s per LSB (from JoyConSwift library)
    /// Nearly identical to PSVR2's 0.0625 (1/16)
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
}
