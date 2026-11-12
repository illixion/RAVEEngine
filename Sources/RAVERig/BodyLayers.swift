import Foundation
import simd

/// The procedural layers a character's body gets on top of whatever poses
/// it: the head turning to look, the tail carried and swung as a weighted
/// chain, and the soft parts (`JiggleBones`).
///
/// One stack for every body. A host hands it the pose it is about to write
/// (from a clip, from a performer's tracking, from a physics body), where
/// the skeleton stands in the world, what to look at and where the wearer's
/// hands are; it lays the layers on that pose in place. Because the layers
/// live here rather than in the code that draws one kind of body, a
/// character looks, wags and jiggles the same wherever it appears.
///
/// Order: look, then tail, then soft parts, so hair on a turned head and
/// flesh on a moved body answer the pose they end up on.
///
/// World space is Y-up, in metres. Pure arithmetic: no framework, so the
/// same code poses a RealityKit skeleton and a GoldSrc bone palette.
public struct BodyLayers: Sendable {

    /// What the layers need to know about a skeleton, by joint name (full
    /// path or leaf), so a rig analysed in one joint order and a pose
    /// published in another agree.
    public struct Rig: Sendable, Equatable {
        public var head: String?
        /// Neck joints between the chest and the head, lowest first.
        public var neck: [String]
        /// The tail, base first, each joint the parent of the next. Empty for
        /// a character with none.
        public var tail: [String]
        /// The way the character faces, in the skeleton's model space.
        public var forward: SIMD3<Float>
        /// Up, in the skeleton's model space (a Blender export's is +Z).
        public var up: SIMD3<Float>

        public init(head: String? = nil, neck: [String] = [], tail: [String] = [],
                    forward: SIMD3<Float> = SIMD3(0, 0, 1), up: SIMD3<Float> = SIMD3(0, 1, 0)) {
            self.head = head
            self.neck = neck
            self.tail = tail
            self.forward = forward
            self.up = up
        }

        /// From an analysed rig: the head and neck landmarks, and the tail
        /// `TailArchitecture` finds.
        public init(landmarks: HumanoidLandmarks, rig: RigSkeleton,
                    forward: SIMD3<Float> = SIMD3(0, 0, 1), up: SIMD3<Float> = SIMD3(0, 1, 0)) {
            head = rig.joints[landmarks.head].name
            neck = landmarks.neck.map { [rig.joints[$0].name] } ?? []
            tail = TailArchitecture.find(landmarks: landmarks, rig: rig)?.chain.map { rig.joints[$0].name } ?? []
            self.forward = forward
            self.up = up
        }
    }

    /// One frame's surroundings.
    public struct Frame: Sendable {
        /// The skeleton's model space to the world, scale included.
        public var modelToWorld: float4x4
        public var deltaTime: Float
        /// How much larger than natural size the character is drawn.
        public var sizeScale: Float
        /// The point to look at, world space. Nil lets the head go back to
        /// the pose it was given.
        public var lookAt: SIMD3<Float>?
        /// Height nothing may sink below, when there is a floor.
        public var floor: Float?
        /// The wearer's hands, as spheres in world space.
        public var obstacles: [ChainDynamics.Sphere]

        public init(modelToWorld: float4x4, deltaTime: Float, sizeScale: Float = 1,
                    lookAt: SIMD3<Float>? = nil, floor: Float? = nil,
                    obstacles: [ChainDynamics.Sphere] = []) {
            self.modelToWorld = modelToWorld
            self.deltaTime = deltaTime
            self.sizeScale = sizeScale
            self.lookAt = lookAt
            self.floor = floor
            self.obstacles = obstacles
        }
    }

    public let jointNames: [String]
    public let solver: PoseSolver
    /// Nil when the rig names no head on this skeleton.
    public var look: LookLayer?
    /// Nil when the character has no tail.
    public var tail: TailLayer?
    /// Nil when nothing was asked for.
    public var jiggle: JiggleBones?
    /// Off holds the soft parts on the pose they are given.
    public var jiggleEnabled = true
    /// Whether hands push the soft parts.
    public var jiggleTouch = true
    /// Jiggle requests left to the tail layer, because they name its joints.
    public private(set) var jiggleOnTail: [String] = []

    /// - Parameters:
    ///   - jointNames: the pose's joints, in the pose's order.
    ///   - parents: parent index per joint (`PoseSolver.parents(fromPaths:)`).
    ///   - rest: the bind pose, or the first frame: where directions and
    ///     lengths are measured.
    ///   - jiggle: the soft parts the character asks for. A request on a
    ///     joint of the tail is the tail layer's, which carries, swings and
    ///     simulates the whole chain.
    public init(jointNames: [String], parents: [Int?], rest: [JointPose], rig: Rig, jiggle: [JiggleSpec] = []) {
        self.jointNames = jointNames
        solver = PoseSolver(parents: parents)
        let leaves = jointNames.map(Self.leaf)
        func find(_ name: String) -> Int? { leaves.firstIndex(of: Self.leaf(name)) }

        if let head = rig.head.flatMap(find) {
            look = LookLayer(head: head, neck: rig.neck.compactMap(find), solver: solver, rest: rest,
                             forward: rig.forward, up: rig.up)
        }
        let chain = rig.tail.compactMap(find)
        if chain.count == rig.tail.count {
            tail = TailLayer(chain: chain, solver: solver)
        }
        var specs = jiggle
        if tail != nil {
            let onTail = Set(chain.map { leaves[$0] })
            specs.removeAll { spec in
                let taken = onTail.contains(Self.leaf(spec.joint))
                if taken { jiggleOnTail.append(spec.joint) }
                return taken
            }
        }
        if !specs.isEmpty {
            self.jiggle = JiggleBones(specs: specs, jointNames: jointNames, parents: parents, rest: rest)
        }
    }

    /// Lays this frame's layers onto `pose`.
    public mutating func apply(to pose: inout [JointPose], frame: Frame) {
        guard pose.count == solver.parents.count else { return }
        look?.apply(to: &pose, solver: solver, modelToWorld: frame.modelToWorld,
                    target: frame.lookAt, deltaTime: frame.deltaTime)
        tail?.apply(to: &pose, solver: solver, frame: frame)
        if jiggleEnabled {
            jiggle?.apply(to: &pose, modelToWorld: frame.modelToWorld, deltaTime: frame.deltaTime,
                          sizeScale: frame.sizeScale, obstacles: jiggleTouch ? frame.obstacles : [])
        } else {
            jiggle?.reset()
        }
    }

    /// Starts every simulation over from the pose it is next given: for a
    /// body that was teleported, hidden or reloaded.
    public mutating func reset() {
        tail?.reset()
        jiggle?.reset()
    }

    static func leaf(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }
}

// MARK: - Look

/// Where the head should turn, in the character's own terms: clamped to
/// what a neck does, and eased so it glances rather than snaps.
public struct LookSteering: Sendable {
    public var maxYaw: Float = 70 * .pi / 180
    public var maxPitch: Float = 35 * .pi / 180
    /// Radians a second the head may turn.
    public var rate: Float = 4
    /// Current head yaw and pitch relative to the body.
    public private(set) var yaw: Float = 0
    public private(set) var pitch: Float = 0
    /// The unclamped yaw last asked for, for deciding to turn the body.
    public private(set) var wantedYaw: Float = 0

    public init() {}

    /// Signed yaw and pitch of `direction` relative to a body facing
    /// `forward` (both world, forward on the floor plane). A target almost
    /// straight behind keeps the side the head is already turned to, so
    /// walking round behind the character does not flip it across.
    public func angles(of direction: SIMD3<Float>, forward: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
        let flat = SIMD2(direction.x, direction.z)
        let ahead = SIMD2(forward.x, forward.z)
        guard simd_length(flat) > 1e-4, simd_length(ahead) > 1e-4 else { return (yaw, 0) }
        let f = simd_normalize(ahead), d = simd_normalize(flat)
        // Positive yaw turns toward +x of a body facing +z.
        var yaw = atan2(f.y * d.x - f.x * d.y, simd_dot(f, d))
        if abs(yaw) > 150 * .pi / 180, self.yaw != 0, (yaw > 0) != (self.yaw > 0) {
            yaw = self.yaw > 0 ? abs(yaw) : -abs(yaw)
        }
        let pitch = atan2(direction.y, simd_length(flat))
        return (yaw, pitch)
    }

    /// Steps toward looking along `direction`, or back to straight ahead
    /// when it is nil, and returns the clamped direction to aim at (world).
    public mutating func step(toward direction: SIMD3<Float>?, forward: SIMD3<Float>,
                              deltaTime: Float) -> SIMD3<Float> {
        var goal: (yaw: Float, pitch: Float) = (0, 0)
        if let direction {
            let raw = angles(of: direction, forward: forward)
            wantedYaw = raw.yaw
            goal = (min(max(raw.yaw, -maxYaw), maxYaw), min(max(raw.pitch, -maxPitch), maxPitch))
        } else {
            wantedYaw = 0
        }
        let limit = rate * deltaTime
        yaw += min(max(goal.yaw - yaw, -limit), limit)
        pitch += min(max(goal.pitch - pitch, -limit), limit)
        return Self.direction(yaw: yaw, pitch: pitch, forward: forward)
    }

    /// The world direction `yaw` and `pitch` away from `forward`.
    public static func direction(yaw: Float, pitch: Float, forward: SIMD3<Float>) -> SIMD3<Float> {
        var f = SIMD3(forward.x, 0, forward.z)
        f = simd_length(f) > 1e-4 ? simd_normalize(f) : SIMD3(0, 0, 1)
        // About +Y, which takes +z toward +x: the same sense as `angles`.
        let turned = simd_quatf(angle: yaw, axis: [0, 1, 0]).act(f)
        return simd_normalize(turned * cos(pitch) + SIMD3(0, sin(pitch), 0))
    }
}

/// Turns the neck and head toward a point, on a pose.
///
/// The turn is shared down the chain, the neck taking part of it and the
/// head the rest, and it keeps the head level: yaw about the body's up, then
/// pitch, never a roll. `stabilise` chooses between two honest answers to
/// "what about the clip's own head motion": at 0 the turn is added to
/// whatever the clip does with the head, so nods and sways play on top and
/// the eyes wander off the target with them; at 1 the head is held on the
/// target outright, which reads as a turret on a body that sways. The
/// default keeps a little of the clip.
public struct LookLayer: Sendable {
    public var steering = LookSteering()
    /// Off eases the head back to the pose it is given.
    public var enabled = true
    /// 0 adds the turn to the clip's head motion; 1 holds the head on the
    /// target whatever the clip does.
    public var stabilise: Float = 0.7
    /// Seconds to take the head, or give it back.
    public var fadeTime: Float = 0.4
    /// How much the layer owns the head right now, 0...1.
    public private(set) var weight: Float = 0
    /// Whether the head was turned on the last frame.
    public var aimed: Bool { weight > 0.001 }

    /// Neck joints then the head, parent first.
    public let chain: [Int]
    /// The share of the turn each joint of `chain` takes; they sum to one.
    public let shares: [Float]
    public var head: Int { chain[chain.count - 1] }
    /// The head joint's own axes that face forward and up at rest.
    let forwardInHead: SIMD3<Float>
    let upInHead: SIMD3<Float>
    let forward: SIMD3<Float>
    let up: SIMD3<Float>
    /// The head joint's place in the world on the last frame.
    public private(set) var headWorld: SIMD3<Float> = .zero

    /// How much of the turn the head takes; the neck joints split the rest.
    public static let headShare: Float = 0.6

    init(head: Int, neck: [Int], solver: PoseSolver, rest: [JointPose], forward: SIMD3<Float>, up: SIMD3<Float>) {
        // Only neck joints that really are above the head.
        let above = neck.filter { candidate in
            var cursor = solver.parents[head]
            while let joint = cursor, joint >= 0 {
                if joint == candidate { return true }
                cursor = solver.parents[joint]
            }
            return false
        }
        chain = above + [head]
        shares = above.isEmpty ? [1]
            : above.map { _ in (1 - Self.headShare) / Float(above.count) } + [Self.headShare]
        self.forward = simd_normalize(forward)
        self.up = simd_normalize(up)
        let restRotation = PoseSolver.rotation(of: solver.modelMatrices(of: rest)[head])
        forwardInHead = restRotation.inverse.act(self.forward)
        upInHead = restRotation.inverse.act(self.up)
    }

    mutating func apply(to pose: inout [JointPose], solver: PoseSolver, modelToWorld: float4x4,
                        target: SIMD3<Float>?, deltaTime: Float) {
        let model = solver.modelMatrices(of: pose)
        let worldRotation = PoseSolver.rotation(of: modelToWorld)
        headWorld = PoseSolver.translation(of: modelToWorld * model[head])
        var ahead = worldRotation.act(forward)
        ahead.y = 0
        guard simd_length(ahead) > 1e-4 else { return }
        ahead = simd_normalize(ahead)

        let wanted = enabled ? target.map { $0 - headWorld } : nil
        let dt = min(max(deltaTime, 0), 0.1)
        let rate = dt / max(fadeTime, 1e-3)
        weight += min(max((wanted == nil ? 0 : 1) - weight, -rate), rate)
        // Stepped even while fading out, so the head eases back through
        // straight ahead instead of freezing where it was let go.
        let direction = steering.step(toward: wanted, forward: ahead, deltaTime: dt)
        guard weight > 0.001 else { return }
        let eased = weight * weight * (3 - 2 * weight)

        // Model space from here on.
        let toModel = worldRotation.inverse
        let aim = simd_normalize(toModel.act(direction))
        let bodyUp = simd_normalize(toModel.act(SIMD3<Float>(0, 1, 0)))
        let bodyAhead = simd_normalize(toModel.act(ahead))
        let headRotation = PoseSolver.rotation(of: model[head])
        let added = Self.turn(from: (bodyAhead, bodyUp), to: (aim, bodyUp))
        let held = Self.turn(from: (headRotation.act(forwardInHead), headRotation.act(upInHead)), to: (aim, bodyUp))
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        var remaining = simd_slerp(identity, simd_slerp(added, held, min(max(stabilise, 0), 1)), eased)

        // Parent first: each joint takes its share of what is left, and
        // everything below it is carried round by it.
        var carried = identity
        var sharesLeft = shares.reduce(0, +)
        for (joint, share) in zip(chain, shares) {
            let part = simd_slerp(identity, remaining, sharesLeft > 1e-5 ? min(share / sharesLeft, 1) : 1)
            sharesLeft -= share
            remaining = simd_normalize(remaining * part.inverse)
            let parent = solver.parents[joint].flatMap { $0 >= 0 && $0 < model.count ? PoseSolver.rotation(of: model[$0]) : nil }
                ?? identity
            let own = PoseSolver.rotation(of: model[joint])
            pose[joint].rotation = simd_normalize(parent.inverse * carried.inverse * part * carried * own)
            carried = simd_normalize(part * carried)
        }
    }

    /// The rotation taking a frame facing `from.forward` with `from.up`
    /// overhead onto one facing `to.forward` with `to.up` overhead. Each up
    /// is squared off against its forward first, so the result carries yaw
    /// and pitch and whatever roll separates the two ups, never a roll of
    /// its own.
    static func turn(from: (forward: SIMD3<Float>, up: SIMD3<Float>),
                     to: (forward: SIMD3<Float>, up: SIMD3<Float>)) -> simd_quatf {
        func basis(_ forward: SIMD3<Float>, _ up: SIMD3<Float>) -> float3x3? {
            let f = simd_normalize(forward)
            let side = simd_cross(up, f)
            guard simd_length(side) > 1e-4 else { return nil }
            let right = simd_normalize(side)
            return float3x3(right, simd_cross(f, right), f)
        }
        guard let a = basis(from.forward, from.up), let b = basis(to.forward, to.up) else {
            return PoseSolver.rotation(from: simd_normalize(from.forward), to: simd_normalize(to.forward))
        }
        return simd_normalize(simd_quatf(b * a.transpose))
    }
}

// MARK: - Tail

/// A tail on a pose: carried round after the body, swung by its mood,
/// simulated as a chain that sags, trails and meets hands and the floor,
/// then laid back onto the joints.
///
/// The pose it is given says where the body carries the tail this frame;
/// that shape is what the simulation is drawn toward, never what is drawn.
public struct TailLayer: Sendable {
    /// Joint indices, base first.
    public let chain: [Int]
    /// The deliberate motion: the wag, and how high the tail is carried.
    public var sway = TailSway(style: .still)
    public var settings = ChainDynamics.Settings()
    /// Off hands the tail back to the pose it is given, eased.
    public var enabled = true
    /// Whether hands push it.
    public var touch = true
    /// How much the simulation owns the tail right now, 0...1.
    public private(set) var weight: Float = 0
    public private(set) var dynamics: ChainDynamics?
    /// Whether a hand was against the tail on the last frame.
    public private(set) var touching = false
    /// How many hand spheres were in play on the last frame.
    public private(set) var obstacleCount = 0

    /// World positions of the joints as drawn on the last frame, base first.
    public var positions: [SIMD3<Float>] { dynamics?.positions ?? [] }
    public var tip: SIMD3<Float>? { dynamics?.positions.last }

    init?(chain: [Int], solver: PoseSolver) {
        guard chain.count >= 2 else { return nil }
        for (parent, child) in zip(chain, chain.dropFirst()) where solver.parents[child] != parent { return nil }
        self.chain = chain
    }

    public mutating func reset() {
        dynamics = nil
        sway.snapHeading()
    }

    mutating func apply(to pose: inout [JointPose], solver: PoseSolver, frame: BodyLayers.Frame) {
        let dt = min(max(frame.deltaTime, 0), 0.1)
        let rate = dt / 0.5
        weight += min(max((enabled ? 1 : 0) - weight, -rate), rate)
        guard weight > 0.001 else {
            dynamics = nil
            touching = false
            return
        }
        let model = solver.modelMatrices(of: pose)
        let animated = chain.map { PoseSolver.translation(of: frame.modelToWorld * model[$0]) }
        // The carriage follows the body's heading at a bounded rate, then
        // wags: a turn on the spot otherwise sweeps the tip through metres
        // in a fraction of a second and the spring hauls the tail after it
        // along the chord, through the legs.
        let carried = sway.follow(animated, deltaTime: dt)
        let (yaw, pitch) = sway.advance(by: dt)
        let shape = TailSway.apply(to: carried, yaw: yaw, pitch: pitch)
        if dynamics == nil { dynamics = ChainDynamics(shape: shape, settings: settings) }
        dynamics!.settings = settings
        let hands = touch ? frame.obstacles : []
        obstacleCount = hands.count
        dynamics!.step(toward: shape, deltaTime: dt,
                       floor: frame.floor.map { $0 + 0.02 * frame.sizeScale }, obstacles: hands)
        // Touching means within a whisker of a surface the chain was just
        // pushed to, so the test is against a slightly larger hand.
        touching = !hands.isEmpty && dynamics!.touches(hands.map {
            ChainDynamics.Sphere(center: $0.center, radius: $0.radius + 0.005)
        })
        let toModel = frame.modelToWorld.inverse
        let targets = dynamics!.positions.map { PoseSolver.translation(of: toModel * Self.translation($0)) }
        solver.lay(chain, along: targets, in: &pose, weight: weight * weight * (3 - 2 * weight))
    }

    private static func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}

extension PoseSolver {
    /// Turns each joint of `chain` so the next one lies toward the next of
    /// `positions` (model space), base first. The base joint's own place is
    /// left to its parent; the last joint keeps its rotation. Each joint
    /// turns by the shortest arc, so the twist the pose gave it stays.
    ///
    /// `chain` must run parent to child. With `positions` a bone length
    /// apart, as a chain simulation leaves them, every joint lands on its
    /// position; otherwise each bone points the right way at its own length.
    public func lay(_ chain: [Int], along positions: [SIMD3<Float>], in pose: inout [JointPose], weight: Float = 1) {
        guard chain.count >= 2, positions.count == chain.count, weight > 0 else { return }
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let model = modelMatrices(of: pose)
        var parentMatrix = parents[chain[0]].flatMap { $0 >= 0 && $0 < model.count ? model[$0] : nil }
            ?? matrix_identity_float4x4
        for (index, joint) in chain.dropLast().enumerated() {
            let child = chain[index + 1]
            guard parents[child] == joint else { return }
            let here = parentMatrix * pose[joint].matrix
            let origin = Self.translation(of: here)
            let now = Self.translation(of: here * pose[child].matrix) - origin
            let want = positions[index + 1] - origin
            if simd_length(now) > 1e-7, simd_length(want) > 1e-7 {
                let turn = simd_slerp(identity, Self.rotation(from: simd_normalize(now), to: simd_normalize(want)),
                                      min(weight, 1))
                let parentRotation = Self.rotation(of: parentMatrix)
                pose[joint].rotation = simd_normalize(parentRotation.inverse * turn * Self.rotation(of: here))
            }
            parentMatrix = parentMatrix * pose[joint].matrix
        }
    }
}
