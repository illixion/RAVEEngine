/*
 RAVE Engine — stick shaping: deadzones and snap-turn edges.

 Every app that reads a thumbstick re-picked the same three numbers: a ~0.15
 radial deadzone, a ~0.15 per-axis deadzone so pushing forward does not also
 strafe, and a ~0.5 deflection as the snap-turn edge. Each also re-derived the
 edge logic, and none of them had hysteresis on it, so a stick resting near the
 edge could snap twice on one push. This is that logic, once, framework-free:
 it shapes plain `SIMD2<Float>` values, so it serves a `GCExtendedGamepad`, a
 spatial controller and the hand joystick equally.

 Value types with no isolation, like the rest of the sensing layer.
 */

import Foundation
import simd

/// Deadzone helpers for a 2D stick value. Inputs are expected in -1...1 per
/// axis; outputs are clamped to unit magnitude.
public enum RAVEStickShaping {

    /// The deadzone every consumer arrived at independently.
    public static let defaultDeadzone: Float = 0.15

    /// Zero the stick inside a circle of radius `deadzone`. With `rescale`
    /// the remaining travel is remapped so output starts at zero on the
    /// deadzone's edge and still reaches 1 at full deflection — without it,
    /// the output jumps from 0 to `deadzone` as the stick leaves the circle.
    public static func radialDeadzone(
        _ value: SIMD2<Float>,
        deadzone: Float = defaultDeadzone,
        rescale: Bool = true
    ) -> SIMD2<Float> {
        guard value.x.isFinite, value.y.isFinite else { return .zero }
        let dz = min(max(deadzone.isFinite ? deadzone : 0, 0), 0.999)
        let magnitude = simd_length(value)
        guard magnitude > dz, magnitude > 1e-6 else { return .zero }
        let direction = value / magnitude
        let clamped = min(magnitude, 1)
        let out = rescale ? (clamped - dz) / (1 - dz) : clamped
        return direction * out
    }

    /// Zero each axis independently when its magnitude is below `deadzone`
    /// (a cross-shaped deadzone), rescaling the rest of that axis's travel.
    /// Applied after a radial deadzone it keeps a forward push from also
    /// strafing a little.
    public static func axialDeadzone(
        _ value: SIMD2<Float>,
        deadzone: Float = defaultDeadzone,
        rescale: Bool = true
    ) -> SIMD2<Float> {
        guard value.x.isFinite, value.y.isFinite else { return .zero }
        let dz = min(max(deadzone.isFinite ? deadzone : 0, 0), 0.999)
        func axis(_ v: Float) -> Float {
            let a = abs(v)
            guard a > dz else { return 0 }
            let clamped = min(a, 1)
            let out = rescale ? (clamped - dz) / (1 - dz) : clamped
            return v < 0 ? -out : out
        }
        var out = SIMD2(axis(value.x), axis(value.y))
        let length = simd_length(out)
        if length > 1 { out /= length }
        return out
    }

    /// Radial then axial: the shape most game sticks want.
    public static func shaped(
        _ value: SIMD2<Float>,
        radialDeadzone radial: Float = defaultDeadzone,
        axialDeadzone axial: Float = 0
    ) -> SIMD2<Float> {
        let r = radialDeadzone(value, deadzone: radial)
        return axial > 0 ? axialDeadzone(r, deadzone: axial) : r
    }
}

/// Turns one stick axis into discrete snap-turn steps.
///
/// Fires when the axis crosses `engage`, and re-arms only once it falls back
/// below `release` — the hysteresis a stick resting near the edge needs, or a
/// single push snaps twice. Optionally repeats while held, after
/// `repeatDelay` and then every `repeatInterval`.
public struct RAVESnapTurnDetector: Sendable, Equatable {
    /// Deflection that fires a step.
    public var engage: Float
    /// Deflection below which the detector re-arms. Must be below `engage`.
    public var release: Float
    /// Delay before a held stick starts repeating. `nil` never repeats: one
    /// push, one step.
    public var repeatDelay: TimeInterval?
    /// Time between repeats once repeating.
    public var repeatInterval: TimeInterval

    /// The direction currently held past `engage` (-1, +1), or 0 when armed.
    public private(set) var heldDirection: Int = 0
    private var nextRepeat: TimeInterval = .infinity

    public init(
        engage: Float = 0.5,
        release: Float = 0.3,
        repeatDelay: TimeInterval? = nil,
        repeatInterval: TimeInterval = 0.3
    ) {
        self.engage = engage
        self.release = release
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
    }

    public mutating func reset() {
        heldDirection = 0
        nextRepeat = .infinity
    }

    /// Feed this frame's axis value. Returns -1 or +1 on a frame that fires a
    /// step, 0 otherwise.
    @discardableResult
    public mutating func update(_ axis: Float, now: TimeInterval) -> Int {
        let value = axis.isFinite ? axis : 0
        let magnitude = abs(value)
        let direction = value < 0 ? -1 : 1

        if heldDirection != 0 {
            // Flicked straight through to the other side: that is a new push.
            if magnitude >= engage, direction != heldDirection {
                return fire(direction, now: now)
            }
            if magnitude < release {
                reset()
                return 0
            }
            if now >= nextRepeat {
                nextRepeat = now + max(repeatInterval, 1e-3)
                return heldDirection
            }
            return 0
        }
        if magnitude >= engage {
            return fire(direction, now: now)
        }
        return 0
    }

    private mutating func fire(_ direction: Int, now: TimeInterval) -> Int {
        heldDirection = direction
        nextRepeat = repeatDelay.map { now + max($0, 0) } ?? .infinity
        return direction
    }
}
