import Foundation
import simd

/// One joint's transform relative to its parent.
///
/// Deliberately the same shape as RealityKit's `Transform` and as a GoldSrc
/// bone's decomposed pos/quat, so both consumers convert in a line and neither
/// has to hand this package its own type. Scale is carried rather than assumed
/// away: a clip may scale a joint, and a solver that quietly drops it would
/// rebuild the limb at the wrong length.
public struct JointPose: Sendable, Equatable {
    public var rotation: simd_quatf
    public var translation: SIMD3<Float>
    public var scale: SIMD3<Float>

    public init(rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                translation: SIMD3<Float> = .zero,
                scale: SIMD3<Float> = .one) {
        self.rotation = rotation
        self.translation = translation
        self.scale = scale
    }

    public var matrix: float4x4 {
        var m = float4x4(rotation)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4<Float>(translation, 1)
        return m
    }
}

/// Bends joint chains onto targets by running `FABRIK` in model space and
/// turning the result back into joint rotations.
///
/// The two halves are worth keeping apart in your head. FABRIK answers "where
/// should each joint sit"; it knows nothing about a skeleton and returns bare
/// points. A skinned character needs "how far should each joint turn", because
/// that is what a bone palette or a `SkeletalPose` stores, and the conversion
/// is where the subtleties live — accumulated parent transforms, the change of
/// basis into a parent's space, and rotations that are undefined exactly when
/// a limb straightens out.
///
/// This type is that conversion, and nothing else. It does not know what a leg
/// is, where the floor is, or which framework will consume the pose: callers
/// hand it local transforms and get local transforms back. `spatial-ai-character`
/// wraps it for RealityKit's `SkeletalPose`; `halflife-visionos` wraps it for a
/// GoldSrc bone palette bound for a Metal vertex shader.
public struct PoseSolver: Sendable {

    /// Parent index per joint, nil for a root.
    public let parents: [Int?]
    /// Joint indices ordered so a parent always precedes its children.
    public let order: [Int]

    /// A run of joints, each the direct parent of the next, root first.
    public struct Chain: Sendable, Equatable {
        public var joints: [Int]
        public init(joints: [Int]) { self.joints = joints }
    }

    public struct Report: Sendable, Equatable {
        /// Distance left between the chain's tip and the target.
        public var error: Float
        public var reached: Bool
        /// The chain is at its comfortable limit — normal at full stretch.
        public var extended: Bool
        /// The target is further than the chain is long, which means the
        /// target itself is wrong rather than the solve.
        public var outOfReach: Bool
        /// The target is inside the radius the chain can fold to — a wrist
        /// asked to sit inside its own shoulder. Also a statement about the
        /// target rather than the solve.
        public var folded: Bool
        public var iterations: Int

        public static let unsolved = Report(error: .infinity, reached: false,
                                            extended: false, outOfReach: false,
                                            folded: false, iterations: 0)
    }

    /// - Parameter parents: one entry per joint; nil marks a root. Indices
    ///   must be in range, but need not be ordered parents-before-children.
    public init(parents: [Int?]) {
        self.parents = parents
        self.order = Self.traversalOrder(parents: parents)
    }

    // MARK: - Topology

    /// Joint indices sorted shallowest first, so forward kinematics runs in a
    /// single pass.
    ///
    /// Sorted by measured depth rather than by trusting declaration order.
    /// Most exporters do emit parents first, but a skeleton rebuilt from a
    /// runtime — or a GoldSrc rig, which only promises that indices exist —
    /// need not, and a single out-of-order joint silently poses its whole
    /// subtree against a stale parent.
    public static func traversalOrder(parents: [Int?]) -> [Int] {
        var depth = [Int](repeating: -1, count: parents.count)
        func measure(_ i: Int, _ guard_: Int = 0) -> Int {
            if depth[i] >= 0 { return depth[i] }
            // A cycle cannot produce a valid depth; treat it as a root rather
            // than recursing forever on malformed input.
            guard guard_ < parents.count, let p = parents[i], p >= 0, p < parents.count, p != i
            else { depth[i] = 0; return 0 }
            let d = measure(p, guard_ + 1) + 1
            depth[i] = d
            return d
        }
        for i in parents.indices { _ = measure(i) }
        return parents.indices.sorted { depth[$0] == depth[$1] ? $0 < $1 : depth[$0] < depth[$1] }
    }

    /// Parents read off hierarchical joint names, where the parent of `a/b/c`
    /// is whichever joint is named `a/b`. RealityKit names joints this way.
    public static func parents(fromPaths names: [String]) -> [Int?] {
        var index = [String: Int](minimumCapacity: names.count)
        for (i, name) in names.enumerated() { index[name] = i }
        return names.map { name in
            guard let cut = name.lastIndex(of: "/") else { return nil }
            return index[String(name[name.startIndex..<cut])]
        }
    }

    /// Validates that `joints` really is a parent-to-child run.
    ///
    /// Returns nil rather than repairing it. A rig can be shaped any way at
    /// all, and a solver that treats an unrelated joint as the next link
    /// produces a limb bending in an impossible place — which looks like a
    /// tuning problem and is not one.
    public func chain(_ joints: [Int]) -> Chain? {
        guard joints.count >= 2,
              joints.allSatisfy({ $0 >= 0 && $0 < parents.count }) else { return nil }
        for (parent, child) in zip(joints, joints.dropFirst()) where parents[child] != parent {
            return nil
        }
        return Chain(joints: joints)
    }

    // MARK: - Kinematics

    /// Model-space matrix per joint, accumulated from parent-relative ones.
    public func modelMatrices(of pose: [JointPose]) -> [float4x4] {
        var out = [float4x4](repeating: matrix_identity_float4x4, count: pose.count)
        for i in order where i < pose.count {
            let local = pose[i].matrix
            if let parent = parents[i], parent >= 0, parent < out.count, parent != i {
                out[i] = out[parent] * local
            } else {
                out[i] = local
            }
        }
        return out
    }

    // MARK: - Solving

    /// Bends `chain` so its last joint reaches `target`, writing the result
    /// back into `pose` as joint rotations.
    ///
    /// `target` and `pole` are in the same space as the model matrices — the
    /// space the root of the skeleton sits in. `bendTowardPole` is FABRIK's:
    /// off, the pole only fixes the plane and the current pose keeps its
    /// side of the bend; on, the pole chooses the side too.
    ///
    /// `model` is taken `inout` and kept current for the solved joints, so
    /// several chains can be solved against one array in sequence. Joints
    /// hanging off a solved chain but not part of it are left stale; refresh
    /// with `modelMatrices(of:)` if something downstream needs them.
    @discardableResult
    public func solve(chain: Chain,
                      target: SIMD3<Float>,
                      pole: SIMD3<Float>? = nil,
                      bendTowardPole: Bool = false,
                      weight: Float = 1,
                      iterations: Int = 8,
                      reachLimit: Float = 0.98,
                      pose: inout [JointPose],
                      model: inout [float4x4]) -> Report {
        let joints = chain.joints
        guard joints.allSatisfy({ $0 < pose.count && $0 < model.count }) else { return .unsolved }

        let points = joints.map { Self.translation(of: model[$0]) }
        let solution = FABRIK.solve(chain: points, target: target, pole: pole,
                                    bendTowardPole: bendTowardPole,
                                    iterations: iterations, reachLimit: reachLimit)
        place(joints, at: solution.positions, weight: weight, pose: &pose, model: &model)
        return Report(error: solution.error, reached: solution.reached,
                      extended: solution.extended, outOfReach: solution.outOfReach,
                      folded: solution.folded, iterations: solution.iterations)
    }

    /// Bends a leg so its last joint reaches `target`, in closed form.
    ///
    /// A three-joint chain (hip, knee, ankle) is the textbook two-bone solve.
    /// A four-joint chain is a digitigrade leg (hip, knee, hock, toe): its
    /// last segment keeps the direction it has in `pose`, which fixes where
    /// the hock must be, and the hip, knee and hock are then solved as two
    /// bones. Either way the knee goes toward `pole`.
    ///
    /// FABRIK reaches the same targets, but on a chain longer than two bones
    /// it chooses among many shapes that all reach, starting from whatever
    /// the clip happened to show. Measured on the headset with the Synth's
    /// four-segment legs, that was a leg that changed shape between frames —
    /// crossing over the other, or lying nearly flat — and a gait that read as
    /// a series of snaps. This has exactly one answer for a given target and
    /// pole, so neighbouring frames give neighbouring legs.
    ///
    /// Any other length falls back to `solve`.
    @discardableResult
    public func solveLeg(chain: Chain,
                         target: SIMD3<Float>,
                         pole: SIMD3<Float>,
                         weight: Float = 1,
                         reachLimit: Float = 0.98,
                         pose: inout [JointPose],
                         model: inout [float4x4]) -> Report {
        let joints = chain.joints
        guard joints.count == 3 || joints.count == 4 else {
            return solve(chain: chain, target: target, pole: pole, bendTowardPole: true,
                         weight: weight, reachLimit: reachLimit, pose: &pose, model: &model)
        }
        guard joints.allSatisfy({ $0 < pose.count && $0 < model.count }) else { return .unsolved }
        let points = joints.map { Self.translation(of: model[$0]) }
        let hip = points[0]
        let thigh = simd_length(points[1] - points[0])
        let shin = simd_length(points[2] - points[1])
        // The digitigrade foot, held as the pose has it.
        let foot = joints.count == 4 ? points[3] - points[2] : .zero
        let ankleTarget = target - foot

        var toAnkle = ankleTarget - hip
        let wanted = simd_length(toAnkle)
        let longest = (thigh + shin) * reachLimit
        let shortest = abs(thigh - shin) * 1.02 + 1e-4
        let d = min(max(wanted, shortest), longest)
        toAnkle = wanted > 1e-6 ? toAnkle / wanted : SIMD3<Float>(0, -1, 0)

        // The bend plane holds the hip-to-ankle line and the pole. A pole
        // along that line says nothing; keep the knee where it was then.
        var side = pole - simd_dot(pole, toAnkle) * toAnkle
        if simd_length(side) < 1e-4 {
            let current = points[1] - hip
            side = current - simd_dot(current, toAnkle) * toAnkle
        }
        side = simd_length(side) > 1e-6 ? simd_normalize(side) : SIMD3<Float>(0, 0, 1)

        // Law of cosines: how far along the line the knee projects, and how
        // far off it toward the pole.
        let along = (thigh * thigh - shin * shin + d * d) / (2 * d)
        let off = sqrt(max(thigh * thigh - along * along, 0))
        let knee = hip + toAnkle * along + side * off
        let ankle = hip + toAnkle * d
        var positions = [hip, knee, ankle]
        if joints.count == 4 { positions.append(ankle + foot) }

        place(joints, at: positions, weight: weight, pose: &pose, model: &model)
        let tip = Self.translation(of: model[joints[joints.count - 1]])
        let error = simd_length(tip - target)
        return Report(error: error, reached: error < 0.002,
                      extended: wanted >= longest, outOfReach: wanted > thigh + shin,
                      folded: wanted < shortest, iterations: 1)
    }

    /// Turns each joint of `joints` so the next lands on `positions`.
    private func place(_ joints: [Int], at positions: [SIMD3<Float>], weight: Float,
                       pose: inout [JointPose], model: inout [float4x4]) {
        // Walk from the root of the chain down, turning each joint so its
        // child lands where the solution puts it. This order matters: rotating
        // a joint carries everything beneath it, so by the time a link is
        // reached its own position is already settled and only its orientation
        // is still owed.
        var parentMatrix = parents[joints[0]].flatMap { p in
            p >= 0 && p < model.count ? model[p] : nil
        } ?? matrix_identity_float4x4

        for step in 0..<(joints.count - 1) {
            let joint = joints[step]
            let child = joints[step + 1]
            var local = pose[joint]
            let here = parentMatrix * local.matrix
            let origin = Self.translation(of: here)
            let childNow = Self.translation(of: here * pose[child].matrix)
            let old = Self.normalized(childNow - origin)
            let new = Self.normalized(positions[step + 1] - origin)
            var turn = Self.rotation(from: old, to: new)
            if weight < 0.999 {
                turn = simd_slerp(simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                                  turn, max(weight, 0))
            }
            // `turn` is expressed in model space; a joint's stored rotation is
            // expressed in its parent's. Conjugating by the parent's rotation
            // is the change of basis between the two.
            let parentRotation = Self.rotation(of: parentMatrix)
            local.rotation = simd_normalize(
                parentRotation.inverse * turn * parentRotation * local.rotation)
            pose[joint] = local
            parentMatrix = parentMatrix * local.matrix
            model[joint] = parentMatrix
        }
        // The tip carries no child in this chain, so its orientation is
        // whatever its parent handed it; only its model matrix is refreshed.
        model[joints[joints.count - 1]] = parentMatrix * pose[joints[joints.count - 1]].matrix
    }

    // MARK: - Geometry

    public static func translation(of m: float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Rotation carried by a transform matrix, with scale divided out.
    /// Skeletons are uniformly scaled; a non-uniformly scaled joint would need
    /// a polar decomposition and does not occur here.
    public static func rotation(of m: float4x4) -> simd_quatf {
        func axis(_ c: SIMD4<Float>) -> SIMD3<Float> {
            let v = SIMD3<Float>(c.x, c.y, c.z)
            let length = simd_length(v)
            return length > 1e-7 ? v / length : SIMD3<Float>(0, 0, 1)
        }
        return simd_normalize(simd_quatf(float3x3(axis(m.columns.0),
                                                  axis(m.columns.1),
                                                  axis(m.columns.2))))
    }

    static func normalized(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(v)
        return length > 1e-7 ? v / length : SIMD3<Float>(0, -1, 0)
    }

    /// Shortest rotation taking `a` onto `b`, defined for every input.
    ///
    /// `simd_quatf(from:to:)` is undefined when the two are exactly opposed,
    /// and that is not a corner case here — a chain straightened out and
    /// reaching back the way it came produces it.
    public static func rotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let dot = simd_dot(a, b)
        if dot > 0.999999 { return identity }
        if dot < -0.999999 {
            var perpendicular = simd_cross(a, SIMD3<Float>(1, 0, 0))
            if simd_length(perpendicular) < 1e-4 {
                perpendicular = simd_cross(a, SIMD3<Float>(0, 1, 0))
            }
            return simd_quatf(angle: .pi, axis: simd_normalize(perpendicular))
        }
        return simd_normalize(simd_quatf(from: a, to: b))
    }
}
