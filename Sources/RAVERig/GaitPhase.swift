import Foundation
import simd

/// Where in a walk clip's cycle a foot touches down.
///
/// A host that places the feet itself (`LegStepper`) still wants the rest of
/// the body from the walk clip — the arms, the bob, the sway — and those only
/// read as walking when they swing with the feet. Locking the clip to the
/// stepper needs one number: the clip phase at which the foot the stepper
/// starts on lands. The clip does not say, so it is read off the foot.
public enum GaitPhase {

    /// The phase, 0 to 1, at which the foot reaches the front of its stride,
    /// from one cycle of its positions relative to the hips (any space, as
    /// long as up is +y). Nil when the foot barely moves.
    ///
    /// The axis of travel is the foot's widest horizontal sweep, so the clip
    /// may face any way. Which end is the front comes from timing: a walking
    /// foot spends most of the cycle on the ground being carried backward and
    /// the short rest swinging forward, so the direction it moves in for
    /// longer is backward, and touchdown is the end of the sweep it moves away
    /// from slowly.
    public static func touchdown(footRelativeToHips positions: [SIMD3<Float>]) -> Float? {
        let n = positions.count
        guard n >= 4 else { return nil }
        let flat = positions.map { SIMD2<Float>($0.x, $0.z) }
        let mean = flat.reduce(.zero, +) / Float(n)
        var xx: Float = 0, xz: Float = 0, zz: Float = 0
        for p in flat {
            let d = p - mean
            xx += d.x * d.x; xz += d.x * d.y; zz += d.y * d.y
        }
        // Major axis of the 2x2 covariance.
        let angle = 0.5 * atan2(2 * xz, xx - zz)
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        let along = flat.map { simd_dot($0 - mean, axis) }
        guard let high = along.max(), let low = along.min(), high - low > 1e-4 else { return nil }

        var rising = 0
        for i in 0..<n where along[(i + 1) % n] > along[i] { rising += 1 }
        // Moving toward -axis for longer means -axis is backward, so the
        // front is the high end.
        let frontIsHigh = rising * 2 < n
        let signed = frontIsHigh ? along : along.map { -$0 }
        let peak = signed.indices.max { signed[$0] < signed[$1] }!

        // Parabola through the peak and its neighbours, for a sub-frame answer.
        let a = signed[(peak - 1 + n) % n], b = signed[peak], c = signed[(peak + 1) % n]
        let denominator = a - 2 * b + c
        let shift = abs(denominator) > 1e-9 ? min(max(0.5 * (a - c) / denominator, -0.5), 0.5) : 0
        let phase = (Float(peak) + shift) / Float(n)
        return phase < 0 ? phase + 1 : phase.truncatingRemainder(dividingBy: 1)
    }

    /// The clip phase to show for a stepper phase, given the clip phase at
    /// which the stepper's first foot lands.
    public static func clipPhase(stepperPhase: Float, touchdown: Float) -> Float {
        let p = (stepperPhase + touchdown).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }
}
