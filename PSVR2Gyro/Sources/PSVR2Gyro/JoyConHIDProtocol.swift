import Foundation

/// Joy-Con HID protocol constants (Bluetooth)
enum JoyConHIDProtocol {
    // Device identification
    static let nintendoVendorID: Int = 0x057E
    static let leftProductID: Int = 0x2006
    static let rightProductID: Int = 0x2007

    // Input report
    static let inputReportID: UInt32 = 0x30
    /// Standard full input reports are 49 bytes over Bluetooth. Some stacks may deliver a byte more; we cap at this length.
    static let reportLength: Int = 49

    /// Offsets into the latest IMU sample (report contains 3 samples; newest is the last block)
    enum Offset {
        // Header / metadata
        static let battery: Int = 2   // Upper nibble encodes battery level; lower nibble connection flags

        // Buttons (layout differs by side; these are raw bytes)
        static let buttonByteRight1: Int = 2
        static let buttonByteRight2: Int = 3
        static let buttonByteLeft1: Int = 3
        static let buttonByteLeft2: Int = 4

        // Sticks
        static let leftStickStart: Int = 5   // 3 bytes packed
        static let rightStickStart: Int = 8  // 3 bytes packed

        // IMU samples (12 bytes each: accel XYZ int16 LE, then gyro XYZ int16 LE)
        static let imuSample0: Int = 12
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
