import Foundation

/// PlayStation Sense Controller HID Protocol Constants
/// See docs/Sense-HID-Protocol.md for full documentation
enum SenseHIDProtocol {

    // MARK: - Device Identification

    /// Sony vendor ID
    static let sonyVendorID: Int = 0x054C

    /// Left controller product ID
    static let leftProductID: Int = 0x0E45

    /// Right controller product ID
    static let rightProductID: Int = 0x0E46

    /// Main input report ID
    static let inputReportID: UInt32 = 0x31

    /// Expected report length in bytes
    static let reportLength: Int = 78

    /// Minimum valid report length (includes IMU data)
    static let minimumReportLength: Int = 40

    // MARK: - Report Byte Offsets

    enum Offset {
        // Joystick
        static let joystickX: Int = 2
        static let joystickY: Int = 3

        // Trigger and touch sensors
        static let triggerAnalog: Int = 4
        static let triggerProximity: Int = 5
        static let gripCapacitive: Int = 6

        // Button bytes
        static let faceButtons: Int = 9
        static let systemButtons: Int = 10
        static let touchStates: Int = 11

        // Connection timers (reset on reconnect)
        static let connectionTimer1: Int = 14
        static let connectionTimer2: Int = 32
        static let connectionTimer3: Int = 52

        // Gyroscope (signed Int16 LE pairs)
        static let gyroXLow: Int = 17
        static let gyroXHigh: Int = 18
        static let gyroYLow: Int = 19
        static let gyroYHigh: Int = 20
        static let gyroZLow: Int = 21
        static let gyroZHigh: Int = 22

        // Accelerometer (signed Int16 LE pairs, ~4096/g)
        static let accelXLow: Int = 23
        static let accelXHigh: Int = 24
        static let accelYLow: Int = 25
        static let accelYHigh: Int = 26
        static let accelZLow: Int = 27
        static let accelZHigh: Int = 28

        // Battery
        static let battery: Int = 43

        // Possible CRC32 (unconfirmed)
        static let crc32Start: Int = 74
    }

    // MARK: - Button Bit Masks (Byte 9 - Face Buttons)

    enum FaceButtonMask {
        // Right controller
        static let xButton: UInt8 = 0x02      // Bit 1
        static let circleButton: UInt8 = 0x04 // Bit 2
        static let rightGrip: UInt8 = 0x20    // Bit 5 (R1)

        // Left controller
        static let squareButton: UInt8 = 0x01   // Bit 0
        static let triangleButton: UInt8 = 0x08 // Bit 3
        static let leftGrip: UInt8 = 0x10       // Bit 4 (L1)
    }

    // MARK: - System Button Bit Masks (Byte 10)

    enum SystemButtonMask {
        // Right controller
        static let optionsButton: UInt8 = 0x02      // Bit 1
        static let rightStickClick: UInt8 = 0x08    // Bit 3 (R3)

        // Left controller
        static let createButton: UInt8 = 0x01       // Bit 0
        static let leftStickClick: UInt8 = 0x04     // Bit 2 (L3)

        // Both controllers
        static let playStationButton: UInt8 = 0x10  // Bit 4
    }

    // MARK: - Touch State Bit Masks (Byte 11)

    enum TouchStateMask {
        static let joystickTouch: UInt8 = 0x04  // Bit 2
        static let gripTouch: UInt8 = 0x08      // Bit 3
    }

    // MARK: - Battery

    /// Mask for extracting battery level from battery byte
    static let batteryLevelMask: UInt8 = 0x0F

    /// Convert raw battery byte to percentage (0-100)
    static func batteryPercentage(from rawByte: UInt8) -> Int {
        Int(rawByte & batteryLevelMask) * 10
    }

    // MARK: - IMU Constants

    /// Accelerometer scale factor (units per g)
    static let accelerometerScale: Double = 4096.0

    /// Default gyro scale factor (raw units to degrees/second)
    static let defaultGyroScale: Double = 1.0 / 16.0

    // MARK: - Output Report Constants (Experimental - may not work over Bluetooth)

    enum OutputReport {
        static let reportID: UInt8 = 0x31
        static let length: Int = 78

        // Bluetooth header
        static let tagByteValue: UInt8 = 0x10

        // Valid flags for output report byte 2
        enum ValidFlag0: UInt8 {
            case rumble = 0x01
            case led = 0x04
            case rumbleAndLed = 0x05
        }

        // LED settings offsets (DualSense-style, may differ for Sense)
        static let lightbarSetup: Int = 44
        static let ledBrightness: Int = 45
        static let playerLEDs: Int = 46
        static let ledRed: Int = 47
        static let ledGreen: Int = 48
        static let ledBlue: Int = 49
    }
}
