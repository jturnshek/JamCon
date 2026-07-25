import Foundation

enum LinkedJoyConSide: Equatable, Sendable {
    case left
    case right
}

struct JoyConGamepadHalfState: Equatable, Sendable {
    let side: LinkedJoyConSide
    let stickX: Int16
    let stickY: Int16
    private let pressedButtonBits: UInt32

    init(
        side: LinkedJoyConSide,
        stickX: Int16 = 0,
        stickY: Int16 = 0,
        pressedButtons: [JoyConLogicalButton] = []
    ) {
        self.side = side
        self.stickX = stickX
        self.stickY = stickY
        self.pressedButtonBits = pressedButtons.reduce(into: UInt32(0)) { result, button in
            result |= 1 << UInt32(button.index)
        }
    }

    init(
        side: LinkedJoyConSide,
        stickX: Int16,
        stickY: Int16,
        pressedButtonBits: UInt32
    ) {
        self.side = side
        self.stickX = stickX
        self.stickY = stickY
        self.pressedButtonBits = pressedButtonBits
    }

    func isPressed(_ button: JoyConLogicalButton) -> Bool {
        pressedButtonBits & (1 << UInt32(button.index)) != 0
    }
}

/// Holds the latest state from each physical half. The caller publishes the
/// returned combined state immediately on every physical input frame; no
/// resampling timer or additional input queue is needed.
struct LinkedJoyConGamepadComposer: Sendable {
    private struct TimedHalfState: Sendable {
        let state: JoyConGamepadHalfState
        let timestamp: TimeInterval
    }

    private var left: TimedHalfState?
    private var right: TimedHalfState?

    var latestState: VirtualGamepadState? {
        guard let left, let right else {
            return nil
        }
        return Self.compose(left: left.state, right: right.state)
    }

    func freshState(
        at timestamp: TimeInterval,
        timeout: TimeInterval
    ) -> VirtualGamepadState? {
        guard let left, let right,
              timestamp >= left.timestamp,
              timestamp >= right.timestamp,
              timestamp - left.timestamp <= timeout,
              timestamp - right.timestamp <= timeout else {
            return nil
        }
        return Self.compose(left: left.state, right: right.state)
    }

    @discardableResult
    mutating func update(
        _ half: JoyConGamepadHalfState,
        timestamp: TimeInterval
    ) -> VirtualGamepadState? {
        let timedState = TimedHalfState(state: half, timestamp: timestamp)
        switch half.side {
        case .left:
            left = timedState
        case .right:
            right = timedState
        }
        return latestState
    }

    @discardableResult
    mutating func remove(_ side: LinkedJoyConSide) -> VirtualGamepadState? {
        switch side {
        case .left:
            left = nil
        case .right:
            right = nil
        }
        return latestState
    }

    private static func compose(
        left: JoyConGamepadHalfState,
        right: JoyConGamepadHalfState
    ) -> VirtualGamepadState {
        var buttons: VirtualGamepadButtons = []

        // Preserve physical face-button positions. Nintendo B/A/Y/X occupy
        // the conventional south/east/west/north positions respectively.
        buttons.set(.button(.south), enabled: right.isPressed(.b))
        buttons.set(.button(.east), enabled: right.isPressed(.a))
        buttons.set(.button(.west), enabled: right.isPressed(.y))
        buttons.set(.button(.north), enabled: right.isPressed(.x))
        buttons.set(.button(.leftShoulder), enabled: left.isPressed(.l))
        buttons.set(.button(.rightShoulder), enabled: right.isPressed(.r))
        buttons.set(.button(.leftStick), enabled: left.isPressed(.stickClick))
        buttons.set(.button(.rightStick), enabled: right.isPressed(.stickClick))
        buttons.set(.button(.select), enabled: left.isPressed(.minus))
        buttons.set(.button(.start), enabled: right.isPressed(.plus))
        buttons.set(.button(.home), enabled: right.isPressed(.home))
        buttons.set(.button(.capture), enabled: left.isPressed(.capture))
        buttons.set(.button(.auxiliary), enabled: right.isPressed(.c))

        return VirtualGamepadState(
            buttons: buttons,
            hat: hat(
                up: left.isPressed(.dpadUp),
                down: left.isPressed(.dpadDown),
                left: left.isPressed(.dpadLeft),
                right: left.isPressed(.dpadRight)
            ),
            leftX: left.stickX,
            leftY: left.stickY,
            rightX: right.stickX,
            rightY: right.stickY,
            leftTrigger: left.isPressed(.zl) ? .max : 0,
            rightTrigger: right.isPressed(.zr) ? .max : 0
        )
    }

    private static func hat(
        up: Bool,
        down: Bool,
        left: Bool,
        right: Bool
    ) -> VirtualGamepadHat {
        let vertical = (up ? -1 : 0) + (down ? 1 : 0)
        let horizontal = (left ? -1 : 0) + (right ? 1 : 0)
        switch (horizontal, vertical) {
        case (0, -1): return .north
        case (1, -1): return .northEast
        case (1, 0): return .east
        case (1, 1): return .southEast
        case (0, 1): return .south
        case (-1, 1): return .southWest
        case (-1, 0): return .west
        case (-1, -1): return .northWest
        default: return .neutral
        }
    }
}

private extension VirtualGamepadButtons {
    mutating func set(_ button: Self, enabled: Bool) {
        if enabled {
            insert(button)
        } else {
            remove(button)
        }
    }
}
