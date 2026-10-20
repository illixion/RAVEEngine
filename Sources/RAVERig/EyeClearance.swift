import Foundation
import simd

/// Keeps a body's own skin out of the eyes of the person wearing it.
///
/// A first-person body is placed so its neck is where the wearer's is, and a
/// human neck sits a hand's breadth behind the eyes. An avatar's is often
/// thicker (a furred collar, armour, a muzzle's worth of neck), and a head
/// pitched down to look at the feet swings the eyes forward and down about
/// the neck, into the collar. From there the wearer looks out through the
/// inside of the chest. LambdaVision met it first, with a player model built
/// deeper than Gordon.
///
/// The answer is to move the body back, the way a person looking at their
/// own feet does: by exactly as much as it takes for no point of the skin to
/// come nearer the eye than `radius`. Moving the body back along `forward`
/// changes how far ahead of the eye each point is and nothing else, so the
/// step is exact per point: a point `d` from the eye, `a` of it along
/// `forward` and `c` across, leaves the sphere when it is `√(r² − c²)` behind
/// the eye, a step of `a + √(r² − c²)`; a point `r` or more off the line never
/// enters it. The largest step over the skin is the one to take.
public struct EyeClearance: Sendable {

    /// A point of skin, carried by a joint, in that joint's own space.
    public struct Point: Sendable, Equatable {
        public var joint: Int
        public var local: SIMD3<Float>
        public init(joint: Int, local: SIMD3<Float>) {
            self.joint = joint
            self.local = local
        }
    }

    public var points: [Point]
    /// How near the eye the skin may come: outside the near clipping plane,
    /// so nothing is sliced open either.
    public var radius: Float

    public init(points: [Point], radius: Float) {
        self.points = points
        self.radius = radius
    }

    /// How far back along `forward` the body must move for no point to be
    /// nearer `eye` than `radius`, given each joint's model matrix and where
    /// model space sits in the world (`root`). Negative when the body could
    /// come that much nearer; nil when no point is anywhere near the line
    /// the eye looks along.
    public func step(root: simd_float4x4, model: [float4x4], eye: SIMD3<Float>,
                     forward: SIMD3<Float>) -> Float? {
        let r2 = radius * radius
        var step: Float?
        for point in points where point.joint < model.count {
            let w = root * model[point.joint] * SIMD4<Float>(point.local, 1)
            let d = SIMD3<Float>(w.x, w.y, w.z) - eye
            let along = simd_dot(d, forward)
            let across2 = simd_length_squared(d) - along * along
            guard across2 < r2 else { continue }
            let needed = along + (r2 - across2).squareRoot()
            step = max(step ?? needed, needed)
        }
        return step
    }
}
