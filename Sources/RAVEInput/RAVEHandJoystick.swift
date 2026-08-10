/*
 RAVE Engine — the wrist-delta locomotion joystick.

 A sustained pinch anchors the wrist; while it is held, the wrist's displacement
 from that anchor is projected onto the player's head-relative horizontal basis
 and scaled to a unit vector. Releasing drops the anchor, so the next engage
 re-centres wherever the hand happens to be.

 All three apps implemented this identically apart from Lambda's deadzone (which
 stops a perfectly still pinch from creeping) and Lambda's use of the raw vertical
 delta for jump/duck. Both are parameters here rather than forks.

 Head-relative rather than world-relative is the load-bearing detail: it means the
 joystick survives snap turns and a rotating vehicle, because "forward" is
 re-read from the head basis every frame instead of being baked into the anchor.
 */

import simd

/// The joystick's reading for one frame.
public struct RAVEJoystickOutput: Sendable, Equatable {
    /// Head-relative (x = strafe, y = forward), magnitude clamped to 1.
    public var vector: SIMD2<Float>
    /// Raw world-space wrist displacement from the anchor. Vertical gestures
    /// (jump / duck) read `delta.y`; the horizontal part is already folded into
    /// `vector`.
    public var delta: SIMD3<Float>
    /// True while an anchor is held.
    public var isEngaged: Bool

    public init(
        vector: SIMD2<Float> = .zero,
        delta: SIMD3<Float> = .zero,
        isEngaged: Bool = false
    ) {
        self.vector = vector
        self.delta = delta
        self.isEngaged = isEngaged
    }
}

/// Wrist-delta joystick. One per hand that can drive locomotion; stored by
/// value alongside the pinch detector that gates it.
public struct RAVEHandJoystick: Sendable {
    /// Wrist displacement, in meters, that reads as full deflection.
    public var fullScaleMeters: Float
    /// Horizontal displacement below which the stick reads zero. Zero disables
    /// the deadzone entirely (the hysteresis on the engaging pinch is then the
    /// only thing stopping drift).
    public var deadzoneMeters: Float

    /// Where the wrist was when the current hold began. `nil` when disengaged.
    public private(set) var anchorWorld: SIMD3<Float>?

    public init(fullScaleMeters: Float = 0.18, deadzoneMeters: Float = 0) {
        self.fullScaleMeters = fullScaleMeters
        self.deadzoneMeters = deadzoneMeters
    }

    /// Drop the anchor without producing a reading.
    public mutating func release() {
        anchorWorld = nil
    }

    /// Advance one frame.
    ///
    /// - Parameters:
    ///   - wristWorld: current wrist position, world space.
    ///   - engaged: whether the gating pinch is held this frame. `false` drops
    ///     the anchor and returns a zero reading.
    ///   - worldForward/worldRight: the player's head-relative basis in world
    ///     space. Flattened to horizontal here, so callers may pass the raw
    ///     head axes.
    public mutating func update(
        wristWorld: SIMD3<Float>?,
        engaged: Bool,
        worldForward: SIMD3<Float>,
        worldRight: SIMD3<Float>
    ) -> RAVEJoystickOutput {
        guard engaged, let wristWorld else {
            anchorWorld = nil
            return RAVEJoystickOutput()
        }

        if anchorWorld == nil { anchorWorld = wristWorld }
        let delta = wristWorld - (anchorWorld ?? wristWorld)

        // Flatten the head basis, then RE-NORMALIZE. Two of the three ported
        // copies projected onto the raw flattened axes, which shortens them
        // whenever the head is pitched — so looking down at your hand, which is
        // exactly what you do while using a wrist joystick, quietly reduced
        // forward sensitivity. Lambda's copy normalized and was right to.
        let forward = Self.flattenedUnit(worldForward, fallback: SIMD3(0, 0, -1))
        let right = Self.flattenedUnit(worldRight, fallback: SIMD3(1, 0, 0))
        let strafe = simd_dot(delta, right)
        let advance = simd_dot(delta, forward)

        guard (strafe * strafe + advance * advance).squareRoot() > deadzoneMeters else {
            return RAVEJoystickOutput(vector: .zero, delta: delta, isEngaged: true)
        }

        let scale = 1 / fullScaleMeters
        var x = strafe * scale
        var y = advance * scale
        let magnitude = (x * x + y * y).squareRoot()
        if magnitude > 1 {
            x /= magnitude
            y /= magnitude
        }
        return RAVEJoystickOutput(vector: SIMD2(x, y), delta: delta, isEngaged: true)
    }

    /// Horizontal component of `v`, normalized. Falls back when the axis points
    /// straight up or down and so has no horizontal part to speak of.
    static func flattenedUnit(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let flat = SIMD3<Float>(v.x, 0, v.z)
        let length = simd_length(flat)
        return length > 1e-5 ? flat / length : fallback
    }
}
