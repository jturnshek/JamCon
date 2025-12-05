import SwiftUI

// MARK: - Output Test View

struct OutputTestView: View {
    let controller: PSVR2Controller
    let isConnected: Bool

    @State private var rumbleLeft: Double = 0
    @State private var rumbleRight: Double = 0
    @State private var ledRed: Double = 0
    @State private var ledGreen: Double = 0
    @State private var ledBlue: Double = 255
    @State private var lastResult: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output Tests")
                    .font(.headline)
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red)
                    .font(.caption)
                Text("NOT WORKING")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.red)
                Spacer()
            }

            Text("Tested: DualSense protocol over Bluetooth does not work. May need USB or different protocol.")
                .font(.caption)
                .foregroundColor(.secondary)

            if !isConnected {
                Text("Connect a controller to test outputs")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                // Rumble section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rumble Motors")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Left: \(Int(rumbleLeft))")
                                .font(.caption)
                            Slider(value: $rumbleLeft, in: 0...255, step: 1)
                                .frame(width: 100)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Right: \(Int(rumbleRight))")
                                .font(.caption)
                            Slider(value: $rumbleRight, in: 0...255, step: 1)
                                .frame(width: 100)
                        }

                        Button("Test Rumble") {
                            controller.testRumble(left: UInt8(rumbleLeft), right: UInt8(rumbleRight))
                            lastResult = "Sent rumble L=\(Int(rumbleLeft)) R=\(Int(rumbleRight))"
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button("Pulse L") {
                            controller.testRumble(left: 128, right: 0)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                controller.testRumble(left: 0, right: 0)
                            }
                            lastResult = "Pulsed left motor"
                        }
                        .buttonStyle(.bordered)

                        Button("Pulse R") {
                            controller.testRumble(left: 0, right: 128)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                controller.testRumble(left: 0, right: 0)
                            }
                            lastResult = "Pulsed right motor"
                        }
                        .buttonStyle(.bordered)

                        Button("Pulse Both") {
                            controller.testRumble(left: 128, right: 128)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                controller.testRumble(left: 0, right: 0)
                            }
                            lastResult = "Pulsed both motors"
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)

                // LED section
                VStack(alignment: .leading, spacing: 8) {
                    Text("LED / Lightbar")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("R")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .frame(width: 14)
                                Slider(value: $ledRed, in: 0...255, step: 1)
                                    .frame(width: 80)
                                    .tint(.red)
                                Text("\(Int(ledRed))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 28)
                            }
                            HStack {
                                Text("G")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .frame(width: 14)
                                Slider(value: $ledGreen, in: 0...255, step: 1)
                                    .frame(width: 80)
                                    .tint(.green)
                                Text("\(Int(ledGreen))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 28)
                            }
                            HStack {
                                Text("B")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                    .frame(width: 14)
                                Slider(value: $ledBlue, in: 0...255, step: 1)
                                    .frame(width: 80)
                                    .tint(.blue)
                                Text("\(Int(ledBlue))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 28)
                            }
                        }

                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(
                                red: ledRed / 255,
                                green: ledGreen / 255,
                                blue: ledBlue / 255
                            ))
                            .frame(width: 40, height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )

                        Button("Set LED") {
                            controller.testLED(red: UInt8(ledRed), green: UInt8(ledGreen), blue: UInt8(ledBlue))
                            lastResult = "Set LED RGB(\(Int(ledRed)),\(Int(ledGreen)),\(Int(ledBlue)))"
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button("Red") {
                            controller.testLED(red: 255, green: 0, blue: 0)
                            lastResult = "Set LED to Red"
                        }
                        .buttonStyle(.bordered)

                        Button("Green") {
                            controller.testLED(red: 0, green: 255, blue: 0)
                            lastResult = "Set LED to Green"
                        }
                        .buttonStyle(.bordered)

                        Button("Blue") {
                            controller.testLED(red: 0, green: 0, blue: 255)
                            lastResult = "Set LED to Blue"
                        }
                        .buttonStyle(.bordered)

                        Button("White") {
                            controller.testLED(red: 255, green: 255, blue: 255)
                            lastResult = "Set LED to White"
                        }
                        .buttonStyle(.bordered)

                        Button("Off") {
                            controller.testLED(red: 0, green: 0, blue: 0)
                            lastResult = "LED Off"
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)

                // Player LEDs section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Player Indicator LEDs")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        ForEach(0..<5, id: \.self) { i in
                            Button("P\(i + 1)") {
                                controller.testPlayerLEDs(mask: UInt8(1 << i))
                                lastResult = "Set player LED \(i + 1)"
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("All") {
                            controller.testPlayerLEDs(mask: 0x1F)
                            lastResult = "All player LEDs on"
                        }
                        .buttonStyle(.bordered)

                        Button("None") {
                            controller.testPlayerLEDs(mask: 0x00)
                            lastResult = "All player LEDs off"
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)

                // Stop all button
                HStack {
                    Button("Stop All Effects") {
                        controller.stopAllEffects()
                        rumbleLeft = 0
                        rumbleRight = 0
                        lastResult = "Stopped all effects"
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    if !lastResult.isEmpty {
                        Text(lastResult)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
