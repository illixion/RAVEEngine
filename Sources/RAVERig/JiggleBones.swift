import Foundation
import simd

// MARK: - What a character asks for

/// One part of a character's body that should jiggle, as the character asks
/// for it: which joint, how it moves, and how it feels.
///
/// Nothing jiggles unless a character asks. Which joints carry flesh, hair or
/// a strap is a fact about one model, not something a rig reveals: a bone
/// called `breast_L` may be a deform bone, a helper or a control, and a soft
/// part may be weighted to a bone with no telling name at all. So the
/// character's own data names its joints, and this type says what to do with
/// each.
///
/// Feel is given the way it is judged, not the way it is integrated: a
/// natural frequency in hertz (how fast it bounces) and a damping ratio (how
/// soon it stops). A stiffness and a drag coefficient mean nothing until
/// they are tried; "2 Hz, settles in about two bounces" means the same thing
/// on every character and at every frame rate.
///
/// Sizes are metres on the character at its natural size. The solver is
/// handed how much bigger or smaller the character is drawn, and scales
/// lengths and gravity with it, so a character shrunk onto a desk jiggles
/// like the same character, not like a much larger one seen from far away.
public struct JiggleSpec: Sendable, Equatable {

    public enum Motion: String, Sendable, Codable, CaseIterable {
        /// The joint swings about its own head: the far end lags, overshoots
        /// and settles. A breast, an ear, a strand of hair, a tail. Needs a
        /// far end: a child joint, or `tip`.
        case swing
        /// The joint itself lags behind where the animation puts it and
        /// springs back, without turning. Flesh with no direction of its own
        /// to swing along: a buttock, a belly, a cheek. Works on a leaf
        /// joint.
        case spring
    }

    /// The joint that moves. Matched against the skeleton's joint names by
    /// their last path component: exactly, else as a unique suffix, so
    /// `Breast_L` still finds `PCP_Breast_L` in a prefixed release.
    public var joint: String
    /// Joints that copy this one's motion rather than being simulated on
    /// their own: a second bone weighted to the same flesh. A model whose
    /// breast is split across two parallel bones tears at the seam if only
    /// one of them moves.
    public var linked: [String]
    public var motion: Motion
    /// How many joints, from `joint` down through each joint's main child,
    /// swing as a chain. One is `joint` alone. Each link is its own spring,
    /// pulled toward where its parent's motion carries it, so a chain whips.
    public var chainLength: Int
    /// Natural frequency, hertz: bounces per second.
    public var frequency: Float
    /// Damping ratio: 0 rings for ever, 1 returns without overshooting.
    /// Around 0.2 bounces two or three times.
    public var damping: Float
    /// How much of gravity the moving end feels. The rest pose is usually
    /// already modelled hanging, so this is the extra sag when the body
    /// tips or the part is flung upward, and is small for flesh.
    public var gravity: Float
    /// Swing only: the most the joint may turn away from where the
    /// animation points it, degrees.
    public var maxAngle: Float
    /// Spring only: the most the joint may lag behind where the animation
    /// puts it, metres.
    public var maxOffset: Float
    /// How much the body's own travel carries the part rigidly with it,
    /// 0...1. At 0 every step, turn and lean is felt; at 1 only the
    /// animation of the skeleton is, and walking across the room moves
    /// nothing. VRChat calls the same idea "immobile".
    public var carry: Float
    /// Size of the moving end, metres, for keeping it out of hands.
    public var radius: Float
    /// Swing only: where the far end sits, in the joint's own space and
    /// units. Nil takes the joint's child. Needed for a swing on a leaf.
    public var tip: SIMD3<Float>?
    /// How much of the simulated motion is shown, 0...1.
    public var weight: Float
    /// Chains only: the last link's frequency as a fraction of the first's,
    /// eased in along the chain. Below one the tip is looser than the root,
    /// as hair and tails are.
    public var tipFrequencyScale: Float

    public init(_ motion: Motion, joint: String, linked: [String] = [], chainLength: Int = 1,
                frequency: Float = 2.5, damping: Float = 0.25, gravity: Float = 0.2,
                maxAngle: Float = 25, maxOffset: Float = 0.03, carry: Float = 0,
                radius: Float = 0.04, tip: SIMD3<Float>? = nil, weight: Float = 1,
                tipFrequencyScale: Float = 1) {
        self.joint = joint
        self.linked = linked
        self.motion = motion
        self.chainLength = max(1, chainLength)
        self.frequency = frequency
        self.damping = damping
        self.gravity = gravity
        self.maxAngle = maxAngle
        self.maxOffset = maxOffset
        self.carry = carry
        self.radius = radius
        self.tip = tip
        self.weight = weight
        self.tipFrequencyScale = tipFrequencyScale
    }

    // MARK: Presets

    /// A breast: a soft swing, bouncing about twice a second and settling
    /// in two or three.
    public static func breast(_ joint: String, linked: [String] = []) -> JiggleSpec {
        JiggleSpec(.swing, joint: joint, linked: linked, frequency: 2.2, damping: 0.2, gravity: 0.15,
                   maxAngle: 20, radius: 0.05)
    }

    /// A buttock: a spring that lags a couple of centimetres at most.
    public static func butt(_ joint: String, linked: [String] = []) -> JiggleSpec {
        JiggleSpec(.spring, joint: joint, linked: linked, frequency: 2.8, damping: 0.25, gravity: 0.1,
                   maxOffset: 0.02, radius: 0.06)
    }

    /// A belly: a slower, better damped spring.
    public static func belly(_ joint: String, linked: [String] = []) -> JiggleSpec {
        JiggleSpec(.spring, joint: joint, linked: linked, frequency: 2.2, damping: 0.3, gravity: 0.1,
                   maxOffset: 0.02, radius: 0.08)
    }

    /// An ear: quick and well damped, a flick rather than a flop.
    public static func ear(_ joint: String, chainLength: Int = 1) -> JiggleSpec {
        JiggleSpec(.swing, joint: joint, chainLength: chainLength, frequency: 3.5, damping: 0.35,
                   gravity: 0.1, maxAngle: 25, radius: 0.03)
    }

    /// Hair or a fur tuft: slow, heavy and looser toward the tip.
    public static func hair(_ joint: String, chainLength: Int = 1) -> JiggleSpec {
        JiggleSpec(.swing, joint: joint, chainLength: chainLength, frequency: 1.6, damping: 0.3,
                   gravity: 0.5, maxAngle: 45, radius: 0.02, tipFrequencyScale: 0.7)
    }

    /// A tail carried by its own muscle: it droops a little, trails the
    /// body and swings after a turn.
    public static func tail(_ joint: String, chainLength: Int) -> JiggleSpec {
        JiggleSpec(.swing, joint: joint, chainLength: chainLength, frequency: 1.4, damping: 0.35,
                   gravity: 0.25, maxAngle: 30, radius: 0.04, tipFrequencyScale: 0.8)
    }

    /// The same part on the other side of the body.
    public func mirrored(_ joint: String, linked: [String] = []) -> JiggleSpec {
        var copy = self
        copy.joint = joint
        copy.linked = linked
        return copy
    }
}

extension JiggleSpec: Codable {
    private enum CodingKeys: String, CodingKey {
        case joint, linked, motion, chainLength, frequency, damping, gravity, maxAngle, maxOffset
        case carry, radius, tip, weight, tipFrequencyScale
    }

    /// Everything but `joint` is optional, defaulting as the initialiser
    /// does, so a character's file only says what it changes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = JiggleSpec(try c.decodeIfPresent(Motion.self, forKey: .motion) ?? .swing,
                              joint: try c.decode(String.self, forKey: .joint))
        self = base
        linked = try c.decodeIfPresent([String].self, forKey: .linked) ?? base.linked
        chainLength = max(1, try c.decodeIfPresent(Int.self, forKey: .chainLength) ?? base.chainLength)
        frequency = try c.decodeIfPresent(Float.self, forKey: .frequency) ?? base.frequency
        damping = try c.decodeIfPresent(Float.self, forKey: .damping) ?? base.damping
        gravity = try c.decodeIfPresent(Float.self, forKey: .gravity) ?? base.gravity
        maxAngle = try c.decodeIfPresent(Float.self, forKey: .maxAngle) ?? base.maxAngle
        maxOffset = try c.decodeIfPresent(Float.self, forKey: .maxOffset) ?? base.maxOffset
        carry = try c.decodeIfPresent(Float.self, forKey: .carry) ?? base.carry
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? base.radius
        tip = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .tip)
        weight = try c.decodeIfPresent(Float.self, forKey: .weight) ?? base.weight
        tipFrequencyScale = try c.decodeIfPresent(Float.self, forKey: .tipFrequencyScale) ?? base.tipFrequencyScale
    }
}

// MARK: - The solver

/// Secondary motion for the soft and loose parts of a skeleton: flesh that
/// bounces, ears that flick, hair and tails that trail.
///
/// Each part is one point mass on a damped spring. A swinging part's mass
/// sits at the far end of its joint and is held at the joint's length from
/// its head, so it can only swing; a springing part's mass is the joint's
/// head itself and may only lag a short way. Every frame the animation says
/// where the mass would be on a rigid body; the spring pulls it there, the
/// body's motion leaves it behind, gravity tugs it, and what comes out is a
/// turn (swing) or a shift (spring) laid onto that joint's pose.
///
/// The spring is measured against the animated target's own motion, not
/// against the room: a part carried along at a steady walk does not trail
/// in the wind, it only responds when the body speeds up, stops or turns,
/// which is what flesh does. The integration is substepped well under the
/// frame time, so a 90 Hz and a 45 Hz frame give the same bounce.
///
/// Parts run parent first, each against the pose its parents have already
/// been moved to, so a chain is a series of springs that whip, and a part
/// under another part rides on it.
///
/// Pure arithmetic over `JointPose`, like the rest of this target: RealityKit
/// hosts write the result to their skeleton, GoldSrc hosts to a bone
/// palette, and the tests run on the Mac in milliseconds. Gravity is along
/// `-Y` of world space, so the world the caller hands in had better be Y-up.
public struct JiggleBones: Sendable {

    /// Changes that apply to every part at once, for tuning by feel.
    public struct Tuning: Sendable, Equatable {
        /// How much of the simulated motion is shown. Above one exaggerates.
        public var amount: Float = 1
        public var frequencyScale: Float = 1
        public var dampingScale: Float = 1
        public var gravityScale: Float = 1
        public init() {}
    }

    /// One simulated part, resolved onto the skeleton.
    public struct Part: Sendable {
        /// The joint the spec named, or the chain link, by its leaf name.
        public let name: String
        public let motion: JiggleSpec.Motion
        /// Joints moved, the simulated one first, then the ones linked to it.
        public let joints: [Int]
        /// For each of `joints`, the child its swing aims, when it has one.
        /// What an IK host constrains instead of writing the turn.
        public let tipChildren: [Int?]
        /// The far end in the simulated joint's own space, when no child
        /// marks it (a `tip`, or a chain's last link continued).
        let tipLocal: SIMD3<Float>?
        let frequency: Float
        let damping: Float
        let gravity: Float
        let maxAngle: Float
        let maxOffset: Float
        let carry: Float
        let radius: Float
        let weight: Float
        /// A link below the first of a chain. Its spring pulls toward where
        /// the animation alone would put it, not toward the continuation of
        /// its parent's simulated direction; see `apply`.
        let chainLink: Bool
        /// Every joint whose model matrix this part's motion changes, in
        /// traversal order: its joints and all below them.
        let refresh: [Int]

        var position: SIMD3<Float> = .zero
        var velocity: SIMD3<Float> = .zero
        /// Where the spring pulls, last frame: the target, or for a chain
        /// link the animated position.
        var lastPull: SIMD3<Float> = .zero
        var lastTarget: SIMD3<Float> = .zero
        var lastAnchor: SIMD3<Float> = .zero
        var started = false

        /// Last frame's deflection: degrees for a swing, metres at natural
        /// size for a spring.
        public internal(set) var deflection: Float = 0
    }

    /// A requested joint that could not be used, and why.
    public struct Unresolved: Sendable, Equatable {
        public var joint: String
        public var reason: String
    }

    public let parents: [Int?]
    public let jointNames: [String]
    public private(set) var parts: [Part]
    public private(set) var unresolved: [Unresolved]
    public var tuning = Tuning()
    /// Integration step, seconds. Stable for any frequency here while
    /// `2π × frequency × substep` stays well under one.
    public var substep: Float = 1.0 / 240
    /// Metres at natural size: a target that moved further than this in a
    /// frame was teleported, and the part is put down where it now is
    /// rather than flung across the room.
    public var teleportDistance: Float = 0.5
    public var worldGravity = SIMD3<Float>(0, -9.81, 0)

    private let order: [Int]
    private var lastModelToWorld: float4x4?
    /// Frames advanced, for diagnostics.
    public private(set) var frames = 0

    public var isEmpty: Bool { parts.isEmpty }

    /// Resolves `specs` onto a skeleton.
    ///
    /// - Parameters:
    ///   - jointNames: the skeleton's joints, full paths or leaf names.
    ///   - parents: parent index per joint, nil for a root
    ///     (`PoseSolver.parents(fromPaths:)` for path names).
    ///   - rest: a pose to measure bone directions and lengths from; the
    ///     bind pose, or the first animated frame.
    public init(specs: [JiggleSpec], jointNames: [String], parents: [Int?], rest: [JointPose]) {
        self.parents = parents
        self.jointNames = jointNames
        let order = PoseSolver.traversalOrder(parents: parents)
        self.order = order
        var rank = [Int](repeating: 0, count: parents.count)
        for (position, joint) in order.enumerated() { rank[joint] = position }
        var children = [[Int]](repeating: [], count: parents.count)
        for (i, parent) in parents.enumerated() {
            if let parent, parent >= 0, parent < parents.count, parent != i { children[parent].append(i) }
        }
        let model = PoseSolver(parents: parents).modelMatrices(of: rest)
        func head(_ i: Int) -> SIMD3<Float> {
            i < model.count ? PoseSolver.translation(of: model[i]) : .zero
        }
        var descendantCount = [Int](repeating: 0, count: parents.count)
        for joint in order.reversed() {
            descendantCount[joint] = children[joint].reduce(0) { $0 + 1 + descendantCount[$1] }
        }
        // The child a swing aims at: the one continuing the limb. A joint
        // sitting on its parent's head (a zero-length helper) marks no
        // direction; of several, the one carrying the most skeleton below it
        // is the limb and the others are side branches.
        func mainChild(_ joint: Int) -> Int? {
            let candidates = children[joint].filter { simd_distance(head($0), head(joint)) > 1e-5 }
            return candidates.max { a, b in
                descendantCount[a] != descendantCount[b] ? descendantCount[a] < descendantCount[b]
                    : simd_distance(head(a), head(joint)) < simd_distance(head(b), head(joint))
            }
        }

        let leaves = jointNames.map { name in name.split(separator: "/").last.map(String.init) ?? name }
        var unresolved: [Unresolved] = []
        func find(_ wanted: String) -> Int? {
            let leaf = wanted.split(separator: "/").last.map(String.init) ?? wanted
            if let exact = leaves.firstIndex(of: leaf) { return exact }
            let suffixed = leaves.indices.filter { leaves[$0].hasSuffix(leaf) }
            if suffixed.count == 1 { return suffixed[0] }
            unresolved.append(Unresolved(joint: wanted, reason: suffixed.isEmpty
                ? "no joint named \(leaf)"
                : "\(suffixed.count) joints end with \(leaf); name one exactly"))
            return nil
        }
        func subtree(of roots: [Int]) -> [Int] {
            var marked = Set<Int>()
            var stack = roots
            while let next = stack.popLast() {
                guard marked.insert(next).inserted else { continue }
                stack.append(contentsOf: children[next])
            }
            return marked.sorted { rank[$0] < rank[$1] }
        }

        var parts: [Part] = []
        var claimed = Set<Int>()
        for spec in specs {
            guard let first = find(spec.joint) else { continue }
            // A chain: the joint and its main children, one part per link.
            var links = [first]
            while links.count < spec.chainLength, let next = mainChild(links[links.count - 1]) {
                links.append(next)
            }
            if spec.chainLength > 1, links.count < spec.chainLength {
                unresolved.append(Unresolved(joint: spec.joint,
                    reason: "chain ends after \(links.count) of \(spec.chainLength) joints"))
            }
            let linked = links.count == 1 ? spec.linked.compactMap(find) : []
            for (k, link) in links.enumerated() {
                guard !claimed.contains(link) else {
                    unresolved.append(Unresolved(joint: leaves[link], reason: "already jiggled by another spec"))
                    continue
                }
                let moved = [link] + linked.filter { $0 != link && !claimed.contains($0) }
                var tipLocal: SIMD3<Float>?
                var tipChild: Int?
                if spec.motion == .swing {
                    if let tip = spec.tip, k == 0 {
                        tipLocal = tip
                    } else if let child = mainChild(link) {
                        tipChild = child
                    } else if k > 0 {
                        // A chain's last link carries on the way the chain
                        // was going, one link further.
                        let previous = links[k - 1]
                        let direction = head(link) - head(previous)
                        if simd_length(direction) > 1e-5, link < model.count {
                            tipLocal = PoseSolver.translation(
                                of: model[link].inverse * float4x4(translation: head(link) + direction))
                        }
                    }
                    guard tipChild != nil || tipLocal != nil else {
                        unresolved.append(Unresolved(joint: leaves[link], reason: k == 0
                            ? "a leaf joint has no far end to swing; give it a tip, or use spring"
                            : "chain's last joint has no direction to continue"))
                        continue
                    }
                }
                let along = links.count > 1 ? Float(k) / Float(links.count - 1) : 0
                let frequency = spec.frequency * (1 + (spec.tipFrequencyScale - 1) * along * along)
                parts.append(Part(
                    name: leaves[link], motion: spec.motion, joints: moved,
                    tipChildren: moved.map { $0 == link ? tipChild : (spec.motion == .swing ? mainChild($0) : nil) },
                    tipLocal: tipLocal, frequency: max(0.05, frequency), damping: max(0, spec.damping),
                    gravity: spec.gravity, maxAngle: max(0, spec.maxAngle) * .pi / 180,
                    maxOffset: max(0, spec.maxOffset), carry: min(max(spec.carry, 0), 1),
                    radius: max(0, spec.radius), weight: min(max(spec.weight, 0), 1),
                    chainLink: k > 0, refresh: subtree(of: moved)))
                claimed.formUnion(moved)
            }
        }
        // Parents first, so every part sees its parents already moved.
        parts.sort { rank[$0.joints[0]] < rank[$1.joints[0]] }
        self.parts = parts
        self.unresolved = unresolved
    }

    /// Resolves `specs` onto an analysed rig, which knows its joints' rest
    /// positions but not their rotations. Enough to say which joints a
    /// request names and which children their swings aim at, before any
    /// pose exists: what an IK host needs to build its constraints. Joint
    /// indices are the rig's; names are its leaf names.
    public init(specs: [JiggleSpec], rig: RigSkeleton) {
        let rest = rig.joints.map { joint in
            JointPose(translation: joint.parent.map { joint.restHead - rig.joints[$0].restHead } ?? joint.restHead)
        }
        self.init(specs: specs, jointNames: rig.joints.map(\.name), parents: rig.joints.map(\.parent), rest: rest)
    }

    /// Puts every part down where the animation has it, at rest.
    public mutating func reset() {
        for i in parts.indices {
            parts[i].started = false
            parts[i].deflection = 0
        }
        lastModelToWorld = nil
    }

    /// Gives every part a shove, world metres per second: a test that the
    /// springs answer, and what they look like settling.
    public mutating func kick(_ velocity: SIMD3<Float>) {
        for i in parts.indices where parts[i].started {
            parts[i].velocity += velocity
        }
    }

    /// Lays this frame's secondary motion onto `pose`.
    ///
    /// - Parameters:
    ///   - pose: the animated pose, parent-relative, in the skeleton's order.
    ///     Changed in place: swinging joints turn, springing joints shift.
    ///   - modelToWorld: the skeleton's model space to the world, this frame.
    ///     Where the body is and how it is moving comes from here.
    ///   - deltaTime: seconds since the last frame.
    ///   - sizeScale: how much larger than its natural size the character is
    ///     drawn. Lengths, offsets and gravity scale with it.
    ///   - obstacles: spheres in world space the moving ends are kept out of:
    ///     the wearer's hands.
    public mutating func apply(to pose: inout [JointPose], modelToWorld: float4x4, deltaTime: Float,
                               sizeScale: Float = 1, obstacles: [ChainDynamics.Sphere] = []) {
        guard !parts.isEmpty, pose.count == parents.count else { return }
        frames += 1
        // A hitch this long is a pause, not a motion: start over from here.
        if deltaTime > 0.25 { reset() }
        let dt = min(max(deltaTime, 0), 0.1)
        let size = max(sizeScale, 1e-3)
        let worldRotation = PoseSolver.rotation(of: modelToWorld)
        let worldToModel = modelToWorld.inverse
        // How the body moved since last frame, for `carry`.
        let bodyDelta = lastModelToWorld.map { modelToWorld * $0.inverse }
        lastModelToWorld = modelToWorld

        var model = PoseSolver(parents: parents).modelMatrices(of: pose)
        // The pose as animated, before any part moved it: where a chain
        // link's spring pulls.
        let animated = model
        func world(_ m: SIMD3<Float>) -> SIMD3<Float> {
            let w = modelToWorld * SIMD4<Float>(m, 1)
            return SIMD3(w.x, w.y, w.z)
        }

        for p in parts.indices {
            var part = parts[p]
            let joint = part.joints[0]
            let jointModel = model[joint]
            let anchor = world(PoseSolver.translation(of: jointModel))
            let target: SIMD3<Float>
            // A chain link is pulled toward where the animation alone puts
            // it, as `ChainDynamics` pulls a tail, and is tied to its parent
            // only by its length and its cone. Pulled along its parent's
            // simulated direction instead, every link was driven by the one
            // above with no reaction back, and links shortening toward the
            // tip amplified it down the chain: a tail's last links swung
            // against their limits for seconds after its base had settled.
            let pull: SIMD3<Float>
            switch part.motion {
            case .spring:
                target = anchor
                pull = target
            case .swing:
                let local = part.tipChildren[0].map { pose[$0].translation } ?? part.tipLocal ?? .zero
                let tip = jointModel * SIMD4<Float>(local, 1)
                target = world(SIMD3(tip.x, tip.y, tip.z))
                if part.chainLink {
                    let rigid = animated[joint] * SIMD4<Float>(local, 1)
                    pull = world(SIMD3(rigid.x, rigid.y, rigid.z))
                } else {
                    pull = target
                }
            }
            if part.started, part.carry > 0, let delta = bodyDelta {
                // That share of the body's motion moves the part's whole
                // frame of reference, its target's last position included,
                // so the spring never hears about it.
                func carried(_ x: SIMD3<Float>) -> SIMD3<Float> {
                    let moved = delta * SIMD4<Float>(x, 1)
                    return x + (SIMD3(moved.x, moved.y, moved.z) - x) * part.carry
                }
                part.position = carried(part.position)
                part.lastPull = carried(part.lastPull)
                part.lastTarget = carried(part.lastTarget)
                part.lastAnchor = carried(part.lastAnchor)
                let turned = PoseSolver.rotation(of: delta).act(part.velocity)
                part.velocity += (turned - part.velocity) * part.carry
            }
            let teleported = simd_distance(target, part.lastTarget) > teleportDistance * size
            if !part.started || teleported || !part.position.allFinite || !part.velocity.allFinite {
                // Put down already hanging as gravity would leave it. Put down
                // rigid, it would fall and bounce first: a tail dropped from
                // straight out whipped to its limit on every reset.
                part.position = settled(part, pull: pull, target: target, anchor: anchor, size: size)
                part.velocity = .zero
                part.lastPull = pull
                part.lastTarget = target
                part.lastAnchor = anchor
                part.started = true
            }

            if dt > 0 {
                step(&part, pull: pull, target: target, anchor: anchor, deltaTime: dt, size: size,
                     obstacles: obstacles)
            }
            part.lastPull = pull
            part.lastTarget = target
            part.lastAnchor = anchor

            // What the simulation came to, as a pose.
            let shown = part.weight * tuning.amount
            switch part.motion {
            case .swing:
                let from = target - anchor, to = part.position - anchor
                guard simd_length(from) > 1e-7, simd_length(to) > 1e-7 else { break }
                let turn = PoseSolver.rotation(from: simd_normalize(from), to: simd_normalize(to))
                part.deflection = turn.angle * 180 / .pi
                guard shown > 1e-4, turn.angle > 1e-6 else { break }
                let worldTurn = simd_quatf(angle: turn.angle * shown, axis: turn.axis)
                let modelTurn = simd_normalize(worldRotation.inverse * worldTurn * worldRotation)
                for j in part.joints {
                    let parentRotation = parents[j].map { PoseSolver.rotation(of: model[$0]) }
                        ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                    let turned = modelTurn * PoseSolver.rotation(of: model[j])
                    pose[j].rotation = simd_normalize(parentRotation.inverse * turned)
                }
            case .spring:
                let offset = part.position - target
                part.deflection = simd_length(offset) / size
                guard shown > 1e-4, simd_length(offset) > 1e-7 else { break }
                let modelOffset = worldToModel * SIMD4<Float>(offset * shown, 0)
                for j in part.joints {
                    // Into the parent's space, where a joint's translation lives.
                    let parentInverse = parents[j].map { model[$0].inverse } ?? matrix_identity_float4x4
                    let local = parentInverse * modelOffset
                    pose[j].translation += SIMD3(local.x, local.y, local.z)
                }
            }
            parts[p] = part
            // Everything below sees this part's motion.
            for i in part.refresh {
                if let parent = parents[i], parent >= 0, parent < model.count, parent != i {
                    model[i] = model[parent] * pose[i].matrix
                } else {
                    model[i] = pose[i].matrix
                }
            }
        }
    }

    /// Where a part at rest comes to under gravity: its target, sagged by
    /// gravity over the spring's stiffness, inside its limits.
    private func settled(_ part: Part, pull: SIMD3<Float>, target: SIMD3<Float>, anchor: SIMD3<Float>,
                         size: Float) -> SIMD3<Float> {
        let omega = 2 * Float.pi * part.frequency * tuning.frequencyScale
        let sag = worldGravity * (part.gravity * tuning.gravityScale * size) / max(omega * omega, 1e-4)
        let free = pull + sag
        switch part.motion {
        case .swing:
            let rest = target - anchor
            let length = simd_length(rest)
            guard length > 1e-7 else { return target }
            var direction = free - anchor
            let distance = simd_length(direction)
            guard distance > 1e-7 else { return target }
            direction = ChainDynamics.limited(direction / distance, toward: rest / length, maxBend: part.maxAngle)
            return anchor + direction * length
        case .spring:
            let offset = free - target
            let reach = part.maxOffset * size
            let distance = simd_length(offset)
            return distance > reach ? target + (reach > 0 ? offset * (reach / distance) : .zero) : free
        }
    }

    /// One frame of one part, substepped, with the target and anchor moving
    /// in a straight line from last frame's to this frame's.
    private func step(_ part: inout Part, pull: SIMD3<Float>, target: SIMD3<Float>, anchor: SIMD3<Float>,
                      deltaTime: Float, size: Float, obstacles: [ChainDynamics.Sphere]) {
        let steps = max(1, Int((deltaTime / substep).rounded(.up)))
        let h = deltaTime / Float(steps)
        let omega = 2 * Float.pi * part.frequency * tuning.frequencyScale
        let stiffness = omega * omega
        let damping = 2 * part.damping * tuning.dampingScale * omega
        let gravity = worldGravity * (part.gravity * tuning.gravityScale * size)
        let length = simd_distance(target, anchor)
        let reach = part.maxOffset * size
        let radius = part.radius * size
        // The pull moves in a straight line across the frame, so its
        // velocity is the same in every substep.
        let goalVelocity = (pull - part.lastPull) / deltaTime
        var velocity = part.velocity
        for s in 1...steps {
            // The force is taken where the target is at the start of the
            // substep, which is where the position is; the constraints apply
            // where both are at its end. Taking the force against the end
            // left a part on a steady walk one substep ahead of its target.
            let before = Float(s - 1) / Float(steps), t = Float(s) / Float(steps)
            let spring = simd_mix(part.lastPull, pull, SIMD3(repeating: before))
            let goal = simd_mix(part.lastTarget, target, SIMD3(repeating: t))
            let pivot = simd_mix(part.lastAnchor, anchor, SIMD3(repeating: t))
            // Damped against the target's own motion: a part carried along
            // steadily is at rest relative to it.
            let acceleration = (spring - part.position) * stiffness
                - (velocity - goalVelocity) * damping + gravity
            velocity += acceleration * h
            var next = part.position + velocity * h

            for sphere in obstacles {
                let away = next - sphere.center
                let distance = simd_length(away)
                let clearance = sphere.radius + radius
                guard distance < clearance else { continue }
                let outward = distance > 1e-6 ? away / distance : SIMD3<Float>(0, 1, 0)
                next = sphere.center + outward * clearance
            }

            switch part.motion {
            case .swing:
                // Held at the joint's length, inside its cone.
                var direction = next - pivot
                let distance = simd_length(direction)
                let rest = goal - pivot
                let restLength = simd_length(rest)
                guard restLength > 1e-7 else { next = goal; break }
                let along = rest / restLength
                direction = distance > 1e-7 ? direction / distance : along
                direction = ChainDynamics.limited(direction, toward: along, maxBend: part.maxAngle)
                next = pivot + direction * (length > 1e-7 ? length : restLength)
            case .spring:
                let offset = next - goal
                let distance = simd_length(offset)
                if distance > reach {
                    next = goal + (reach > 0 ? offset * (reach / distance) : .zero)
                }
            }
            // What the constraints took away is taken from the velocity
            // too, so a part held at its limit does not store speed there.
            velocity = (next - part.position) / h
            part.position = next
        }
        part.velocity = velocity
    }

    /// Joints an IK host constrains instead of writing the turns: the child
    /// each swinging joint aims, in `parts` order. Springs and swings with
    /// no child are not here, since a constraint on a joint's own position
    /// can only move it by turning its parent.
    public var constrainedJoints: [Int] {
        parts.flatMap { part in part.motion == .swing ? part.tipChildren.compactMap { $0 } : [] }
    }

    /// Where each of `constrainedJoints` sits in `pose`, model space: the
    /// targets for an IK host, read off a pose `apply` has moved.
    public func constraintTargets(in pose: [JointPose]) -> [SIMD3<Float>] {
        guard pose.count == parents.count else { return [] }
        let model = PoseSolver(parents: parents).modelMatrices(of: pose)
        return constrainedJoints.map { PoseSolver.translation(of: model[$0]) }
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t, 1)
    }
}
