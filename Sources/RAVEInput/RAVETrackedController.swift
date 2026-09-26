/*
 RAVE Engine — tracked controllers, framework-free.

 A tracked controller is the other thing a hand can hold: a PSVR2 Sense
 controller the headset tracks itself, or a Quest Touch controller tracked by a
 Quest parked on the desk and streamed over the LAN. Both answer the same
 question a game asks of a hand — where is it, and what is it pressing — so
 both sit behind one protocol and one value type, and an app written against
 `RAVETrackedControllerSource` does not care which one the user owns.

 The same isolation rule as the rest of the sensing layer applies, for the same
 reason: one consumer polls input from a render thread that cannot await
 anything. So `poll(now:)` and `sendHaptic(_:)` are nonisolated and
 lock-guarded in every backend, and the values they trade are plain `Sendable`
 structs. Lifecycle (start/stop, discovery, authorization) is the backend's own
 business and may be `@MainActor`; the poll path never is.

 Coordinate space: every pose is in the ARKit world origin — the same space
 `RAVEARKitHandSensor` reports hands in — so a controller pose can replace a
 wrist pose without a transform. A backend whose device tracks in some other
 space (the Quest's own stage) owns the alignment and publishes nothing as
 tracked until it has one.
 */

import simd

/// Buttons on one controller, named by position rather than by label so a
/// Sense and a Touch controller agree: `primary` is A on the right Touch and X
/// on the left, Cross / Square on the Sense pair.
public struct RAVEControllerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// A / X (Touch), Cross / Square (Sense).
    public static let primary      = RAVEControllerButtons(rawValue: 1 << 0)
    /// B / Y (Touch), Circle / Triangle (Sense).
    public static let secondary    = RAVEControllerButtons(rawValue: 1 << 1)
    public static let stickClick   = RAVEControllerButtons(rawValue: 1 << 2)
    public static let menu         = RAVEControllerButtons(rawValue: 1 << 3)
    /// A digital grip press, where the device reports one. The analog squeeze
    /// is `RAVETrackedControllerState.grip` and is the value to prefer.
    public static let gripClick    = RAVEControllerButtons(rawValue: 1 << 4)
    /// Capacitive: a finger rests on the trigger. Only meaningful when
    /// `RAVETrackedControllerState.touchValid`.
    public static let triggerTouch = RAVEControllerButtons(rawValue: 1 << 5)
    /// Capacitive: the thumb rests on the stick, a face button or the
    /// thumbrest. Only meaningful when `touchValid`.
    public static let thumbTouch   = RAVEControllerButtons(rawValue: 1 << 6)
}

/// One hand's controller, as of its latest reading.
public struct RAVETrackedControllerState: Sendable, Equatable {
    public var chirality: RAVEHandChirality
    /// The pose is usable right now: tracked by the device, fresh, and (for a
    /// backend that needs one) aligned to the ARKit world. When false, fall
    /// back to hand tracking for this hand; buttons and axes still report.
    public var isTracked: Bool
    /// The backend believes the controller is in the user's hand. False for a
    /// controller put down on a desk while the hand waves elsewhere — the hand
    /// should drive this side again even though the controller is tracked.
    /// Backends that cannot tell leave it true.
    public var isInHand: Bool
    /// ARKit world space, metres. Meaningful only when `isTracked`.
    public var position: SIMD3<Float>
    public var orientation: simd_quatf
    /// Radians per second in world space, when the device reports it.
    public var angularVelocity: SIMD3<Float>?
    /// 0…1.
    public var trigger: Float
    /// Analog squeeze, 0…1.
    public var grip: Float
    /// −1…1, +y forward.
    public var stick: SIMD2<Float>
    public var buttons: RAVEControllerButtons
    /// The touch bits in `buttons` carry real readings. When false a clear
    /// touch bit means "unknown", not "not touching".
    public var touchValid: Bool
    /// 0…100, or nil when unknown.
    public var batteryPercent: UInt8?
    /// Monotonic seconds of the reading this state came from.
    public var timestamp: Double

    public init(
        chirality: RAVEHandChirality,
        isTracked: Bool = false,
        isInHand: Bool = true,
        position: SIMD3<Float> = .zero,
        orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        angularVelocity: SIMD3<Float>? = nil,
        trigger: Float = 0,
        grip: Float = 0,
        stick: SIMD2<Float> = .zero,
        buttons: RAVEControllerButtons = [],
        touchValid: Bool = false,
        batteryPercent: UInt8? = nil,
        timestamp: Double = 0
    ) {
        self.chirality = chirality
        self.isTracked = isTracked
        self.isInHand = isInHand
        self.position = position
        self.orientation = orientation
        self.angularVelocity = angularVelocity
        self.trigger = trigger
        self.grip = grip
        self.stick = stick
        self.buttons = buttons
        self.touchValid = touchValid
        self.batteryPercent = batteryPercent
        self.timestamp = timestamp
    }

    /// World-from-controller transform.
    public var transform: simd_float4x4 {
        var m = simd_float4x4(orientation)
        m.columns.3 = SIMD4(position, 1)
        return m
    }
}

/// Both hands' controllers. `nil` for a side with no controller at all.
public struct RAVETrackedControllerFrame: Sendable, Equatable {
    public var left: RAVETrackedControllerState?
    public var right: RAVETrackedControllerState?

    public init(left: RAVETrackedControllerState? = nil, right: RAVETrackedControllerState? = nil) {
        self.left = left
        self.right = right
    }

    public subscript(chirality: RAVEHandChirality) -> RAVETrackedControllerState? {
        get { chirality == .left ? left : right }
        set { if chirality == .left { left = newValue } else { right = newValue } }
    }

    /// The pose to use for a hand this frame, or nil to fall back to hand
    /// tracking: tracked and in hand.
    public func trackedPose(_ chirality: RAVEHandChirality) -> RAVETrackedControllerState? {
        guard let state = self[chirality], state.isTracked, state.isInHand else { return nil }
        return state
    }
}

/// One vibration request.
public struct RAVEControllerHaptic: Sendable, Equatable {
    public var chirality: RAVEHandChirality
    /// Seconds. 0 asks for a transient click where the device supports one.
    public var duration: Float
    /// Hz. Devices that cannot vary frequency map it to sharpness or ignore it.
    public var frequency: Float
    /// 0…1; 0 stops any vibration on that side.
    public var amplitude: Float

    public init(chirality: RAVEHandChirality, duration: Float, frequency: Float = 160, amplitude: Float) {
        self.chirality = chirality
        self.duration = duration
        self.frequency = frequency
        self.amplitude = amplitude
    }
}

/// A source of tracked controllers.
///
/// Both requirements are nonisolated and must be safe to call from any thread,
/// at frame rate. Starting and stopping are backend-specific and not part of
/// the protocol: each backend has its own prerequisites (authorization, a port,
/// a hand provider for alignment).
public protocol RAVETrackedControllerSource: AnyObject, Sendable {
    /// The latest state of both controllers. `now` is monotonic seconds (the
    /// `CACurrentMediaTime()` / `systemUptime` clock); a backend uses it to age
    /// out stale poses.
    func poll(now: Double) -> RAVETrackedControllerFrame

    /// Vibrate one controller. Fire-and-forget; silently dropped when that side
    /// has no controller.
    func sendHaptic(_ haptic: RAVEControllerHaptic)
}
