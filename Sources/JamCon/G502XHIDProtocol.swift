import Foundation

/// Logitech G502X Mouse HID Protocol Constants
/// The G502X uses a Lightspeed USB receiver for wireless connectivity.
///
/// NOTE: HID report format for Logitech mice typically uses a multi-report
/// structure. Button and movement data may be in separate reports.
/// The exact format will need verification with actual device testing.
enum G502XHIDProtocol {

    // MARK: - Device Identification

    /// Logitech vendor ID
    static let logitechVendorID: Int = 0x046D

    /// Lightspeed USB receiver product ID (used by G502X wireless)
    static let lightspeedReceiverProductID: Int = 0xC547

    /// G502X wired product ID (if different from receiver)
    /// May need to be discovered during testing
    static let wiredProductID: Int = 0xC09D  // G502 HERO, may differ for G502X

    /// All supported product IDs for matching
    static let supportedProductIDs: Set<Int> = [
        lightspeedReceiverProductID,
        wiredProductID,
        0xC098,  // G502 Lightspeed (older model)
        0xC08B,  // G502 HERO
    ]

    // MARK: - HID Report Format

    /// Standard USB mouse report ID (typically 0 or 1)
    /// Logitech may use custom report IDs - needs verification
    static let buttonReportID: UInt32 = 0x02

    /// Expected minimum report length for button data
    static let minimumReportLength: Int = 8

    // MARK: - Button Byte Layout

    /// Standard USB HID mouse button layout (byte 0 of report)
    /// Logitech extended buttons may be in additional bytes
    enum ButtonByte {
        /// Primary buttons (byte 0 in standard HID mouse)
        static let primary: Int = 0

        /// Extended buttons may be in byte 1-2
        /// Exact layout depends on device - needs verification
        static let extended1: Int = 1
        static let extended2: Int = 2
    }

    // MARK: - Standard Mouse Buttons (Byte 0)

    enum StandardButtonMask {
        static let left: UInt8 = 0x01      // Bit 0
        static let right: UInt8 = 0x02     // Bit 1
        static let middle: UInt8 = 0x04    // Bit 2
        static let back: UInt8 = 0x08      // Bit 3 (G4/Back)
        static let forward: UInt8 = 0x10   // Bit 4 (G5/Forward)
    }

    // MARK: - Extended Buttons

    /// G502X has additional buttons beyond standard 5-button mouse
    /// These button locations need verification with actual device
    enum ExtendedButtonMask {
        // Byte 1 (hypothetical - needs verification)
        static let g6: UInt8 = 0x01        // DPI down (left side)
        static let g7: UInt8 = 0x02        // G7 button
        static let g8: UInt8 = 0x04        // G8 button
        static let g9: UInt8 = 0x08        // G9 button (top button)

        // DPI shift and profile buttons may be handled in firmware
        // and not appear in HID reports
        static let dpiShift: UInt8 = 0x10  // Sniper button
        static let profileCycle: UInt8 = 0x20
    }

    // MARK: - Movement Data Offsets

    /// Standard USB mouse movement data
    /// X and Y are typically signed 8-bit or 12-bit values
    enum MovementOffset {
        static let deltaX: Int = 1   // Signed delta X
        static let deltaY: Int = 2   // Signed delta Y
        static let wheel: Int = 3    // Scroll wheel delta
        static let hWheel: Int = 4   // Horizontal scroll (if supported)
    }

    // MARK: - Button Definitions for UI

    /// Human-readable names for G502X buttons
    static let buttonNames: [String: String] = [
        "left": "Left Click",
        "right": "Right Click",
        "middle": "Middle Click",
        "back": "Back (G4)",
        "forward": "Forward (G5)",
        "g6": "G6 (DPI Down)",
        "g7": "G7",
        "g8": "G8",
        "g9": "G9",
        "dpiShift": "DPI Shift",
        "profileCycle": "Profile",
    ]
}
