import Foundation
import simd

/// Forward And Backward Reaching Inverse Kinematics, over a chain of points.
///
/// This exists because the alternative did not work. RealityKit's
/// `IKComponent` is a whole-body iterative solver: one solve covers every
/// joint in the rig at once, minimising total error. Both legs hang off the
/// same pelvis, so when one foot target sits slightly out of reach the
/// residual is shared out — and the cheapest way to share it is to let one
/// leg keep its plant and give up on the other. That is measurable as the
/// right foot planting flat while the left stays on tiptoe, and it is the
/// objective function working correctly rather than a bug to tune away.
///
/// FABRIK has no objective function to trade against. It is a geometric
/// construction: drag the chain's tip onto the target and walk the segment
/// lengths back up, then pin the root and walk them down again. Each leg is
/// solved alone, so neither can be sacrificed for the other; nothing outside
/// the chain appears in the arithmetic, so the torso cannot rotate to help;
/// and the result depends only on this frame's input, so there is no state to
/// accumulate and nothing to drift.
///
/// It also handles the leg we actually have. A trigonometric two-bone solver
/// — the usual answer, and what FinalIK uses for a human leg — assumes two
/// segments. The Synth's digitigrade leg is thigh, shin, foot, toe: three
/// segments. FABRIK does not care how many.
public enum FABRIK {

    public struct Solution: Sendable, Equatable {
        /// The chain, same count and order as the input.
        public var positions: [SIMD3<Float>]
        /// Whether the tip arrived within tolerance.
        public var reached: Bool
        /// Distance left between the tip and the target.
        public var error: Float
        /// Iterations actually spent. Zero means the input was degenerate.
        public var iterations: Int
        /// True when the target was further away than the chain can span at
        /// all, so the best it could do was point at it.
        public var outOfReach: Bool
        /// True when the target was inside the chain's span but beyond
        /// `reachLimit`, so the aim was pulled in to keep the limb off its
        /// stops. `error` still measures the real target.
        public var extended: Bool
        /// True when the target was closer to the root than `foldLimit`
        /// allows, so the aim was pushed back out. `error` still measures the
        /// real target.
        ///
        /// The mirror of `extended`, and it means the same kind of thing: the
        /// limb is against a stop. A chain cannot fold through itself, so a
        /// target inside that radius is a statement about the target rather
        /// than a solve that went badly.
        public var folded: Bool
    }

    /// The closest the tip can come to the root.
    ///
    /// A chain can close onto a point only if no single segment is longer than
    /// all the others put together — the same condition as a polygon closing.
    /// When one is, the shortfall is the radius it can never get inside: a
    /// 12-and-10 arm cannot bring its wrist closer than 2 to its shoulder,
    /// whatever it does with the elbow.
    public static func minimumReach(of lengths: [Float]) -> Float {
        guard let longest = lengths.max() else { return 0 }
        return max(0, 2 * longest - lengths.reduce(0, +))
    }

    /// Segment lengths of a chain, as given. Measured per call rather than
    /// taken from a rest pose: a clip may scale a joint, and a solver that
    /// enforces rest lengths against a scaled pose stretches the limb.
    public static func lengths(of chain: [SIMD3<Float>]) -> [Float] {
        zip(chain, chain.dropFirst()).map { simd_length($1 - $0) }
    }

    /// Solves `chain` so its last point reaches `target`, keeping its first
    /// point where it is and every segment the length it already was.
    ///
    /// - Parameter pole: which way the chain is allowed to bend, as a
    ///   direction in the same space as the chain. The chain is flattened
    ///   into the plane through the root that contains both the target and
    ///   this direction, and every FABRIK step moves points along lines
    ///   between points already in that plane, so the chain stays in it.
    ///
    ///   That is what the pole is for here, and it is worth being precise
    ///   about: it does not choose which way the knee bends — the animated
    ///   pose already has that right, and flattening preserves it. It removes
    ///   the sideways component, so a leg cannot answer a reach it is short
    ///   of by swinging inward. The inward-creeping tiptoe walk was exactly
    ///   that, and a planar chain cannot produce it.
    ///
    ///   Pass the character's forward direction: the plane's normal is then
    ///   its left-right axis, and each leg swings sagittally.
    ///
    /// - Parameter bendTowardPole: whether the pole also chooses the side.
    ///   When true, a chain whose interior joints sit on the far side of the
    ///   root–target line is mirrored across that line, within the bend
    ///   plane, before solving, so the bend ends up on the pole's side.
    ///
    ///   Off by default, for the reason above: an animated leg already bends
    ///   the right way and must not be second-guessed. An arm posed from a
    ///   single frozen frame is the other case — its elbow sits wherever that
    ///   frame left it, and only the pole knows where it belongs. Measured on
    ///   a Half-Life player model: with the side left to the seed, a hand
    ///   raised to the face put the elbow up behind the shoulder.
    ///
    /// - Parameter reachLimit: the furthest the tip is aimed, as a fraction
    ///   of the chain's total length. It earns its place twice. A leg at full
    ///   extension is a locked leg, which reads as a limp whatever the rest
    ///   of the gait does. And FABRIK converges slowly there for the same
    ///   geometric reason — measured on a Synth-shaped leg, four iterations
    ///   land within a hundredth of a millimetre at 90% extension and are
    ///   still 14 mm out at 99%. Keeping the aim inside the limit means the
    ///   solver never works in that regime, so a cheap iteration count is
    ///   accurate everywhere rather than only in the easy middle.
    ///
    /// - Parameter foldLimit: the closest the tip is aimed, as a fraction of
    ///   the chain's total length, and the mirror of `reachLimit` in both
    ///   purpose and justification.
    ///
    ///   A chain folded back on itself is as straight as a chain pulled taut,
    ///   and FABRIK converges just as slowly there. Measured on a Half-Life
    ///   arm (11.59 + 10.13 units, so a geometric minimum reach of 1.46):
    ///   thirty-two iterations are exact from 5 units out and 80 mm adrift at
    ///   2. Aiming no closer than a quarter of the chain's length keeps the
    ///   solver out of that neighbourhood entirely, which is what makes a
    ///   cheap iteration count accurate everywhere it is used rather than only
    ///   in the comfortable middle.
    ///
    ///   The default costs nothing real. A quarter of an arm is about 14 cm
    ///   from wrist to shoulder joint — tighter than an elbow actually folds.
    public static func solve(chain: [SIMD3<Float>],
                             target: SIMD3<Float>,
                             pole: SIMD3<Float>? = nil,
                             bendTowardPole: Bool = false,
                             iterations: Int = 16,
                             reachLimit: Float = 0.98,
                             foldLimit: Float = 0.25,
                             tolerance: Float = 1e-4) -> Solution {
        guard chain.count >= 2 else {
            return Solution(positions: chain, reached: false, error: .infinity,
                            iterations: 0, outOfReach: false, extended: false,
                            folded: false)
        }
        // Lengths come from the chain as handed in, BEFORE flattening —
        // projecting onto a plane shortens segments, and FABRIK would then
        // faithfully rebuild a shortened leg.
        let lengths = lengths(of: chain)
        let total = lengths.reduce(0, +)
        guard total > 1e-6 else {
            return Solution(positions: chain, reached: false, error: .infinity,
                            iterations: 0, outOfReach: false, extended: false,
                            folded: false)
        }

        let root = chain[0]
        var joints = pole.map { flattened(chain, root: root, target: target, pole: $0) } ?? chain
        if bendTowardPole, let pole {
            joints = bentToward(pole, joints, root: root, target: target)
        }
        joints[0] = root
        let last = joints.count - 1

        // Aim short of the stops, at both ends. The shortfall is reported
        // rather than absorbed: a leg that is always straining means the step
        // length or the floor height is wrong, and that has to stay visible.
        //
        // The near end is clamped for the same reason the far end is, and it
        // is not a nicety. FABRIK converges slowly wherever the chain is close
        // to a straight line, and a chain folded back on itself is as straight
        // as a chain pulled taut. Measured on a Half-Life arm (11.6 + 10.1
        // units, minimum reach 1.5): eight iterations land within a hundredth
        // of a millimetre from 9 units out, but are 130 mm adrift at 4. Aiming
        // at a point the chain can actually occupy converges at once and gives
        // the same answer every frame, instead of one that depends on how many
        // iterations were spent.
        let reach = simd_distance(root, target)
        let usable = total * min(max(reachLimit, 0.01), 1)
        let usableMin = min(max(minimumReach(of: lengths), total * max(foldLimit, 0)), usable)
        let outOfReach = reach > total
        let extended = reach > usable
        let folded = reach < usableMin
        let aim: SIMD3<Float>
        if extended {
            aim = root + direction(from: root, to: target, fallback: upFallback) * usable
        } else if folded {
            aim = root + direction(from: root, to: target, fallback: upFallback) * usableMin
        } else {
            aim = target
        }

        // A chain that already lies along the line to its target has no bend
        // plane. Every FABRIK step moves a point along the line between two
        // points that are already on it, so a collinear chain stays collinear:
        // it can only collapse or extend, and it flips between the two once
        // per iteration without ever converging. The tip then lands on the
        // geometric minimum or the full span depending on whether the loop
        // happened to stop on an odd or an even pass, which is as arbitrary as
        // it sounds.
        //
        // This is not a corner case. A standing leg points straight down and
        // its foot target is usually straight below it; an arm hanging at rest
        // is asked to reach straight down. Nudging one interior joint off the
        // line gives the construction something to work with, and a bend the
        // solver would have found anyway is not a bend the solver invented.
        if last >= 2 {
            let axis = direction(from: root, to: aim, fallback: upFallback)
            var offLine: Float = 0
            for i in 1..<last {
                let v = joints[i] - root
                offLine = max(offLine, simd_length(v - axis * simd_dot(v, axis)))
            }
            if offLine < total * 1e-3 {
                var bend = pole.map { $0 - axis * simd_dot($0, axis) } ?? SIMD3<Float>.zero
                if simd_length(bend) < 1e-6 { bend = anyPerpendicular(to: axis) }
                bend = simd_normalize(bend)
                for i in 1..<last { joints[i] += bend * (total * 1e-2) }
            }
        }

        var used = 0
        for _ in 0..<max(iterations, 1) {
            if simd_distance(joints[last], aim) < tolerance { break }
            used += 1
            // Backward: tip onto the target, then back up to the root.
            joints[last] = aim
            for i in stride(from: last - 1, through: 0, by: -1) {
                joints[i] = joints[i + 1] + direction(from: joints[i + 1], to: joints[i],
                                                      fallback: upFallback) * lengths[i]
            }
            // Forward: root back where it belongs, then down to the tip.
            joints[0] = root
            for i in 1...last {
                joints[i] = joints[i - 1] + direction(from: joints[i - 1], to: joints[i],
                                                      fallback: upFallback) * lengths[i - 1]
            }
        }
        let error = simd_distance(joints[last], target)
        return Solution(positions: joints, reached: error < tolerance, error: error,
                        iterations: used, outOfReach: outOfReach, extended: extended,
                        folded: folded)
    }

    // MARK: - Geometry

    private static let upFallback = SIMD3<Float>(0, -1, 0)

    /// Any unit vector at right angles to `axis`. Which one does not matter —
    /// it is only ever used to break a tie the caller left unbroken.
    static func anyPerpendicular(to axis: SIMD3<Float>) -> SIMD3<Float> {
        var v = simd_cross(axis, SIMD3<Float>(1, 0, 0))
        if simd_length(v) < 1e-4 { v = simd_cross(axis, SIMD3<Float>(0, 1, 0)) }
        let length = simd_length(v)
        return length > 1e-6 ? v / length : SIMD3<Float>(1, 0, 0)
    }

    /// Unit vector from `a` to `b`, or `fallback` when they coincide.
    private static func direction(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                  fallback: SIMD3<Float>) -> SIMD3<Float> {
        let delta = b - a
        let length = simd_length(delta)
        return length > 1e-7 ? delta / length : fallback
    }

    /// `chain` projected into the plane through `root` spanned by the
    /// direction to `target` and `pole`.
    ///
    /// Returns the chain untouched when the plane is not well defined — the
    /// target sitting on the root, or a pole parallel to it. A degenerate
    /// plane would otherwise collapse the whole leg onto a line.
    static func flattened(_ chain: [SIMD3<Float>], root: SIMD3<Float>,
                          target: SIMD3<Float>, pole: SIMD3<Float>) -> [SIMD3<Float>] {
        var axis = target - root
        let reach = simd_length(axis)
        guard reach > 1e-6 else { return chain }
        axis /= reach
        var inPlane = pole - axis * simd_dot(pole, axis)
        guard simd_length(inPlane) > 1e-6 else { return chain }
        inPlane = simd_normalize(inPlane)
        let normal = simd_cross(axis, inPlane)
        guard simd_length(normal) > 1e-6 else { return chain }
        return chain.map { $0 - normal * simd_dot($0 - root, normal) }
    }

    /// `chain` with its bend on `pole`'s side of the root–target line.
    ///
    /// Judged on the interior joints together and mirrored together, across
    /// the line and within the bend plane — an isometry, so segment lengths
    /// survive. Expects a chain already flattened into that plane; an
    /// out-of-plane component is left alone. Untouched when the plane is
    /// not well defined, for the same reasons as `flattened`.
    static func bentToward(_ pole: SIMD3<Float>, _ chain: [SIMD3<Float>], root: SIMD3<Float>,
                           target: SIMD3<Float>) -> [SIMD3<Float>] {
        guard chain.count >= 3 else { return chain }
        var axis = target - root
        let reach = simd_length(axis)
        guard reach > 1e-6 else { return chain }
        axis /= reach
        var inPlane = pole - axis * simd_dot(pole, axis)
        guard simd_length(inPlane) > 1e-6 else { return chain }
        inPlane = simd_normalize(inPlane)
        let interior = 1..<(chain.count - 1)
        let side = interior.reduce(Float(0)) { $0 + simd_dot(chain[$1] - root, inPlane) }
        guard side < 0 else { return chain }
        var out = chain
        for i in interior {
            out[i] -= inPlane * (2 * simd_dot(chain[i] - root, inPlane))
        }
        return out
    }
}
