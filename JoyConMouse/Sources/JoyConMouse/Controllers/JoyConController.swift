import Foundation
import CoreGraphics
import JoyConSwift

/// Manages Joy-Con connections and forwards input events
class JoyConController {

    // MARK: - Callbacks

    var onGyroUpdate: ((_ gyro: GyroData) -> Void)?
    var onButtonPress: ((_ button: JoyConButton) -> Void)?
    var onButtonRelease: ((_ button: JoyConButton) -> Void)?
    var onStickUpdate: ((_ position: StickPosition) -> Void)?
    var onConnectionChange: ((_ connected: Bool, _ type: ControllerType) -> Void)?
    var onBatteryUpdate: ((_ level: BatteryLevel) -> Void)?

    // MARK: - State

    private var isScanning = false
    private let manager = JoyConManager()
    private var connectedController: Controller?
    private var currentControllerType: ControllerType = .none

    // MARK: - Public Methods

    func startScanning() {
        guard !isScanning else { return }
        isScanning = true

        manager.connectHandler = { [weak self] controller in
            self?.handleControllerConnected(controller)
        }

        manager.disconnectHandler = { [weak self] controller in
            self?.handleControllerDisconnected(controller)
        }

        // Start scanning asynchronously
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.manager.runAsync()
            if result != kIOReturnSuccess {
                print("[JoyConController] Failed to start scanning: \(String(describing: result))")
            } else {
                print("[JoyConController] Started scanning for controllers...")
            }
        }
    }

    func stopScanning() {
        isScanning = false
        manager.stop()
        print("[JoyConController] Stopped scanning")
    }

    // MARK: - Controller Connection Handling

    private func handleControllerConnected(_ controller: Controller) {
        print("[JoyConController] Controller connected: \(controller.type)")

        connectedController = controller

        // Determine controller type
        let type: ControllerType
        switch controller.type {
        case .JoyConR:
            type = .rightJoyCon
        case .JoyConL:
            type = .leftJoyCon
        case .ProController:
            type = .proController
        default:
            type = .none
        }
        currentControllerType = type

        // Notify connection
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionChange?(true, type)
        }

        // Set input mode to full (required for IMU data)
        controller.setInputMode(mode: .standardFull)

        // Enable IMU (6-axis sensor)
        controller.enableIMU(enable: true)

        // Set up input handlers
        setupControllerHandlers(controller, type: type)

        // Send initial battery status
        let batteryLevel = mapBatteryStatus(controller.battery)
        DispatchQueue.main.async { [weak self] in
            self?.onBatteryUpdate?(batteryLevel)
        }
    }

    private func handleControllerDisconnected(_ controller: Controller) {
        print("[JoyConController] Controller disconnected")

        connectedController = nil
        currentControllerType = .none

        DispatchQueue.main.async { [weak self] in
            self?.onConnectionChange?(false, .none)
        }
    }

    // MARK: - Input Handler Setup

    private func setupControllerHandlers(_ controller: Controller, type: ControllerType) {
        // Sensor (gyro/accelerometer) updates
        controller.sensorHandler = { [weak self, weak controller] in
            guard let controller else { return }

            // JoyConSwift provides gyro as SCNVector3 in degrees per second
            let gyro = controller.gyro
            let gyroData = GyroData(
                x: Double(gyro.x),
                y: Double(gyro.y),
                z: Double(gyro.z)
            )
            self?.onGyroUpdate?(gyroData)
        }

        // Button press
        controller.buttonPressHandler = { [weak self] button in
            if let joyConButton = self?.mapJoyConSwiftButton(button) {
                self?.onButtonPress?(joyConButton)
            }
        }

        // Button release
        controller.buttonReleaseHandler = { [weak self] button in
            if let joyConButton = self?.mapJoyConSwiftButton(button) {
                self?.onButtonRelease?(joyConButton)
            }
        }

        // Stick position handlers
        // Use the stick that exists on the controller
        if type == .rightJoyCon {
            controller.rightStickPosHandler = { [weak self] pos in
                let position = StickPosition(x: Double(pos.x), y: Double(pos.y))
                self?.onStickUpdate?(position)
            }
        } else if type == .leftJoyCon {
            controller.leftStickPosHandler = { [weak self] pos in
                let position = StickPosition(x: Double(pos.x), y: Double(pos.y))
                self?.onStickUpdate?(position)
            }
        } else if type == .proController {
            // Pro Controller has both sticks - use right stick for scrolling
            controller.rightStickPosHandler = { [weak self] pos in
                let position = StickPosition(x: Double(pos.x), y: Double(pos.y))
                self?.onStickUpdate?(position)
            }
        }

        // Battery change handler
        controller.batteryChangeHandler = { [weak self] newLevel, _ in
            let level = self?.mapBatteryStatus(newLevel) ?? .unknown
            DispatchQueue.main.async {
                self?.onBatteryUpdate?(level)
            }
        }
    }

    // MARK: - Mapping Helpers

    private func mapJoyConSwiftButton(_ button: JoyCon.Button) -> JoyConButton? {
        switch button {
        case .A: return .a
        case .B: return .b
        case .X: return .x
        case .Y: return .y
        case .R: return .r
        case .ZR: return .zr
        case .L: return .l
        case .ZL: return .zl
        case .Plus: return .plus
        case .Minus: return .minus
        case .Home: return .home
        case .Capture: return .capture
        case .RStick: return .rightStick
        case .LStick: return .leftStick
        case .Up: return .up
        case .Down: return .down
        case .Left: return .left
        case .Right: return .right
        case .LeftSR: return .sr_l
        case .LeftSL: return .sl_l
        case .RightSR: return .sr_r
        case .RightSL: return .sl_r
        case .Start: return nil  // Famicom controller
        case .Select: return nil  // Famicom controller
        @unknown default:
            return nil
        }
    }

    private func mapBatteryStatus(_ status: JoyCon.BatteryStatus) -> BatteryLevel {
        switch status {
        case .empty:
            return .empty
        case .critical:
            return .critical
        case .low:
            return .low
        case .medium:
            return .medium
        case .full:
            return .full
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
