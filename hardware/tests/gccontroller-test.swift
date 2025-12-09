#!/usr/bin/env swift

// GCController Test for PSVR2 Sense Controllers
// Run with: swift gccontroller-test.swift
//
// Tests what GCController framework exposes for PSVR2 controllers:
// - Controller detection
// - Button input (and whether it prevents keyboard mapping)
// - Motion/gyro data availability

import Foundation
import GameController

class ControllerTester {

    init() {
        setupNotifications()
        checkExistingControllers()
        startDiscovery()
    }

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let controller = notification.object as? GCController {
                self?.handleControllerConnected(controller)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { notification in
            if let controller = notification.object as? GCController {
                print("\n❌ Controller disconnected: \(controller.vendorName ?? "Unknown")")
            }
        }
    }

    func checkExistingControllers() {
        print("=== GCController Test for PSVR2 ===\n")
        print("Checking for already-connected controllers...")

        let controllers = GCController.controllers()
        if controllers.isEmpty {
            print("No controllers currently connected.")
        } else {
            for controller in controllers {
                handleControllerConnected(controller)
            }
        }
    }

    func startDiscovery() {
        print("\nStarting wireless controller discovery...")
        print("(Connect your PSVR2 controller via Bluetooth now)\n")
        print("Press Ctrl+C to exit.\n")

        GCController.startWirelessControllerDiscovery {
            print("Discovery completed.")
        }
    }

    func handleControllerConnected(_ controller: GCController) {
        print("\n" + String(repeating: "=", count: 50))
        print("✅ CONTROLLER CONNECTED")
        print(String(repeating: "=", count: 50))

        // Basic info
        print("\n📋 Basic Info:")
        print("  Name: \(controller.vendorName ?? "Unknown")")
        print("  Product Category: \(controller.productCategory)")
        if #available(macOS 11.0, *) {
            print("  Physical Input Profile: \(type(of: controller.physicalInputProfile))")
        }

        // Check available profiles
        print("\n🎮 Available Profiles:")
        print("  Extended Gamepad: \(controller.extendedGamepad != nil ? "✅ YES" : "❌ NO")")
        print("  Gamepad: \(controller.gamepad != nil ? "✅ YES" : "❌ NO")")
        print("  Micro Gamepad: \(controller.microGamepad != nil ? "✅ YES" : "❌ NO")")
        print("  Motion: \(controller.motion != nil ? "✅ YES" : "❌ NO")")

        // Setup button handlers
        setupButtonHandlers(controller)

        // Setup motion handler
        setupMotionHandler(controller)

        print("\n👆 Try pressing buttons on the controller...")
        print("   (Watch for keyboard events in other apps to test if input is consumed)")
    }

    func setupButtonHandlers(_ controller: GCController) {
        print("\n🔘 Setting up button handlers...")

        // Try the physicalInputProfile first (newer API)
        if #available(macOS 11.0, *) {
            let input = controller.physicalInputProfile
            print("  Physical input elements:")
            print("    Buttons: \(input.buttons.keys.sorted())")
            print("    Axes: \(input.axes.keys.sorted())")
            print("    Dpads: \(input.dpads.keys.sorted())")

            // Set up a catch-all handler for any element change
            input.valueDidChangeHandler = { profile, element in
                print("  📍 Input changed: \(element.localizedName ?? element.description) = \(element)")
            }
        }

        if let gamepad = controller.extendedGamepad {
            print("  Using Extended Gamepad profile")

            // Set a catch-all handler first
            gamepad.valueChangedHandler = { gamepad, element in
                print("  🎮 Gamepad element: \(element)")
            }

            // Face buttons
            gamepad.buttonA.pressedChangedHandler = { _, _, pressed in
                print("  Button A (X): \(pressed ? "PRESSED" : "released")")
            }
            gamepad.buttonB.pressedChangedHandler = { _, _, pressed in
                print("  Button B (Circle): \(pressed ? "PRESSED" : "released")")
            }
            gamepad.buttonX.pressedChangedHandler = { _, _, pressed in
                print("  Button X (Square): \(pressed ? "PRESSED" : "released")")
            }
            gamepad.buttonY.pressedChangedHandler = { _, _, pressed in
                print("  Button Y (Triangle): \(pressed ? "PRESSED" : "released")")
            }

            // Shoulders/triggers
            gamepad.leftShoulder.pressedChangedHandler = { _, _, pressed in
                print("  L1: \(pressed ? "PRESSED" : "released")")
            }
            gamepad.rightShoulder.pressedChangedHandler = { _, _, pressed in
                print("  R1: \(pressed ? "PRESSED" : "released")")
            }
            gamepad.leftTrigger.valueChangedHandler = { _, value, pressed in
                if pressed || value > 0.1 {
                    print("  L2: \(String(format: "%.2f", value))")
                }
            }
            gamepad.rightTrigger.valueChangedHandler = { _, value, pressed in
                if pressed || value > 0.1 {
                    print("  R2: \(String(format: "%.2f", value))")
                }
            }

            // Thumbsticks
            gamepad.leftThumbstick.valueChangedHandler = { _, x, y in
                if abs(x) > 0.1 || abs(y) > 0.1 {
                    print("  Left Stick: (\(String(format: "%.2f", x)), \(String(format: "%.2f", y)))")
                }
            }
            gamepad.rightThumbstick.valueChangedHandler = { _, x, y in
                if abs(x) > 0.1 || abs(y) > 0.1 {
                    print("  Right Stick: (\(String(format: "%.2f", x)), \(String(format: "%.2f", y)))")
                }
            }

            // Thumbstick buttons
            gamepad.leftThumbstickButton?.pressedChangedHandler = { _, _, pressed in
                print("  L3: \(pressed ? "PRESSED" : "released")")
            }
            gamepad.rightThumbstickButton?.pressedChangedHandler = { _, _, pressed in
                print("  R3: \(pressed ? "PRESSED" : "released")")
            }

            // Menu buttons
            gamepad.buttonMenu.pressedChangedHandler = { _, _, pressed in
                print("  Menu/Options: \(pressed ? "PRESSED" : "released")")
            }
            gamepad.buttonOptions?.pressedChangedHandler = { _, _, pressed in
                print("  Options/Share: \(pressed ? "PRESSED" : "released")")
            }

            // Home button
            gamepad.buttonHome?.pressedChangedHandler = { _, _, pressed in
                print("  Home/PS: \(pressed ? "PRESSED" : "released")")
            }

        } else if let gamepad = controller.gamepad {
            print("  Using basic Gamepad profile")
            gamepad.valueChangedHandler = { _, element in
                print("  Input: \(element)")
            }
        } else {
            print("  ⚠️ No gamepad profile available")
        }

        // Also try polling current state
        print("\n  Polling current button states:")
        if let gamepad = controller.extendedGamepad {
            print("    A: \(gamepad.buttonA.isPressed), B: \(gamepad.buttonB.isPressed), X: \(gamepad.buttonX.isPressed), Y: \(gamepad.buttonY.isPressed)")
            print("    L1: \(gamepad.leftShoulder.isPressed), R1: \(gamepad.rightShoulder.isPressed)")
            print("    L2: \(gamepad.leftTrigger.value), R2: \(gamepad.rightTrigger.value)")
        }
    }

    func setupMotionHandler(_ controller: GCController) {
        guard let motion = controller.motion else {
            print("\n📐 Motion: Not available on this controller")
            return
        }

        print("\n📐 Motion Profile Available!")
        print("  Setting up motion handler...")

        var lastPrint = Date()

        motion.valueChangedHandler = { motion in
            // Only print every 500ms to avoid spam
            let now = Date()
            guard now.timeIntervalSince(lastPrint) > 0.5 else { return }
            lastPrint = now

            print("\n  --- Motion Data ---")
            print("  Gravity: (\(String(format: "%.3f", motion.gravity.x)), \(String(format: "%.3f", motion.gravity.y)), \(String(format: "%.3f", motion.gravity.z)))")
            print("  User Accel: (\(String(format: "%.3f", motion.userAcceleration.x)), \(String(format: "%.3f", motion.userAcceleration.y)), \(String(format: "%.3f", motion.userAcceleration.z)))")

            if #available(macOS 11.0, *) {
                print("  Rotation Rate: (\(String(format: "%.3f", motion.rotationRate.x)), \(String(format: "%.3f", motion.rotationRate.y)), \(String(format: "%.3f", motion.rotationRate.z)))")
                print("  Attitude: (\(String(format: "%.3f", motion.attitude.x)), \(String(format: "%.3f", motion.attitude.y)), \(String(format: "%.3f", motion.attitude.z)), \(String(format: "%.3f", motion.attitude.w)))")
            }
        }

        // Also check if we need to set sensorsActive
        if #available(macOS 11.0, *) {
            motion.sensorsActive = true
            print("  Sensors activated")
        }
    }
}

// Main
let tester = ControllerTester()

// Keep the run loop alive
RunLoop.main.run()
