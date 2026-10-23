/*
 RAVE Engine — one reading of an extended gamepad, as plain values.

 Every consumer used to walk `GCExtendedGamepad` itself and translate straight
 into its own wire format: Longwave twice (the Moonlight flags and the PCVR
 bridge's Switch Pro bits, the two nearly line for line), Lambda and Oneiros once
 each. The walk is the part that drifts — one copy reads `buttonHome`, another
 forgets it — so it lives here, once, and each consumer maps a snapshot instead.

 Names follow GameController's elements (`buttonA` is `.a`), which use Xbox
 labels whatever the pad prints on its buttons. Mapping those to a layout
 (Nintendo A/B swap, positional south/east) is the consumer's business, because
 consumers disagree about it.

 An isolation-free value type (see "The isolation rule"): the capture is a
 handful of property reads, safe from whichever thread the caller polls on.
 */

import GameController
import simd

public struct RAVEGamepadSnapshot: Sendable, Equatable {

    public struct Buttons: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let a = Buttons(rawValue: 1 << 0)
        public static let b = Buttons(rawValue: 1 << 1)
        public static let x = Buttons(rawValue: 1 << 2)
        public static let y = Buttons(rawValue: 1 << 3)
        public static let leftShoulder = Buttons(rawValue: 1 << 4)
        public static let rightShoulder = Buttons(rawValue: 1 << 5)
        /// The triggers as buttons, at GameController's own press threshold. The
        /// analog value is `leftTrigger`/`rightTrigger`; both are kept because a
        /// consumer re-deriving the press from the value would pick its own
        /// threshold and disagree with every other one.
        public static let leftTrigger = Buttons(rawValue: 1 << 6)
        public static let rightTrigger = Buttons(rawValue: 1 << 7)
        public static let leftStick = Buttons(rawValue: 1 << 8)
        public static let rightStick = Buttons(rawValue: 1 << 9)
        /// `buttonMenu`: Start, Options, Plus.
        public static let menu = Buttons(rawValue: 1 << 10)
        /// `buttonOptions`: Back, View, Create, Minus.
        public static let options = Buttons(rawValue: 1 << 11)
        public static let home = Buttons(rawValue: 1 << 12)
        public static let dpadUp = Buttons(rawValue: 1 << 13)
        public static let dpadDown = Buttons(rawValue: 1 << 14)
        public static let dpadLeft = Buttons(rawValue: 1 << 15)
        public static let dpadRight = Buttons(rawValue: 1 << 16)
    }

    public var buttons: Buttons
    /// −1…1 per axis, +Y up, as GameController reports them. No deadzone: what to
    /// ignore is a property of the consumer, not the pad.
    public var leftStick: SIMD2<Float>
    public var rightStick: SIMD2<Float>
    /// 0…1.
    public var leftTrigger: Float
    public var rightTrigger: Float
    /// Rad/s in GameController's motion axes. Nil when the pad has no gyro, or the
    /// capture was not given its `GCMotion` — never a zero standing in for absent,
    /// which would read as a pad held perfectly still.
    public var rotationRate: SIMD3<Float>?
    /// Total acceleration in g, gravity included (`GCMotion.acceleration`), same
    /// axes. Nil on the same terms.
    public var acceleration: SIMD3<Float>?

    public init(buttons: Buttons = [],
                leftStick: SIMD2<Float> = .zero, rightStick: SIMD2<Float> = .zero,
                leftTrigger: Float = 0, rightTrigger: Float = 0,
                rotationRate: SIMD3<Float>? = nil, acceleration: SIMD3<Float>? = nil) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.rotationRate = rotationRate
        self.acceleration = acceleration
    }

    /// Nothing pressed, sticks centred, no motion: what to send when a pad leaves
    /// or input moves elsewhere.
    public static let neutral = RAVEGamepadSnapshot()
}

extension RAVEGamepadSnapshot {

    /// Read `pad` now. Pass the controller's `GCMotion` to include motion; it is
    /// read only for the sensors it says it has, and only yields values while its
    /// sensors are active, which is the caller's to arrange.
    public init(_ pad: GCExtendedGamepad, motion: GCMotion? = nil) {
        var buttons: Buttons = []
        func press(_ element: GCControllerButtonInput?, _ button: Buttons) {
            if element?.isPressed == true { buttons.insert(button) }
        }
        press(pad.buttonA, .a)
        press(pad.buttonB, .b)
        press(pad.buttonX, .x)
        press(pad.buttonY, .y)
        press(pad.leftShoulder, .leftShoulder)
        press(pad.rightShoulder, .rightShoulder)
        press(pad.leftTrigger, .leftTrigger)
        press(pad.rightTrigger, .rightTrigger)
        press(pad.leftThumbstickButton, .leftStick)
        press(pad.rightThumbstickButton, .rightStick)
        press(pad.buttonMenu, .menu)
        press(pad.buttonOptions, .options)
        press(pad.buttonHome, .home)
        press(pad.dpad.up, .dpadUp)
        press(pad.dpad.down, .dpadDown)
        press(pad.dpad.left, .dpadLeft)
        press(pad.dpad.right, .dpadRight)

        var rotationRate: SIMD3<Float>?
        var acceleration: SIMD3<Float>?
        if let motion {
            if motion.hasRotationRate {
                let r = motion.rotationRate
                rotationRate = SIMD3(Float(r.x), Float(r.y), Float(r.z))
            }
            if motion.hasGravityAndUserAcceleration {
                let a = motion.acceleration
                acceleration = SIMD3(Float(a.x), Float(a.y), Float(a.z))
            }
        }

        self.init(buttons: buttons,
                  leftStick: SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value),
                  rightStick: SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value),
                  leftTrigger: pad.leftTrigger.value, rightTrigger: pad.rightTrigger.value,
                  rotationRate: rotationRate, acceleration: acceleration)
    }
}

extension RAVEGamepadSource {

    /// The current pad read into a snapshot (with motion when it has any), or nil
    /// when nothing suitable is connected.
    public func snapshot() -> RAVEGamepadSnapshot? {
        guard let controller = controller(), let pad = controller.extendedGamepad else { return nil }
        return RAVEGamepadSnapshot(pad, motion: controller.motion)
    }
}
