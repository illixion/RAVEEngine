/*
 RAVE Engine — both hands' pinch readings plus the joystick, for one frame.

 Produced by `RAVEARKitHandSensor.poll`, but framework-free, so the event
 filtering it does (the joystick's own pinch is not a bindable event) is
 testable on the host.
 */

import simd

/// Both hands' readings for one frame.
public struct RAVEHandTickOutput: Sendable {
    public var left: RAVEPinchOutput
    public var right: RAVEPinchOutput
    /// The locomotion joystick, driven by whichever pinch the sensor reserves
    /// for it (left + index by default).
    public var joystick: RAVEJoystickOutput
    /// The hand + finger reserved for the joystick this frame, or `nil` when
    /// the joystick is disabled. Its rising edges are left out of
    /// `pinchEvents`; `left`/`right` still report it as held (see
    /// `RAVEARKitHandSensor.joystickChirality` for why).
    public var joystickSlot: RAVEHandPinchEvent?
    /// The dedicated joystick detector's reading, when the sensor was given a
    /// `joystickPinchTuning`. `nil` when the joystick shares the hand's
    /// ordinary detector.
    public var joystickPinch: RAVEPinchOutput?

    public init(
        left: RAVEPinchOutput = RAVEPinchOutput(),
        right: RAVEPinchOutput = RAVEPinchOutput(),
        joystick: RAVEJoystickOutput = RAVEJoystickOutput(),
        joystickSlot: RAVEHandPinchEvent? = nil,
        joystickPinch: RAVEPinchOutput? = nil
    ) {
        self.left = left
        self.right = right
        self.joystick = joystick
        self.joystickSlot = joystickSlot
        self.joystickPinch = joystickPinch
    }

    public subscript(chirality: RAVEHandChirality) -> RAVEPinchOutput {
        switch chirality {
        case .left:  return left
        case .right: return right
        }
    }

    /// Bindable rising edges from both hands, in left-then-right order (the
    /// order the ported originals emitted them in). The joystick's own pinch
    /// is not bindable and is left out: it drives the stick, and a binding
    /// table that forgot to reserve its slot would otherwise fire an action
    /// every time the player starts walking.
    public var pinchEvents: [RAVEHandPinchEvent] {
        var events: [RAVEHandPinchEvent] = []
        if let event = left.pinchEvent(for: .left), event != joystickSlot { events.append(event) }
        if let event = right.pinchEvent(for: .right), event != joystickSlot { events.append(event) }
        return events
    }

    /// The additive-input view of this frame.
    public var inputFrame: RAVEHandInputFrame {
        RAVEHandInputFrame(
            pinchEvents: pinchEvents,
            joystick: joystick.vector,
            joystickVisualization: joystick.visualization
        )
    }
}
