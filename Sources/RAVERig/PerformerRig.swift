import Foundation
import simd

// MARK: - What the tracker sees

/// One tracked hand as joint positions in tracking space (metres, Y up).
///
/// Positions rather than joint rotations, on purpose: positions reflect
/// through a mirror plane exactly, and they mean the same thing on every
/// tracker. A joint's orientation is a convention — ARKit's left and right
/// hands do not even share one — and the solver only ever needs directions
/// between joints and the frame the palm spans, both of which positions give.
public struct PerformerHand: Sendable, Equatable {
    public var wrist: SIMD3<Float>
    /// A point along the forearm toward the elbow (ARKit's `forearmArm`),
    /// when the tracker has one. It decides which way the elbow points, which
    /// nothing else on the hand can.
    public var forearm: SIMD3<Float>?
    /// Base of the thumb (the CMC joint), its two knuckles, then the tip.
    public var thumb: [SIMD3<Float>]
    /// Index, middle, ring, little; each metacarpal base, knuckle, the two
    /// finger joints, then the tip.
    public var fingers: [[SIMD3<Float>]]

    public init(wrist: SIMD3<Float>, forearm: SIMD3<Float>? = nil,
                thumb: [SIMD3<Float>], fingers: [[SIMD3<Float>]]) {
        self.wrist = wrist
        self.forearm = forearm
        self.thumb = thumb
        self.fingers = fingers
    }

    /// The knuckle (metacarpophalangeal joint) of finger `i`.
    func knuckle(_ i: Int) -> SIMD3<Float>? {
        i < fingers.count && fingers[i].count >= 2 ? fingers[i][1] : nil
    }

    var isComplete: Bool {
        thumb.count == 4 && fingers.count == 4 && fingers.allSatisfy { $0.count == 5 }
    }
}

/// One frame of a performer: the head, always, and whichever hands are in
/// view.
public struct PerformerFrame: Sendable, Equatable {
    public var head: SIMD3<Float>
    /// The head's orientation in tracking space. The head looks along its own
    /// −Z with +Y up, as ARKit's device anchor does.
    public var headRotation: simd_quatf
    public var left: PerformerHand?
    public var right: PerformerHand?

    public init(head: SIMD3<Float>, headRotation: simd_quatf,
                left: PerformerHand? = nil, right: PerformerHand? = nil) {
        self.head = head
        self.headRotation = headRotation
        self.left = left
        self.right = right
    }
}

/// Where the performer is when neutral, which way is "to camera", and how
/// big they are.
///
/// `forward` is the direction the performer faces when they mean to look
/// into the camera: in a call, the call's window. Looking that way puts the
/// avatar's eyes on the viewer.
public struct PerformerCalibration: Sendable, Equatable {
    public var head: SIMD3<Float>
    /// Horizontal unit vector.
    public var forward: SIMD3<Float>
    /// Standing height in metres. Only proportions are derived from it — arm
    /// length, the neck below the eyes — so a seated performer keeps their
    /// standing height.
    public var height: Float

    public init(head: SIMD3<Float>, forward: SIMD3<Float>, height: Float = 1.70) {
        self.head = head
        var flat = SIMD3<Float>(forward.x, 0, forward.z)
        if simd_length(flat) < 1e-4 { flat = SIMD3<Float>(0, 0, -1) }
        self.forward = simd_normalize(flat)
        self.height = height
    }

    /// Neutral at a head pose: looking the way the head looks, levelled.
    public init(headTransform: simd_float4x4, height: Float = 1.70) {
        let c = headTransform.columns
        self.init(head: SIMD3<Float>(c.3.x, c.3.y, c.3.z),
                  forward: -SIMD3<Float>(c.2.x, c.2.y, c.2.z), height: height)
    }
}

// MARK: - The rig

/// Drives a humanoid skeleton from a tracked performer's head and hands — the
/// whole of what a headset knows about the person wearing it.
///
/// What it does with each part:
/// - **Head and neck** turn by the head's rotation away from neutral, set
///   absolutely (not on top of a clip), the neck taking part of it.
/// - **Spine** bends with the head's travel away from neutral (a lean pivots
///   about the hips, which a headset cannot see but which barely move) and
///   follows a share of the head's yaw, on top of the base pose.
/// - **Arms** are two-bone solves to the wrists, scaled by the ratio of arm
///   lengths and measured from the shoulders, with the elbow pointed where the
///   tracker's forearm says it is.
/// - **Hands** take the palm's frame; the forearm takes half of the wrist's
///   twist, as a real forearm does, so the skin does not wring at the wrist.
/// - **Digits** point along the performer's: each avatar digit follows the
///   performer digits it stands for, averaged — a three-fingered paw's outer
///   finger follows the middle, ring and little fingers together — matched
///   from the knuckle out, a metacarpal inside the palm recognised by where
///   it sits, so the bend lands at the knuckle on any rig.
/// - **Jaw** opens by a caller-supplied amount (the voice, say).
/// - **Legs and hips** stay whatever the base pose gives them.
///
/// Everything not tracked this frame eases back to the base pose, so a hand
/// leaving view drops to the clip's idle instead of freezing in the air.
///
/// **Mirrored** solves reflect the performer through the plane between them
/// and the avatar, swapping hands, so an avatar facing the performer moves as
/// their reflection. Reflection happens to points and directions before any
/// frame is built, which keeps every frame right-handed. A camera's avatar is
/// solved unmirrored: raising your right hand raises its right hand.
///
/// Framework-free and in pose order, like `PoseSolver`: the host converts a
/// RealityKit `SkeletalPose` or a GoldSrc bone palette in a line, and hands
/// tracking in from whatever produced it.
public struct PerformerRig: Sendable {

    /// One hand's digits as joint indices, root first: thumb, then fingers
    /// ordered from the thumb side.
    public struct Digits: Sendable, Equatable {
        public var thumb: [Int]?
        public var fingers: [[Int]]
        public init(thumb: [Int]?, fingers: [[Int]]) {
            self.thumb = thumb
            self.fingers = fingers
        }
    }

    /// The avatar as the rig needs it, every index in pose order and every
    /// vector in the pose's model space.
    public struct Skeleton: Sendable {
        public var parents: [Int?]
        /// The bind pose. Head, neck, hands and digits are set relative to
        /// it, so it must be the pose the skeleton was modelled in.
        public var rest: [JointPose]
        /// Hips to chest, exclusive of the hips: the joints a lean bends.
        public var spine: [Int]
        public var neck: Int?
        public var head: Int
        public var jaw: Int?
        /// Shoulder or upper arm through hand. The last three are solved.
        public var leftArm: [Int]
        public var rightArm: [Int]
        public var leftDigits: Digits?
        public var rightDigits: Digits?
        /// Which way the avatar faces, and up, in model space.
        public var forward: SIMD3<Float>
        public var up: SIMD3<Float>

        public init(parents: [Int?], rest: [JointPose], spine: [Int], neck: Int?, head: Int, jaw: Int?,
                    leftArm: [Int], rightArm: [Int], leftDigits: Digits?, rightDigits: Digits?,
                    forward: SIMD3<Float>, up: SIMD3<Float>) {
            self.parents = parents
            self.rest = rest
            self.spine = spine
            self.neck = neck
            self.head = head
            self.jaw = jaw
            self.leftArm = leftArm
            self.rightArm = rightArm
            self.leftDigits = leftDigits
            self.rightDigits = rightDigits
            self.forward = forward
            self.up = up
        }
    }

    /// Tuning, all of it worth changing live.
    public struct Tuning: Sendable, Equatable {
        /// Share of the head's turn the neck takes; the head takes the rest.
        public var neckShare: Float = 0.4
        /// Share of the head's yaw the chest follows, and its limit.
        public var torsoYawShare: Float = 0.3
        public var torsoYawLimit: Float = 25 * .pi / 180
        /// How far a lean may bend the spine.
        public var leanLimit: Float = 35 * .pi / 180
        /// How wide the jaw opens at `mouthOpen` 1.
        public var jawOpen: Float = 16 * .pi / 180
        /// Seconds to ease a hand in when it appears, and out when it goes.
        public var handFadeIn: Float = 0.15
        public var handFadeOut: Float = 0.5
        /// How long a hand that drops out of tracking is held where it was
        /// last seen before it starts to fade. Hand tracking blinks out for a
        /// few frames all the time — a hand turned edge-on, fingers crossing —
        /// and dropping to the base pose for each blink reads as flicker.
        public var handHold: Float = 0.35
        /// Share of the wrist's twist the forearm takes.
        public var forearmTwistShare: Float = 0.5
        public init() {}
    }

    /// What the last solve did, for a debug readout.
    public struct Report: Sendable, Equatable {
        public var leftWeight: Float = 0
        public var rightWeight: Float = 0
        public var headDegrees: Float = 0
        public var leanDegrees: Float = 0
        public var leftReach: Float = .nan
        public var rightReach: Float = .nan
    }

    public let skeleton: Skeleton
    public var tuning = Tuning()
    public private(set) var report = Report()

    private let solver: PoseSolver
    private let restModel: [float4x4]
    /// The avatar's body frame (x = its left, y = up, z = forward) as a
    /// rotation from body coordinates into model space.
    private let avatarFrame: simd_quatf
    private let leftArmChain: PoseSolver.Chain
    private let rightArmChain: PoseSolver.Chain
    private let armLength: Float
    /// Each hand's palm frame in the hand joint's own space.
    private let leftPalm: simd_quatf?
    private let rightPalm: simd_quatf?
    /// Per digit joint, the bone's direction in the joint's own space, for
    /// the last joint of a chain, which has no child to measure to.
    private let boneAxis: [Int: SIMD3<Float>]
    /// Finger chains (by root) whose first joint sits inside the palm — a
    /// metacarpal — so the knuckle bend belongs to the second.
    private let metacarpals: Set<Int>
    private let jawAxisSign: Float
    private var weights: (left: Float, right: Float) = (0, 0)
    /// Each avatar hand's last tracked performer hand, and how long it has
    /// been gone: what a dropout holds, and what a real loss fades from.
    private var held: (left: PerformerHand?, right: PerformerHand?) = (nil, nil)
    private var lost: (left: Float, right: Float) = (0, 0)

    public init?(_ skeleton: Skeleton) {
        let count = skeleton.rest.count
        guard skeleton.parents.count == count, skeleton.head < count,
              skeleton.leftArm.count >= 3, skeleton.rightArm.count >= 3 else { return nil }
        let solver = PoseSolver(parents: skeleton.parents)
        guard let left = solver.chain(Array(skeleton.leftArm.suffix(3))),
              let right = solver.chain(Array(skeleton.rightArm.suffix(3))) else { return nil }
        self.skeleton = skeleton
        self.solver = solver
        self.leftArmChain = left
        self.rightArmChain = right
        let model = solver.modelMatrices(of: skeleton.rest)
        self.restModel = model
        func position(_ i: Int) -> SIMD3<Float> { PoseSolver.translation(of: model[i]) }

        let up = simd_normalize(skeleton.up)
        var forward = skeleton.forward - simd_dot(skeleton.forward, up) * up
        forward = simd_length(forward) > 1e-5 ? simd_normalize(forward) : SIMD3<Float>(0, 0, 1)
        avatarFrame = Self.frame(up: up, forward: forward)

        func reach(_ chain: [Int]) -> Float {
            let c = Array(chain.suffix(3))
            return simd_distance(position(c[0]), position(c[1])) + simd_distance(position(c[1]), position(c[2]))
        }
        armLength = (reach(skeleton.leftArm) + reach(skeleton.rightArm)) / 2

        // A finger whose first joint is much nearer the wrist than its
        // second starts with a metacarpal: VRChat rigs such as the Synth carry
        // one (`Index_Base`, 5 cm from the wrist, then `Index_1` at the
        // knuckle 13 cm out); Mixamo's start at the knuckle. Matched from the
        // tip without knowing that, every joint took the bone one further
        // along, and a curl folded the palm.
        var inPalm: Set<Int> = []
        for (hand, digits) in [(skeleton.leftArm.last!, skeleton.leftDigits),
                               (skeleton.rightArm.last!, skeleton.rightDigits)] {
            for chain in digits?.fingers ?? [] where chain.count >= 2 {
                let root = simd_distance(position(hand), position(chain[0]))
                let next = simd_distance(position(hand), position(chain[1]))
                if next > 1e-6, root / next < 0.55 { inPalm.insert(chain[0]) }
            }
        }
        metacarpals = inPalm

        func palm(hand: Int, digits: Digits?) -> simd_quatf? {
            guard let digits, let frame = Self.avatarPalm(digits: digits, hand: hand, metacarpals: inPalm,
                                                          position: position) else {
                return nil
            }
            return simd_normalize(PoseSolver.rotation(of: model[hand]).inverse * frame)
        }
        leftPalm = palm(hand: skeleton.leftArm.last!, digits: skeleton.leftDigits)
        rightPalm = palm(hand: skeleton.rightArm.last!, digits: skeleton.rightDigits)

        var axes: [Int: SIMD3<Float>] = [:]
        for digits in [skeleton.leftDigits, skeleton.rightDigits].compactMap({ $0 }) {
            for chain in (digits.thumb.map { [$0] } ?? []) + digits.fingers {
                guard let last = chain.last, let parent = skeleton.parents[last] else { continue }
                let along = position(last) - position(parent)
                guard simd_length(along) > 1e-6 else { continue }
                axes[last] = PoseSolver.rotation(of: model[last]).inverse.act(simd_normalize(along))
            }
        }
        boneAxis = axes

        // Which way about the avatar's lateral axis lowers the chin.
        var sign: Float = 1
        if let jaw = skeleton.jaw, jaw < count {
            let children = (0..<count).filter { skeleton.parents[$0] == jaw }
            let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
            let chin: SIMD3<Float>
            if let child = children.first {
                chin = position(child) - position(jaw)
            } else {
                chin = forward
            }
            sign = simd_dot(simd_cross(lateral, chin), -up) >= 0 ? 1 : -1
        }
        jawAxisSign = sign
    }

    /// Clears the hand weights, so the next solve eases in from the base pose.
    public mutating func reset() {
        weights = (0, 0)
        held = (nil, nil)
        lost = (0, 0)
    }

    // MARK: - Solving

    /// The base pose with the performer laid over it.
    ///
    /// - Parameters:
    ///   - base: this frame's pose before the performer — an idle clip, or the
    ///     rest pose. Joints the performer does not reach keep it.
    ///   - frame: nil when nothing is tracked at all; the hands then ease out
    ///     and the head and spine keep the base pose.
    ///   - mirrored: solve the performer's reflection (an avatar facing them).
    ///   - mouthOpen: 0 closed to 1 wide.
    public mutating func solve(base: [JointPose], frame: PerformerFrame?, calibration: PerformerCalibration,
                               mirrored: Bool, mouthOpen: Float = 0, deltaTime: Float) -> [JointPose] {
        guard base.count == skeleton.rest.count else { return base }
        var pose = base
        var report = Report()

        let performer = Self.frame(up: SIMD3<Float>(0, 1, 0), forward: calibration.forward)
        let reflect = Self.reflection(mirrored)
        // Tracking-space direction → model-space direction, via body
        // coordinates, reflected for a mirror.
        func toModel(_ v: SIMD3<Float>) -> SIMD3<Float> {
            avatarFrame.act(reflect * performer.inverse.act(v))
        }
        func rotationToModel(_ q: simd_quatf) -> simd_quatf {
            var body = performer.inverse * q * performer
            if mirrored { body = simd_quatf(ix: body.imag.x, iy: -body.imag.y, iz: -body.imag.z, r: body.real) }
            return simd_normalize(avatarFrame * body * avatarFrame.inverse)
        }

        let k = calibration.height / 1.70
        let live: (left: PerformerHand?, right: PerformerHand?) = mirrored
            ? (frame?.right, frame?.left) : (frame?.left, frame?.right)
        func ease(_ current: Float, tracked: Bool) -> Float {
            let seconds = tracked ? tuning.handFadeIn : tuning.handFadeOut
            let step = seconds > 0 ? deltaTime / seconds : 1
            return tracked ? min(1, current + step) : max(0, current - step)
        }
        /// The hand to pose this frame and whether it counts as tracked: the
        /// live one, or the last one seen — held at full weight through a
        /// short dropout, then faded from rather than dropped.
        func resolve(_ hand: PerformerHand?, held: inout PerformerHand?, lost: inout Float,
                     weight: inout Float) -> PerformerHand? {
            if let hand, hand.isComplete {
                held = hand
                lost = 0
                weight = ease(weight, tracked: true)
                return hand
            }
            lost += deltaTime
            weight = ease(weight, tracked: lost < tuning.handHold && held != nil)
            if weight <= 0 { held = nil }
            return held
        }
        let hands = (left: resolve(live.left, held: &held.left, lost: &lost.left, weight: &weights.left),
                     right: resolve(live.right, held: &held.right, lost: &lost.right, weight: &weights.right))
        report.leftWeight = weights.left
        report.rightWeight = weights.right

        var model = solver.modelMatrices(of: pose)
        var bodyTurn = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        var shoulders: (left: SIMD3<Float>, right: SIMD3<Float>)?

        if let frame {
            // The head's turn away from looking straight down `forward`.
            let neutral = Self.neutralHead(performer: performer)
            let headTurn = simd_normalize(frame.headRotation * neutral.inverse)
            let headInModel = rotationToModel(headTurn)
            report.headDegrees = headTurn.angle * 180 / .pi

            // The torso, as a segment pivoting at hips the headset can't see:
            // the top of the neck (behind and below the eyes) moved off where
            // it sits when neutral is the lean.
            let atlasOffset = SIMD3<Float>(0, -0.07, 0.08) * k
            let atlas = frame.head + frame.headRotation.act(atlasOffset)
            let neutralAtlas = calibration.head + neutral.act(atlasOffset)
            let neckBase = neutralAtlas - SIMD3<Float>(0, 0.11 * k, 0)
            let hips = neckBase - SIMD3<Float>(0, 0.29 * calibration.height, 0)
            var lean = PoseSolver.rotation(from: simd_normalize(neutralAtlas - hips),
                                           to: simd_normalize(atlas - hips))
            if lean.angle > tuning.leanLimit {
                lean = simd_quatf(angle: tuning.leanLimit, axis: lean.axis)
            }
            report.leanDegrees = lean.angle * 180 / .pi
            // A share of where the head points, for the chest to follow.
            let lookBody = performer.inverse.act(headTurn.act(calibration.forward))
            let yaw = max(-tuning.torsoYawLimit,
                          min(tuning.torsoYawLimit, atan2(lookBody.x, lookBody.z) * tuning.torsoYawShare))
            let torsoTracking = simd_normalize(lean * performer * simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                                               * performer.inverse)
            bodyTurn = rotationToModel(torsoTracking)

            // The performer's shoulders ride the same torso.
            let lateral = performer.act(SIMD3<Float>(1, 0, 0))
            let currentNeck = hips + torsoTracking.act(neckBase - hips)
            func shoulder(_ side: Float) -> SIMD3<Float> {
                currentNeck + torsoTracking.act(lateral * (0.17 * k * side) - SIMD3<Float>(0, 0.03 * k, 0))
            }
            // Body x is the performer's left.
            shoulders = (shoulder(1), shoulder(-1))

            // Spine: the turn spread evenly up the chain, each joint on top
            // of the base pose.
            if !skeleton.spine.isEmpty {
                let part = simd_slerp(Self.identity, bodyTurn, 1 / Float(skeleton.spine.count))
                for joint in skeleton.spine {
                    turn(joint, by: part, pose: &pose, model: &model)
                }
            }

            // Neck and head: set absolutely against the bind pose, since the
            // performer's head is absolute too.
            if let neck = skeleton.neck {
                let neckTurn = simd_slerp(bodyTurn, headInModel, tuning.neckShare)
                set(neck, modelRotation: neckTurn * PoseSolver.rotation(of: restModel[neck]),
                    pose: &pose, model: &model)
            }
            set(skeleton.head, modelRotation: headInModel * PoseSolver.rotation(of: restModel[skeleton.head]),
                pose: &pose, model: &model)
        }

        if let jaw = skeleton.jaw, mouthOpen > 0.001 {
            let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
            let open = simd_quatf(angle: jawAxisSign * tuning.jawOpen * min(mouthOpen, 1), axis: lateral)
            turn(jaw, by: open, pose: &pose, model: &model)
        }

        // Arms and hands, each side on its own weight.
        model = solver.modelMatrices(of: pose)
        let scale = armLength / (0.332 * calibration.height)
        for side in [Side.left, .right] {
            let weight = side == .left ? weights.left : weights.right
            guard weight > 0.001, let hand = side == .left ? hands.left : hands.right,
                  let shoulders else { continue }
            // Mirrored, the avatar's left hand is the performer's right, so it
            // is measured from the performer's right shoulder.
            let performerShoulder = (side == .left) != mirrored ? shoulders.left : shoulders.right
            let chain = side == .left ? leftArmChain : rightArmChain
            let upper = chain.joints[0], hand_ = chain.joints[2]
            let shoulderModel = PoseSolver.translation(of: model[upper])
            let target = shoulderModel + toModel(hand.wrist - performerShoulder) * scale

            // The elbow goes where the forearm points back to; without a
            // forearm, out, down and a little back.
            var pole: SIMD3<Float>
            if let forearm = hand.forearm, simd_distance(forearm, hand.wrist) > 0.02 {
                let elbow = hand.wrist + simd_normalize(forearm - hand.wrist) * 0.146 * calibration.height
                pole = toModel(elbow - performerShoulder)
            } else {
                let out: Float = side == .left ? 1 : -1
                pole = avatarFrame.act(simd_normalize(SIMD3<Float>(0.45 * out, -0.8, -0.35)))
            }
            let reached = solver.solveLeg(chain: chain, target: target, pole: pole, weight: weight,
                                          pose: &pose, model: &model)
            if side == .left { report.leftReach = reached.error } else { report.rightReach = reached.error }

            let palm = side == .left ? leftPalm : rightPalm
            let digits = side == .left ? skeleton.leftDigits : skeleton.rightDigits
            if let palm, let digits,
               let wanted = Self.performerPalm(hand, digits: digits, toModel: toModel) {
                orientHand(hand_, forearm: chain.joints[1], to: wanted * palm.inverse, weight: weight,
                           pose: &pose, model: &model)
            }
            if let digits {
                pointDigits(digits, along: hand, toModel: toModel, weight: weight, pose: &pose, model: &model)
            }
        }

        self.report = report
        return pose
    }

    private enum Side { case left, right }

    // MARK: - Joint writes

    private static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    /// Turns `joint` by a model-space rotation on top of what it has.
    private func turn(_ joint: Int, by rotation: simd_quatf, pose: inout [JointPose], model: inout [float4x4]) {
        let current = currentModel(joint, pose: pose, model: model)
        set(joint, modelRotation: rotation * PoseSolver.rotation(of: current), pose: &pose, model: &model)
    }

    /// Gives `joint` a model-space rotation, keeping its translation.
    private func set(_ joint: Int, modelRotation: simd_quatf, pose: inout [JointPose], model: inout [float4x4]) {
        let parentModel = parentMatrix(of: joint, model: model)
        let parentRotation = PoseSolver.rotation(of: parentModel)
        pose[joint].rotation = simd_normalize(parentRotation.inverse * modelRotation)
        model[joint] = parentModel * pose[joint].matrix
        refresh(below: joint, pose: pose, model: &model)
    }

    private func parentMatrix(of joint: Int, model: [float4x4]) -> float4x4 {
        skeleton.parents[joint].flatMap { $0 >= 0 && $0 < model.count ? model[$0] : nil } ?? matrix_identity_float4x4
    }

    /// The joint's model matrix from its parent's current one — never stale,
    /// whatever was written above it since `model` was last refreshed.
    private func currentModel(_ joint: Int, pose: [JointPose], model: [float4x4]) -> float4x4 {
        parentMatrix(of: joint, model: model) * pose[joint].matrix
    }

    /// Keeps the model matrices under `joint` current after it moved.
    private func refresh(below joint: Int, pose: [JointPose], model: inout [float4x4]) {
        var moved: Set<Int> = [joint]
        for i in solver.order where i != joint {
            if let p = skeleton.parents[i], moved.contains(p) {
                model[i] = model[p] * pose[i].matrix
                moved.insert(i)
            }
        }
    }

    // MARK: - Hands

    private func orientHand(_ hand: Int, forearm: Int, to wanted: simd_quatf, weight: Float,
                            pose: inout [JointPose], model: inout [float4x4]) {
        let current = PoseSolver.rotation(of: currentModel(hand, pose: pose, model: model))
        let target = simd_slerp(current, simd_normalize(wanted), weight)
        // Give the forearm its share of the twist about its own length, so
        // the wrist does not wring.
        let forearmModel = currentModel(forearm, pose: pose, model: model)
        let forearmRotation = PoseSolver.rotation(of: forearmModel)
        let along = pose[hand].translation
        if simd_length(along) > 1e-6, tuning.forearmTwistShare > 0 {
            // The change the hand is about to make, in the forearm's frame;
            // its twist about the bone is the part the forearm shares.
            let local = simd_normalize(forearmRotation.inverse * target)
            let change = simd_normalize(local * pose[hand].rotation.inverse)
            let axis = simd_normalize(along)
            let twist = Self.twist(of: change, about: axis)
            let share = simd_slerp(Self.identity, twist, tuning.forearmTwistShare)
            set(forearm, modelRotation: forearmRotation * share, pose: &pose, model: &model)
        }
        set(hand, modelRotation: target, pose: &pose, model: &model)
    }

    /// The part of `q` that turns about `axis`.
    static func twist(of q: simd_quatf, about axis: SIMD3<Float>) -> simd_quatf {
        let projected = simd_dot(q.imag, axis) * axis
        let t = simd_quatf(ix: projected.x, iy: projected.y, iz: projected.z, r: q.real)
        return simd_length(t.vector) > 1e-6 ? simd_normalize(t) : identity
    }

    /// Which performer fingers each avatar finger stands for, by count.
    static func fingerGroups(avatarFingers: Int) -> [[Int]] {
        switch avatarFingers {
        case 0: []
        case 1: [[0, 1, 2, 3]]
        case 2: [[0], [1, 2, 3]]
        case 3: [[0], [1], [2, 3]]
        default: (0..<avatarFingers).map { [min($0, 3)] }
        }
    }

    /// A palm frame from where the fingers start: across from the outermost
    /// finger toward the thumb side, along toward the fingers, and the normal
    /// they make. Built the same way on both sides of the rig, so the rotation
    /// between them is the hand's.
    static func palmFrame(base: SIMD3<Float>, fingerRoots: [SIMD3<Float>],
                          thumbRoot: SIMD3<Float>?) -> simd_quatf? {
        guard let first = fingerRoots.first else { return nil }
        let middle = fingerRoots.reduce(.zero, +) / Float(fingerRoots.count)
        let along = middle - base
        guard simd_length(along) > 1e-6 else { return nil }
        let l = simd_normalize(along)
        var across: SIMD3<Float>
        if fingerRoots.count >= 2 {
            across = first - fingerRoots[fingerRoots.count - 1]
        } else if let thumbRoot {
            across = thumbRoot - first
        } else {
            return nil
        }
        across -= simd_dot(across, l) * l
        guard simd_length(across) > 1e-6 else { return nil }
        let a = simd_normalize(across)
        let n = simd_cross(l, a)
        return simd_normalize(simd_quatf(float3x3(a, n, l)))
    }

    /// Built from the knuckles, as the performer's is: a metacarpal's root
    /// sits in the wrist and says little about where the palm points.
    private static func avatarPalm(digits: Digits, hand: Int, metacarpals: Set<Int>,
                                   position: (Int) -> SIMD3<Float>) -> simd_quatf? {
        let knuckles = digits.fingers.compactMap { chain -> SIMD3<Float>? in
            guard let root = chain.first else { return nil }
            return position(metacarpals.contains(root) && chain.count >= 2 ? chain[1] : root)
        }
        return palmFrame(base: position(hand), fingerRoots: knuckles, thumbRoot: digits.thumb?.first.map(position))
    }

    /// The performer's palm in model space, built from the knuckles of the
    /// fingers each avatar finger stands for, so both palms span the same
    /// fingers.
    private static func performerPalm(_ hand: PerformerHand, digits: Digits,
                                      toModel: (SIMD3<Float>) -> SIMD3<Float>) -> simd_quatf? {
        let groups = fingerGroups(avatarFingers: digits.fingers.count)
        let roots = groups.map { group in
            group.compactMap { hand.knuckle($0) }.reduce(.zero, +) / Float(max(group.count, 1))
        }
        // Mapped as offsets from the wrist; the frame needs only directions.
        return palmFrame(base: .zero, fingerRoots: roots.map { toModel($0 - hand.wrist) },
                         thumbRoot: hand.thumb.first.map { toModel($0 - hand.wrist) })
    }

    // MARK: - Digits

    private func pointDigits(_ digits: Digits, along hand: PerformerHand,
                             toModel: (SIMD3<Float>) -> SIMD3<Float>, weight: Float,
                             pose: inout [JointPose], model: inout [float4x4]) {
        func direction(_ points: [SIMD3<Float>], _ bone: (Int, Int)) -> SIMD3<Float>? {
            guard bone.1 < points.count else { return nil }
            let v = toModel(points[bone.1] - points[bone.0])
            return simd_length(v) > 1e-7 ? simd_normalize(v) : nil
        }
        if let thumb = digits.thumb {
            let bones = Self.thumbBones(joints: thumb.count)
            point(thumb, along: bones.map { $0.flatMap { direction(hand.thumb, $0) } },
                  weight: weight, pose: &pose, model: &model)
        }
        let groups = Self.fingerGroups(avatarFingers: digits.fingers.count)
        for (chain, group) in zip(digits.fingers, groups) {
            let bones = Self.fingerBones(joints: chain.count,
                                         metacarpal: chain.first.map(metacarpals.contains) ?? false)
            let sources = group.filter { $0 < hand.fingers.count }.map { hand.fingers[$0] }
            // Each avatar bone along the mean of the performer bones it stands
            // for.
            let wanted = bones.map { bone -> SIMD3<Float>? in
                guard let bone else { return nil }
                let sum = sources.compactMap { direction($0, bone) }.reduce(SIMD3<Float>.zero, +)
                return simd_length(sum) > 1e-6 ? simd_normalize(sum) : nil
            }
            point(chain, along: wanted, weight: weight, pose: &pose, model: &model)
        }
    }

    /// Which performer bone each avatar finger joint follows, as indices into
    /// a finger's points (metacarpal base 0, knuckle 1, the two finger joints
    /// 2 and 3, tip 4), or nil to leave a joint as the base pose has it.
    ///
    /// Matched from the knuckle out, so the bend lands at the knuckle on any
    /// rig. A finger with fewer phalanges than a hand takes the chord of the
    /// ones it lacks: two phalanges are knuckle-to-middle and middle-to-tip.
    static func fingerBones(joints: Int, metacarpal: Bool) -> [(Int, Int)?] {
        func phalanges(_ n: Int) -> [(Int, Int)?] {
            switch n {
            case ..<1: []
            case 1: [(1, 4)]
            case 2: [(1, 2), (2, 4)]
            default: Array(repeating: nil, count: n - 3) + [(1, 2), (2, 3), (3, 4)]
            }
        }
        return metacarpal && joints >= 2 ? [(0, 1)] + phalanges(joints - 1) : phalanges(joints)
    }

    /// The thumb's version: its points are the base (0), the two knuckles and
    /// the tip (3), and an avatar thumb's first joint is always its
    /// metacarpal, on every rig seen so far.
    static func thumbBones(joints: Int) -> [(Int, Int)?] {
        switch joints {
        case ..<1: []
        case 1: [(0, 3)]
        case 2: [(0, 1), (1, 3)]
        default: Array(repeating: nil, count: joints - 3) + [(0, 1), (1, 2), (2, 3)]
        }
    }

    /// Points each joint of `chain` along its wanted bone direction, root
    /// first; a nil direction leaves that joint as it is.
    private func point(_ chain: [Int], along wanted: [SIMD3<Float>?], weight: Float,
                       pose: inout [JointPose], model: inout [float4x4]) {
        for (offset, joint) in chain.enumerated() {
            guard offset < wanted.count, let target = wanted[offset] else { continue }
            let here = currentModel(joint, pose: pose, model: model)
            let origin = PoseSolver.translation(of: here)
            let now: SIMD3<Float>
            if offset + 1 < chain.count {
                let child = chain[offset + 1]
                now = PoseSolver.translation(of: here * pose[child].matrix) - origin
            } else if let axis = boneAxis[joint] {
                now = PoseSolver.rotation(of: here).act(axis)
            } else {
                continue
            }
            guard simd_length(now) > 1e-7 else { continue }
            var rotation = PoseSolver.rotation(from: simd_normalize(now), to: target)
            if weight < 0.999 { rotation = simd_slerp(Self.identity, rotation, weight) }
            set(joint, modelRotation: rotation * PoseSolver.rotation(of: here), pose: &pose, model: &model)
        }
    }

    // MARK: - Frames

    /// A body frame — x to its left, y up, z forward — as a rotation from body
    /// coordinates. x = up × forward keeps the frame right-handed.
    static func frame(up: SIMD3<Float>, forward: SIMD3<Float>) -> simd_quatf {
        let x = simd_normalize(simd_cross(up, forward))
        return simd_normalize(simd_quatf(float3x3(x, up, forward)))
    }

    /// The head's orientation when it looks straight down the performer's
    /// forward: its −Z forward, +Y up, +X to the performer's right.
    static func neutralHead(performer: simd_quatf) -> simd_quatf {
        let left = performer.act(SIMD3<Float>(1, 0, 0))
        let up = performer.act(SIMD3<Float>(0, 1, 0))
        let forward = performer.act(SIMD3<Float>(0, 0, 1))
        return simd_normalize(simd_quatf(float3x3(-left, up, -forward)))
    }

    /// The reflection through the body's midline (x → −x), or nothing.
    static func reflection(_ mirrored: Bool) -> float3x3 {
        mirrored ? float3x3(diagonal: SIMD3<Float>(-1, 1, 1)) : matrix_identity_float3x3
    }
}

// MARK: - Smoothing

/// The 1€ filter (Casiez, Roussel and Vogel, 2012): a low-pass whose cutoff
/// rises with speed, so a still hand stops jittering and a fast one does not
/// lag. Tracking noise is worst exactly when the hand is still, which is
/// where a fixed low-pass is either too weak or, made strong enough, turns
/// every gesture to treacle.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Float
    public var beta: Float
    public var derivativeCutoff: Float
    private var value: SIMD3<Float>?
    private var derivative = SIMD3<Float>.zero

    public init(minCutoff: Float = 1.2, beta: Float = 8, derivativeCutoff: Float = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func reset() { value = nil; derivative = .zero }

    public mutating func filter(_ x: SIMD3<Float>, deltaTime: Float) -> SIMD3<Float> {
        guard let previous = value, deltaTime > 0 else {
            value = x
            return x
        }
        func alpha(_ cutoff: Float) -> Float {
            let tau = 1 / (2 * .pi * cutoff)
            return 1 / (1 + tau / deltaTime)
        }
        let rawDerivative = (x - previous) / deltaTime
        derivative += alpha(derivativeCutoff) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * simd_length(derivative)
        let next = previous + alpha(cutoff) * (x - previous)
        value = next
        return next
    }
}

/// Smooths whole performer frames: every hand point through its own 1€
/// filter, the head through a light one. A hand gone longer than a tracking
/// blink resets its filters, so it comes back where it is, not gliding from
/// where it went; one that blinks keeps them, and picks up where it left off.
public struct PerformerSmoothing: Sendable {
    private var head = OneEuroFilter(minCutoff: 2.5, beta: 4)
    private var hands: [[OneEuroFilter]] = [[], []]
    private var missing: [Float] = [0, 0]
    /// Longer than `PerformerRig.Tuning.handHold`: a hand still held is still
    /// the same hand.
    public var forgetAfter: Float = 0.5

    public init() {}

    public mutating func reset() {
        head.reset()
        hands = [[], []]
        missing = [0, 0]
    }

    public mutating func smooth(_ frame: PerformerFrame, deltaTime: Float) -> PerformerFrame {
        var out = frame
        out.head = head.filter(frame.head, deltaTime: deltaTime)
        out.left = smooth(frame.left, slot: 0, deltaTime: deltaTime)
        out.right = smooth(frame.right, slot: 1, deltaTime: deltaTime)
        return out
    }

    private mutating func smooth(_ hand: PerformerHand?, slot: Int, deltaTime: Float) -> PerformerHand? {
        guard var hand else {
            missing[slot] += deltaTime
            if missing[slot] > forgetAfter { hands[slot] = [] }
            return nil
        }
        missing[slot] = 0
        var points = [hand.wrist] + hand.thumb + hand.fingers.flatMap { $0 }
        if let forearm = hand.forearm { points.append(forearm) }
        if hands[slot].count != points.count {
            hands[slot] = Array(repeating: OneEuroFilter(), count: points.count)
        }
        for i in points.indices {
            points[i] = hands[slot][i].filter(points[i], deltaTime: deltaTime)
        }
        var cursor = 0
        func take(_ n: Int) -> [SIMD3<Float>] {
            defer { cursor += n }
            return Array(points[cursor..<(cursor + n)])
        }
        hand.wrist = take(1)[0]
        hand.thumb = take(hand.thumb.count)
        hand.fingers = hand.fingers.map { take($0.count) }
        if hand.forearm != nil { hand.forearm = take(1)[0] }
        return hand
    }
}
