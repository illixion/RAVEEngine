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
        /// The pelvis: what a pull on the tail shifts.
        public var hips: String?
        /// Each leg from the thigh down, for keeping the tail out of them.
        public var legs: [[String]]
        /// The way the character faces, in the skeleton's model space.
        public var forward: SIMD3<Float>
        /// Up, in the skeleton's model space (a Blender export's is +Z).
        public var up: SIMD3<Float>

        public init(head: String? = nil, neck: [String] = [], tail: [String] = [],
                    hips: String? = nil, legs: [[String]] = [],
                    forward: SIMD3<Float> = SIMD3(0, 0, 1), up: SIMD3<Float> = SIMD3(0, 1, 0)) {
            self.head = head
            self.neck = neck
            self.tail = tail
            self.hips = hips
            self.legs = legs
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
            hips = rig.joints[landmarks.hips].name
            legs = [landmarks.leftLeg, landmarks.rightLeg].map { leg in leg.map { rig.joints[$0].name } }
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
        /// The wearer's hands: what pushes, holds and is curled round.
        public var hands: [Hand]
        /// Anything else to stay out of, as spheres in world space.
        public var obstacles: [ChainDynamics.Sphere]

        public init(modelToWorld: float4x4, deltaTime: Float, sizeScale: Float = 1,
                    lookAt: SIMD3<Float>? = nil, floor: Float? = nil,
                    hands: [Hand] = [], obstacles: [ChainDynamics.Sphere] = []) {
            self.modelToWorld = modelToWorld
            self.deltaTime = deltaTime
            self.sizeScale = sizeScale
            self.lookAt = lookAt
            self.floor = floor
            self.hands = hands
            self.obstacles = obstacles
        }

        /// Everything solid this frame, as spheres.
        var spheres: [ChainDynamics.Sphere] { obstacles + hands.flatMap(\.spheres) }
    }

    /// One of the wearer's hands near a body, world space.
    public struct Hand: Sendable, Equatable {
        /// Stable while the hand is tracked (0 left, 1 right), so a grip
        /// stays with the hand that took it.
        public var id: Int
        /// The palm and fingers, as spheres: what pushes.
        public var spheres: [ChainDynamics.Sphere]
        /// The middle of the closing hand: where something held sits.
        public var grip: SIMD3<Float>
        /// The palm's radius: what a tail curls round.
        public var radius: Float
        /// 0 open, 1 a fist.
        public var closure: Float

        public init(id: Int, spheres: [ChainDynamics.Sphere], grip: SIMD3<Float>, radius: Float = 0.045,
                    closure: Float = 0) {
            self.id = id
            self.spheres = spheres
            self.grip = grip
            self.radius = radius
            self.closure = closure
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
    /// The pelvis joint, which a pull on the tail shifts. Nil leaves the body
    /// where it is, whatever is done to the tail.
    public let hips: Int?
    /// Leg joints, thigh down, per leg: the tail is kept out of them.
    public let legs: [[Int]]
    /// How the body gives to a pull on the tail.
    public var give = Give()
    /// The hips' offset from the pose they were given, world space, as of
    /// the last frame: the tug of a held tail, eased.
    public private(set) var bodyShift: SIMD3<Float> = .zero
    private var shiftedThisFrame = false

    /// How far the hips follow a pull on the tail.
    public struct Give: Sendable, Equatable {
        /// Metres the hips move per metre the tail is stretched past its
        /// length.
        public var gain: Float = 0.6
        /// The most the hips move, metres at natural size.
        public var limit: Float = 0.06
        /// Seconds to follow a pull, or to come back from one.
        public var time: Float = 0.12
        public init() {}
    }

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
        hips = rig.hips.flatMap(find)
        legs = rig.legs.map { $0.compactMap(find) }.filter { $0.count >= 2 }
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
        if !shiftedThisFrame {
            shiftBody(&pose, modelToWorld: frame.modelToWorld, deltaTime: frame.deltaTime, sizeScale: frame.sizeScale)
        }
        shiftedThisFrame = false
        look?.apply(to: &pose, solver: solver, modelToWorld: frame.modelToWorld,
                    target: frame.lookAt, deltaTime: frame.deltaTime)
        if tail != nil {
            let model = solver.modelMatrices(of: pose)
            // The legs, as capsules a twelfth of a metre thick at a person's
            // size: thinner than a thigh, so the tail is kept out of the
            // legs without being held off them.
            var limbs: [ChainDynamics.Capsule] = []
            for leg in legs {
                let points = leg.map { PoseSolver.translation(of: frame.modelToWorld * model[$0]) }
                for (a, b) in zip(points, points.dropFirst()) {
                    limbs.append(.init(a: a, b: b, radius: 0.13 * simd_distance(a, b)))
                }
            }
            tail?.apply(to: &pose, solver: solver, frame: frame, limbs: limbs)
        }
        if jiggleEnabled {
            jiggle?.apply(to: &pose, modelToWorld: frame.modelToWorld, deltaTime: frame.deltaTime,
                          sizeScale: frame.sizeScale, obstacles: jiggleTouch ? frame.spheres : [])
        } else {
            jiggle?.reset()
        }
    }

    /// Moves the hips by the pull the tail carried on the last frame: a held
    /// tail tugs the body it is attached to.
    ///
    /// A host that places feet calls this before its leg solve, so the feet
    /// stay planted while the hips give. `apply` does it itself for a host
    /// that does not, and the legs then ride along.
    public mutating func shiftBody(_ pose: inout [JointPose], modelToWorld: float4x4, deltaTime: Float,
                                   sizeScale: Float = 1) {
        shiftedThisFrame = true
        guard let hips, pose.count == solver.parents.count else { return }
        var wanted = (tail?.pull ?? .zero) * give.gain
        let limit = give.limit * max(sizeScale, 1e-3)
        let length = simd_length(wanted)
        if length > limit { wanted *= limit / length }
        let dt = min(max(deltaTime, 0), 0.1)
        bodyShift += (wanted - bodyShift) * min(1, dt / max(give.time, 1e-3))
        guard simd_length(bodyShift) > 1e-5 else { return }
        // World offset into the space the hips' translation is written in.
        var parentToWorld = modelToWorld
        if let parent = solver.parents[hips], parent >= 0 {
            parentToWorld = modelToWorld * solver.modelMatrices(of: pose)[parent]
        }
        let local = parentToWorld.inverse * SIMD4<Float>(bodyShift, 0)
        pose[hips].translation += SIMD3<Float>(local.x, local.y, local.z)
    }

    /// Starts every simulation over from the pose it is next given: for a
    /// body that was teleported, hidden or reloaded.
    public mutating func reset() {
        tail?.reset()
        jiggle?.reset()
        bodyShift = .zero
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
/// simulated as a chain that sags, trails and meets hands, legs and the
/// floor, then laid back onto the joints.
///
/// The pose it is given says where the body carries the tail this frame;
/// that shape is what the simulation is drawn toward, never what is drawn.
///
/// A hand does three things to it:
/// - **Open**, it pushes: the tail rests on a palm and, with friction,
///   stays there.
/// - **Closing on it**, it holds: the nearest joint goes with the hand. A
///   hold further off than the tail reaches leaves it taut, and the rest is
///   `pull`: what the body it hangs from feels (`BodyLayers.shiftBody`).
///   Pulled harder than the grip holds, the tail slides through the hand
///   toward its tip and comes free.
/// - **Near**, it is answered: with `affinity` above zero the tail curls
///   round the hand, below zero it draws away from it.
public struct TailLayer: Sendable {
    /// Joint indices, base first.
    public let chain: [Int]
    /// The deliberate motion: the wag, and how high the tail is carried.
    public var sway = TailSway(style: .still)
    public var settings = ChainDynamics.Settings()
    /// Off hands the tail back to the pose it is given, eased.
    public var enabled = true
    /// Whether hands push and hold it.
    public var touch = true
    /// Whether a closing hand takes hold of it.
    public var grabbable = true
    /// A hand closed this far takes hold; opened past `gripExit` it lets go.
    public var gripEnter: Float = 0.6
    public var gripExit: Float = 0.3
    /// Metres a fist can stretch the tail past its length before it starts
    /// to slide through the hand. A looser hand holds less.
    public var slipStretch: Float = 0.12
    /// Seconds for the hold to slide one joint toward the tip while it slips.
    public var slipTime: Float = 0.09
    /// What the tail does about a hand near it: above zero it curls round
    /// the hand, below zero it draws away. Its muscle, which a mood sets.
    public var affinity: Float = 0
    /// How near a hand's surface has to be for the tail to answer it, metres.
    public var answerRange: Float = 0.12
    /// How much the simulation owns the tail right now, 0...1.
    public private(set) var weight: Float = 0
    public private(set) var dynamics: ChainDynamics?
    /// Whether a hand was against the tail on the last frame.
    public private(set) var touching = false
    /// How many solid spheres were in play on the last frame.
    public private(set) var obstacleCount = 0
    /// The pull on the body on the last frame, world metres: how far the
    /// hands holding the tail are asking it to reach past its length, eased.
    public private(set) var pull: SIMD3<Float> = .zero
    /// What happened on the last frame.
    public private(set) var events: [Event] = []
    /// The hand answered on the last frame (curled round or avoided), and
    /// how strongly, 0...1.
    public private(set) var answering: (hand: Int, amount: Float)?

    public enum Event: Sendable, Equatable {
        /// A hand took hold, at this joint of the chain.
        case grabbed(hand: Int, joint: Int)
        /// The hand let go.
        case released(hand: Int)
        /// The tail was pulled out of the hand.
        case slipped(hand: Int)
    }

    struct Grip: Sendable, Equatable {
        var particle: Int
        var slipping: Float = 0
    }
    private var grips: [Int: Grip] = [:]
    /// Seconds each hand has been closed, to tell a hand closing on the tail
    /// from a fist brushing past it.
    private var closedFor: [Int: Float] = [:]
    private var lastObstacles: [SIMD3<Float>] = []

    /// Whether any hand holds the tail.
    public var held: Bool { !grips.isEmpty }
    /// The joints of the chain held, by hand.
    public var heldJoints: [Int: Int] { grips.mapValues(\.particle) }

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
        grips = [:]
        pull = .zero
    }

    mutating func apply(to pose: inout [JointPose], solver: PoseSolver, frame: BodyLayers.Frame,
                        limbs: [ChainDynamics.Capsule] = []) {
        events = []
        answering = nil
        let dt = min(max(frame.deltaTime, 0), 0.1)
        let rate = dt / 0.5
        weight += min(max((enabled ? 1 : 0) - weight, -rate), rate)
        guard weight > 0.001 else {
            dynamics = nil
            touching = false
            grips = [:]
            pull = .zero
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
        var shape = TailSway.apply(to: carried, yaw: yaw, pitch: pitch)
        // The tail's own lengths, before anything bends the shape it is
        // drawn toward.
        let carriedShape = shape
        if dynamics == nil { dynamics = ChainDynamics(shape: shape, settings: settings) }
        var stepSettings = settings

        let hands = touch ? frame.hands : []
        updateGrips(hands: hands, deltaTime: dt)
        // A hand holding the tail is not also pushing it away.
        var pushing = (touch ? frame.obstacles : []) + hands.filter { grips[$0.id] == nil }.flatMap(\.spheres)
        obstacleCount = pushing.count
        // How each is moving, from where it was a frame ago, so a tail
        // resting on a hand goes with the hand.
        if pushing.count == lastObstacles.count, dt > 1e-4 {
            for i in pushing.indices {
                let velocity = (pushing[i].center - lastObstacles[i]) / dt
                pushing[i].velocity = simd_length(velocity) < 6 ? velocity : .zero
            }
        }
        lastObstacles = pushing.map(\.center)
        if let answer = answer(hands: hands.filter { grips[$0.id] == nil }, shape: &shape) {
            answering = answer
            // Curled, it bends tighter than it carries itself.
            if affinity > 0 {
                stepSettings.maxBendDegrees += max(0, 100 - stepSettings.maxBendDegrees) * answer.amount
            }
        }
        // A hand bends a tail further than the tail bends itself.
        if held { stepSettings.maxBendDegrees = max(stepSettings.maxBendDegrees, 80) }
        dynamics!.settings = stepSettings
        dynamics!.holds = hands.compactMap { hand in
            grips[hand.id].map { ChainDynamics.Hold(particle: $0.particle, point: hand.grip) }
        }
        dynamics!.step(toward: shape, deltaTime: dt,
                       floor: frame.floor.map { $0 + 0.02 * frame.sizeScale }, obstacles: pushing, capsules: limbs,
                       measuring: carriedShape)
        slip(hands: hands, deltaTime: dt)
        pull += (dynamics!.stretch - pull) * min(1, dt / 0.06)
        // Touching means within a whisker of a surface the chain was just
        // pushed to, so the test is against a slightly larger hand.
        touching = held || (!pushing.isEmpty && dynamics!.touches(pushing.map {
            ChainDynamics.Sphere(center: $0.center, radius: $0.radius + 0.005)
        }))
        let toModel = frame.modelToWorld.inverse
        let targets = dynamics!.positions.map { PoseSolver.translation(of: toModel * Self.translation($0)) }
        solver.lay(chain, along: targets, in: &pose, weight: weight * weight * (3 - 2 * weight))
    }

    /// Takes hold where a hand closes on the tail, and lets go where one
    /// opens or is lost.
    private mutating func updateGrips(hands: [BodyLayers.Hand], deltaTime: Float) {
        let present = Set(hands.map(\.id))
        for id in grips.keys where !present.contains(id) {
            grips[id] = nil
            events.append(.released(hand: id))
        }
        closedFor = closedFor.filter { present.contains($0.key) }
        guard let positions = dynamics?.positions, positions.count >= 2 else { return }
        for hand in hands {
            let closed = hand.closure >= gripEnter
            let before = closedFor[hand.id]
            closedFor[hand.id] = closed ? (before ?? 0) + deltaTime : nil
            if grips[hand.id] != nil {
                if hand.closure < gripExit {
                    grips[hand.id] = nil
                    events.append(.released(hand: hand.id))
                }
                continue
            }
            // Only a hand that closes while on the tail: a fist that arrives
            // already closed pushes it instead.
            guard grabbable, closed, (before ?? 0) < 0.3 else { continue }
            var best: (particle: Int, distance: Float)?
            for i in 1..<positions.count {
                let (closest, t) = ChainDynamics.closestPoint(on: positions[i - 1], positions[i], to: hand.grip)
                let distance = simd_distance(closest, hand.grip)
                // The joint nearer the contact, and never the base.
                let particle = max(1, t < 0.5 ? i - 1 : i)
                if distance < (best?.distance ?? .infinity) { best = (particle, distance) }
            }
            guard let best, best.distance < dynamics!.thickness(ofSegment: best.particle) + 0.05 else { continue }
            grips[hand.id] = Grip(particle: best.particle)
            events.append(.grabbed(hand: hand.id, joint: best.particle))
        }
    }

    /// A tail pulled harder than a hand holds slides through it toward the
    /// tip, a joint at a time, and comes free at the end.
    private mutating func slip(hands: [BodyLayers.Hand], deltaTime: Float) {
        guard let dynamics, !grips.isEmpty else { return }
        let stretched = simd_length(dynamics.stretch)
        for hand in hands {
            guard var grip = grips[hand.id] else { continue }
            let holds = slipStretch * min(max(hand.closure, 0.1), 1)
            if stretched > holds {
                grip.slipping += deltaTime
                if grip.slipping >= slipTime {
                    grip.slipping = 0
                    grip.particle += 1
                }
            } else {
                grip.slipping = max(0, grip.slipping - deltaTime)
            }
            if grip.particle >= dynamics.count {
                grips[hand.id] = nil
                events.append(.slipped(hand: hand.id))
            } else {
                grips[hand.id] = grip
            }
        }
    }

    /// Bends the shape the tail is drawn toward for the nearest open hand:
    /// round it, or away from it.
    private func answer(hands: [BodyLayers.Hand], shape: inout [SIMD3<Float>]) -> (hand: Int, amount: Float)? {
        guard abs(affinity) > 1e-3, let dynamics, dynamics.count >= 3 else { return nil }
        let positions = dynamics.positions
        var nearest: (hand: BodyLayers.Hand, particle: Int, gap: Float)?
        for hand in hands {
            // Where the tail first comes up to the hand, counting from the
            // body: once it is wrapped, every joint past that is as near.
            var gaps: [(particle: Int, gap: Float)] = []
            for i in 1..<positions.count {
                let (closest, t) = ChainDynamics.closestPoint(on: positions[i - 1], positions[i], to: hand.grip)
                let gap = simd_distance(closest, hand.grip) - hand.radius - dynamics.thickness(ofSegment: i)
                gaps.append((max(1, t < 0.5 ? i - 1 : i), gap))
            }
            guard let least = gaps.map(\.gap).min(), least < (nearest?.gap ?? .infinity),
                  let first = gaps.first(where: { $0.gap <= least + 0.02 }) else { continue }
            nearest = (hand, first.particle, least)
        }
        guard let nearest, nearest.gap < answerRange else { return nil }
        let amount = min(max(1 - nearest.gap / answerRange, 0), 1) * min(abs(affinity), 1)
        let centre = nearest.hand.grip
        if affinity < 0 {
            // Swing the whole tail about its base, away from the hand.
            let base = shape[0]
            let toHand = centre - base, along = shape[shape.count - 1] - base
            let axis = simd_cross(toHand, along)
            guard simd_length(axis) > 1e-5 else { return (nearest.hand.id, amount) }
            let turn = simd_quatf(angle: 45 * .pi / 180 * amount, axis: simd_normalize(axis))
            shape = shape.map { base + turn.act($0 - base) }
            return (nearest.hand.id, amount)
        }
        // Wrap what lies past the contact round the hand: a turn of a helix
        // starting where the tail meets it.
        let contact = nearest.particle
        guard contact < positions.count - 1 else { return (nearest.hand.id, amount) }
        var inward = centre - positions[contact]
        guard simd_length(inward) > 1e-5 else { return (nearest.hand.id, amount) }
        inward = simd_normalize(inward)
        var tangent = positions[contact] - positions[contact - 1]
        tangent -= inward * simd_dot(tangent, inward)
        guard simd_length(tangent) > 1e-5 else { return (nearest.hand.id, amount) }
        tangent = simd_normalize(tangent)
        let axis = simd_cross(inward, tangent)
        let radius = nearest.hand.radius + dynamics.thickness(ofSegment: contact)
        // The spring that draws the tail to its shape gives under the
        // tail's weight by this much. The curl is aimed that much high, so
        // it holds against gravity: muscle, where the rest of the tail hangs.
        let sag = SIMD3<Float>(0, settings.gravity * settings.gravityScale / max(settings.stiffness, 1e-3), 0)
        var arc: Float = 0
        for i in (contact + 1)..<positions.count {
            arc += dynamics.lengths[i - 1]
            let angle = arc / radius
            let wrapped = centre + (tangent * sin(angle) - inward * cos(angle)) * radius
                + axis * (2 * settings.thickness * angle / (2 * .pi)) + sag
            shape[i] += (wrapped - shape[i]) * amount
        }
        return (nearest.hand.id, amount)
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
