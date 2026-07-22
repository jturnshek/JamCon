import Foundation

/// Opaque reference owned by a concrete HID backend. Raw framework objects stay
/// behind the transport boundary and never enter the input engine.
protocol HIDDeviceHandle: AnyObject, Sendable {
    var transportIdentifier: ObjectIdentifier { get }
}

/// Framework-neutral identity properties shared by direct HID backends.
struct HIDDeviceProperties: Equatable, Sendable {
    let vendorID: Int
    let productID: Int
    let name: String
    let serialNumber: String?
    let physicalDeviceUniqueID: String?
    let locationID: Int
    let registryEntryID: UInt64
}

enum HIDTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case managerCreationFailed
    case managerOpenFailed(Int32)
    case unexpectedHandle
    case unsupportedOperation(String)
    case deviceOpenFailed(Int32)
    case deviceCloseFailed(Int32)
    case outputReportFailed(Int32)

    var description: String {
        switch self {
        case .managerCreationFailed:
            return "HID manager creation failed"
        case let .managerOpenFailed(result):
            return "HID manager open failed (IOReturn=\(result))"
        case .unexpectedHandle:
            return "HID transport received a handle from another transport"
        case let .unsupportedOperation(message):
            return message
        case let .deviceOpenFailed(result):
            return "managed device open failed (IOReturn=\(result))"
        case let .deviceCloseFailed(result):
            return "managed device close failed (IOReturn=\(result))"
        case let .outputReportFailed(result):
            return "output report failed (IOReturn=\(result))"
        }
    }
}

protocol HIDInputRegistration: AnyObject, Sendable {}

typealias HIDReportHandler = @Sendable (
    _ reportID: UInt32,
    _ report: UnsafeMutablePointer<UInt8>,
    _ length: Int
) -> Void

/// Common lifecycle contract for direct HID backends. Device-specific
/// transports add only the output operations their protocols require.
protocol HIDTransport: AnyObject, Sendable {
    func startDiscovery(
        on runLoop: CFRunLoop,
        deviceConnected: @escaping @Sendable (any HIDDeviceHandle) -> Void,
        deviceDisconnected: @escaping @Sendable (any HIDDeviceHandle) -> Void
    ) -> Result<Void, HIDTransportError>

    func stopDiscovery(on runLoop: CFRunLoop)
    func properties(for device: any HIDDeviceHandle) -> HIDDeviceProperties?

    func openInput(
        for device: any HIDDeviceHandle,
        on runLoop: CFRunLoop,
        reportLength: Int,
        handler: @escaping HIDReportHandler
    ) -> Result<any HIDInputRegistration, HIDTransportError>

    func closeInput(
        _ registration: any HIDInputRegistration
    ) -> Result<Void, HIDTransportError>
}

enum HIDDeviceIdentity {
    /// Preserve the historic serial-number format so existing managed-device
    /// selections continue to work. Documented physical IDs come next, while
    /// location and registry IDs provide progressively weaker fallbacks.
    static func identifier(for properties: HIDDeviceProperties) -> String {
        if let serial = normalized(properties.serialNumber) {
            return serial
        }
        if let physicalID = normalized(properties.physicalDeviceUniqueID) {
            return "physical-\(physicalID)"
        }
        if properties.locationID != 0 {
            return "loc-\(properties.locationID)-pid-\(properties.productID)"
        }
        if properties.registryEntryID != 0 {
            return "registry-\(properties.registryEntryID)-pid-\(properties.productID)"
        }
        return "unidentified-pid-\(properties.productID)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
