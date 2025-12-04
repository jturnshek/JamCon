import Foundation

// MARK: - Device Button

/// Physical button on any input device (Joy-Con or air mouse)
enum DeviceButton: Hashable, Sendable {
    /// Joy-Con button
    case joycon(JoyConButton)

    /// Mouse button by index
    /// - 0: Left click
    /// - 1: Right click
    /// - 2: Middle click
    /// - 3: Back/Button 4
    /// - 4: Forward/Button 5
    case mouseButton(index: Int)

    /// Human-readable name for this button
    var displayName: String {
        switch self {
        case .joycon(let button):
            return button.rawValue.capitalized
        case .mouseButton(let index):
            switch index {
            case 0: return "Left Click"
            case 1: return "Right Click"
            case 2: return "Middle Click"
            case 3: return "Back"
            case 4: return "Forward"
            default: return "Button \(index + 1)"
            }
        }
    }
}

// MARK: - LogicalButton Extension

extension LogicalButton {
    /// Convert a DeviceButton to a LogicalButton based on device type
    /// - Parameters:
    ///   - button: The physical button pressed
    ///   - deviceType: The type of device
    ///   - mirrorFaceButtons: Whether to mirror face buttons (Joy-Con only)
    /// - Returns: The logical button, or nil if the button doesn't map
    static func from(
        _ button: DeviceButton,
        deviceType: InputDeviceType,
        mirrorFaceButtons: Bool
    ) -> LogicalButton? {
        switch button {
        case .joycon(let joyConButton):
            // Delegate to existing Joy-Con mapping
            return LogicalButton.from(
                joyConButton,
                controllerType: deviceType.asControllerType,
                mirrorFaceButtons: mirrorFaceButtons
            )

        case .mouseButton(let index):
            // Map air mouse buttons to logical buttons
            // This mapping treats left click like trigger, right click like shoulder
            switch index {
            case 0: return .trigger       // Left click → primary action
            case 1: return .shoulder      // Right click → secondary action
            case 2: return .stick         // Middle click → stick click equivalent
            case 3: return .faceLeft      // Back button
            case 4: return .faceRight     // Forward button
            default: return nil
            }
        }
    }

    /// Available buttons for a given device type
    static func availableButtons(for deviceType: InputDeviceType) -> [LogicalButton] {
        switch deviceType {
        case .leftJoyCon, .rightJoyCon, .proController:
            // All logical buttons available for Joy-Cons
            return LogicalButton.allCases

        case .dinostrike:
            // Dinostrike - buttons to be defined later
            return []

        case .airMouse:
            // Air mice typically have 5 buttons
            return [.trigger, .shoulder, .stick, .faceLeft, .faceRight]

        case .genericMouse:
            // Basic mice have 2-3 buttons
            return [.trigger, .shoulder, .stick]

        case .none:
            return []
        }
    }
}

// MARK: - Button Mapping Profile Extension

extension ButtonMappingProfile {
    /// Look up actions for a DeviceButton by translating to logical button first
    func actions(
        for button: DeviceButton,
        deviceType: InputDeviceType,
        mirrorFaceButtons: Bool
    ) -> ButtonActions {
        guard let logical = LogicalButton.from(
            button,
            deviceType: deviceType,
            mirrorFaceButtons: mirrorFaceButtons
        ) else {
            return ButtonActions()
        }
        return self[logical]
    }

    /// Default profile for air mouse as primary device
    static var defaultAirMousePrimary: ButtonMappingProfile {
        ButtonMappingProfile(mappings: [
            .trigger: ButtonActions(press: .mouseClick(.left)),    // Left click
            .shoulder: ButtonActions(press: .mouseClick(.right)),  // Right click
            .stick: ButtonActions(press: .mouseClick(.middle)),    // Middle click
            .faceLeft: ButtonActions(press: .keyPress(.init(keyCode: 123, modifiers: .command))),  // Cmd+[ (back)
            .faceRight: ButtonActions(press: .keyPress(.init(keyCode: 124, modifiers: .command))), // Cmd+] (forward)
        ])
    }

    /// Default profile for air mouse as secondary device
    static var defaultAirMouseSecondary: ButtonMappingProfile {
        ButtonMappingProfile(mappings: [
            .trigger: ButtonActions(press: .mouseClick(.left)),
            .shoulder: ButtonActions(press: .mouseClick(.right)),
        ])
    }
}
