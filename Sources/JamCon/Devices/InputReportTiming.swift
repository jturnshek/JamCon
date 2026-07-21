import Foundation

/// Clock used to advance the input-processing pipeline.
///
/// This describes the timestamp used for signal processing; it does not imply
/// that the timestamp identifies the physical instant at which input occurred.
enum InputTimestampSource: String, CaseIterable, Hashable, Sendable {
    /// Timestamp captured at the beginning of JamCon's raw HID report callback.
    case hostReceipt
}
