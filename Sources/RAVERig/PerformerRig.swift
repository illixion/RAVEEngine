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

    /// Every point moved by `offset`.
    func translated(by offset: SIMD3<Float>) -> PerformerHand {
        PerformerHand(wrist: wrist + offset, forearm: forearm.map { $0 + offset },
                      thumb: thumb.map { $0 + offset }, fingers: fingers.map { $0.map { $0 + offset } })
    }

    /// Each point moved `amount` of the way toward `other`'s. A hand shaped
    /// differently (another joint count) is simply `other`.
    func moved(toward other: PerformerHand, by amount: Float) -> PerformerHand {
        guard thumb.count == other.thumb.count, fingers.count == other.fingers.count,
              zip(fingers, other.fingers).allSatisfy({ $0.count == $1.count }) else { return other }
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * amount }
        let arm: SIMD3<Float>? = if let forearm, let theirs = other.forearm { mix(forearm, theirs) } else { other.forearm }
        return PerformerHand(wrist: mix(wrist, other.wrist), forearm: arm,
                             thumb: zip(thumb, other.thumb).map(mix),
                             fingers: zip(fingers, other.fingers).map { zip($0, $1).map(mix) })
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
    public var torso: PerformerTorso? = nil
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

public struct PerformerTorso: Sendable, Equatable {
    /// Anatomical body frame (+X left, +Y up, +Z forward), in tracking space.
    public var rotation: simd_quatf
    public var weight: Float
    public init(rotation: simd_quatf, weight: Float) { self.rotation = rotation; self.weight = weight }
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

    // The body the rig fits under a tracked head, scaled from a 1.70 m
    // performer: the top of the neck (behind and below the eyes), the neck's
    // base, and the shoulders either side of it.
    static let atlasOffset = SIMD3<Float>(0, -0.07, 0.08)
    static let neckDrop: Float = 0.11
    static let shoulderHalfWidth: Float = 0.17
    static let shoulderDrop: Float = 0.03

    var proportion: Float { height / 1.70 }

    /// The base of the neck when the performer stands as calibrated.
    public var neutralNeck: SIMD3<Float> {
        let neutral = PerformerRig.neutralHead(performer: PerformerRig.frame(up: SIMD3<Float>(0, 1, 0),
                                                                             forward: forward))
        return head + neutral.act(Self.atlasOffset * proportion) - SIMD3<Float>(0, Self.neckDrop * proportion, 0)
    }

    /// Where the rig puts the performer's shoulders when they stand as
    /// calibrated: what it measures each wrist from.
    public var neutralShoulders: (left: SIMD3<Float>, right: SIMD3<Float>) {
        let left = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        let neck = neutralNeck - SIMD3<Float>(0, Self.shoulderDrop * proportion, 0)
        return (neck + left * Self.shoulderHalfWidth * proportion, neck - left * Self.shoulderHalfWidth * proportion)
    }

    /// Shoulder to wrist, as the rig assumes it from the height.
    public var armLength: Float { 0.332 * height }

    /// The base of the neck to the hip joints, of the height.
    static let hipsDrop: Float = 0.29
    /// The eyes' height over the floor standing, of the height.
    static let eyeHeight: Float = 0.936

    /// Between the hip joints when the performer stands as calibrated: what
    /// a lean pivots about, and where a pelvis is measured from.
    public var neutralHips: SIMD3<Float> { neutralNeck - SIMD3<Float>(0, Self.hipsDrop * height, 0) }

    /// Hip joint to the floor, standing, as the rig assumes it from the height.
    public var legLength: Float { 0.53 * height }
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
        /// Thigh, knee, ankle, then the ball of the foot if there is one: a
        /// digitigrade leg's raised hock is its ankle. Nil finds them: the
        /// two limbs hanging off the hips, each joint's lowest child the next.
        public var leftLeg: [Int]?
        public var rightLeg: [Int]?
        /// Which way the avatar faces, and up, in model space.
        public var forward: SIMD3<Float>
        public var up: SIMD3<Float>

        public init(parents: [Int?], rest: [JointPose], spine: [Int], neck: Int?, head: Int, jaw: Int?,
                    leftArm: [Int], rightArm: [Int], leftDigits: Digits?, rightDigits: Digits?,
                    leftLeg: [Int]? = nil, rightLeg: [Int]? = nil,
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
            self.leftLeg = leftLeg
            self.rightLeg = rightLeg
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
        /// How far an untracked arm swings forward and back at a full stride.
        public var armSwing: Float = 18 * .pi / 180
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
        /// How strongly the elbow bends out, down and back when the tracked
        /// forearm doesn't say otherwise, in metres off the shoulder-to-hand
        /// line. A forearm-derived elbow further off the line than this
        /// decides the bend; a nearly straight arm falls back to this one.
        public var elbowDefaultBend: Float = 0.05
        /// How quickly the elbow's bend direction follows, seconds.
        public var elbowSmoothing: Float = 0.08
        /// A hand lost while any point of the other (wrist, knuckles,
        /// fingertips, forearm) is this close to it as the eyes see it, or
        /// while the wrists are within `hiddenDistance`, is taken as hidden
        /// behind it: hands held together or crossing in front block the
        /// headset's view of one another all the time.
        public var occlusionAngle: Float = 15 * .pi / 180
        public var hiddenDistance: Float = 0.3
        /// How long a hand hidden behind the other is bridged before it
        /// starts to fade.
        public var occludedHold: Float = 8
        /// A hidden hand that was moving with the other one (within this
        /// speed of it, m/s) moves with it; otherwise it coasts on its own.
        public var togetherSpeed: Float = 0.25
        /// A hand lost while this close to straight ahead can't have left the
        /// view that fast, so something is in front of it. The headset tracks
        /// hands well past this, below the eyes especially: 35° caught hands
        /// waved in front of the chest as leaving.
        public var inViewAngle: Float = 55 * .pi / 180
        /// How long such a hand is held before it starts to fade.
        public var inViewHold: Float = 3
        /// A lost hand keeps moving the way it was going, slowing over this
        /// time constant, seconds, and no faster than `coastSpeed` (m/s): a
        /// hand waved past the other comes out of hiding about where it went
        /// in, and one that reverses mid-wave doesn't overshoot far.
        public var coastTime: Float = 0.15
        public var coastSpeed: Float = 1.2
        /// The other hand counts as there for spotting a hidden one for this
        /// long after it is lost itself: hands crossing each other vanish
        /// within a few frames of one another.
        public var partnerMemory: Float = 0.25
        /// How long a forearm point that blinks out under a tracked hand is
        /// kept, riding the hand's own orientation, seconds. A flat hand at
        /// eye level puts the forearm across the face, where the tracker
        /// keeps losing it, and the elbow jiggled between it and the default.
        public var forearmHold: Float = 1
        /// How quickly a hand that comes back after a loss moves from where
        /// it was bridged to where it is, seconds, and for how long after its
        /// return that easing applies.
        public var returnEasing: Float = 0.08
        public var returnTime: Float = 0.3
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
        /// Being bridged behind the other hand.
        public var leftHidden = false
        public var rightHidden = false
        /// How each hand is being posed: `tracked`, or which bridge holds it
        /// (`blink`, `hidden`, `inView`) with what decided it, or `none`.
        public var leftBridge = "none"
        public var rightBridge = "none"
        /// How far each ankle ended from where the lower body put it, model
        /// units, and how far the pelvis had to drop for the legs to reach.
        public var leftFootError: Float = .nan
        public var rightFootError: Float = .nan
        public var pelvisDrop: Float = 0
        /// How far the own body stands back to keep its skin out of the eyes.
        public var clearance: Float = 0
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
    /// The avatar's shoulder to wrist, both arms averaged, in model units.
    public let armLength: Float
    /// Both legs, left first, when the skeleton has two under its hips: what
    /// `seatLegs` folds and a lower body poses.
    private let legs: [Leg]
    public var hasLegs: Bool { !legs.isEmpty }
    /// The joint the legs and the spine hang from.
    private let hips: Int?
    /// The feet as the bind pose has them, model units: what `footShape` and
    /// `stanceWidth` scale.
    private let feet: Feet?
    /// How far the skin reaches below the lowest joint of a foot, model
    /// units: the sole under the joints. Skeletons don't say; the host can
    /// measure it from the mesh, and the feet then stand on the floor rather
    /// than in it.
    public var soleDepth: Float = 0
    /// The torso's skin, which an own body keeps clear of the eyes, and how
    /// far back it stands for that now (tracking metres).
    private var clearance: EyeClearance?
    private var clearanceStep: Float = 0

    /// One leg as the rig poses it.
    private struct Leg: Sendable {
        var thigh: Int
        var knee: Int
        /// A digitigrade leg's raised hock.
        var ankle: Int
        /// The first joint of each toe pointing forward, where it bends up
        /// off the ball of the foot.
        var toes: [Int]
        var chain: PoseSolver.Chain
        /// Thigh and shin, as built.
        var length: Float
    }

    private struct Feet: Sendable {
        var ankleHeight: Float
        var heel: Float
        var ball: Float
        /// Ankle to ankle across the body.
        var width: Float
        /// The height (along up) of the lowest foot joint, and of the hips.
        var sole: Float
        var hips: Float
    }
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
    private var hands = (left: HandState(), right: HandState())

    /// One avatar hand's tracking story.
    private struct HandState {
        var weight: Float = 0
        /// The last tracked performer hand, or the estimate bridging a loss:
        /// what a dropout holds, and what a real loss fades from.
        var held: PerformerHand?
        /// How long it has been gone, and how long this loss is bridged.
        var lost: Float = 0
        var hold: Float = 0
        /// While hidden behind the other hand and moving with it: that hand's
        /// wrist last frame, so this one follows it.
        var partner: SIMD3<Float>?
        /// The wrist's velocity while tracked (eased), and what a lost hand
        /// coasts on.
        var velocity: SIMD3<Float> = .zero
        var lastWrist: SIMD3<Float>?
        /// How it is being posed, for the report.
        var bridge = "none"
        /// The forearm point in the hand's own frame, and how long since it
        /// was last tracked.
        var forearmLocal: SIMD3<Float>?
        var forearmAge: Float = 0
        /// What was posed last frame, which a returning hand eases from.
        var posed: PerformerHand?
        var sinceReturn: Float = .infinity
        /// The elbow's eased bend direction, off its shoulder-to-hand line.
        var bend: SIMD3<Float>?
    }

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

        // The legs hang from the hips beside the spine. Each joint's lowest
        // child is the next one down: a twist bone or a skirt beside it
        // hangs less far.
        func lowestChild(of joint: Int) -> Int? {
            skeleton.parents.indices.filter { skeleton.parents[$0] == joint }
                .min { simd_dot(position($0), up) < simd_dot(position($1), up) }
        }
        let hips = skeleton.spine.first.flatMap { skeleton.parents[$0] }
        var below: [[Int]] = Array(repeating: [], count: count)
        for (joint, parent) in skeleton.parents.enumerated() {
            if let parent, parent >= 0, parent < count { below[parent].append(joint) }
        }
        func subtree(_ joint: Int) -> [Int] { [joint] + below[joint].flatMap(subtree) }
        // How far forward of the ankle each joint of the foot sits.
        func ahead(_ joint: Int, of ankle: Int) -> Float { simd_dot(position(joint) - position(ankle), forward) }
        func legs(_ chains: [[Int]]) -> [Leg] {
            let found: [Leg] = chains.compactMap { chain in
                guard chain.count >= 3, chain.allSatisfy({ $0 < count }),
                      let solved = solver.chain(Array(chain.prefix(3))) else { return nil }
                // The toes bend where each forward one starts: its first joint
                // a fair way toward the tips. Not simply the next joint down,
                // which on some rigs (the Synth's `Digi_Toes`) sits on the
                // ankle with every toe hanging off it, a rear claw included.
                let ankle = chain[2]
                let foot = subtree(ankle).dropFirst()
                let tip = foot.map { ahead($0, of: ankle) }.max() ?? 0
                let toes = tip > 1e-4 ? foot.filter { joint in
                    ahead(joint, of: ankle) > 0.25 * tip
                        && skeleton.parents[joint].map { $0 == ankle || ahead($0, of: ankle) <= 0.25 * tip } ?? false
                } : []
                return Leg(thigh: chain[0], knee: chain[1], ankle: ankle, toes: toes, chain: solved,
                           length: simd_distance(position(chain[0]), position(chain[1]))
                               + simd_distance(position(chain[1]), position(chain[2])))
            }
            return found.count == 2 ? found : []
        }
        var found: [Leg] = []
        if let left = skeleton.leftLeg, let right = skeleton.rightLeg { found = legs([left, right]) }
        if found.isEmpty, let spineRoot = skeleton.spine.first, let hips {
            var chains: [[Int]] = []
            for thigh in skeleton.parents.indices where skeleton.parents[thigh] == hips && thigh != spineRoot {
                guard let knee = lowestChild(of: thigh), let ankle = lowestChild(of: knee) else { continue }
                // A leg reaches well down, further than an arm is long.
                if simd_dot(position(hips) - position(ankle), up) > armLength * 0.8 {
                    chains.append([thigh, knee, ankle])
                }
            }
            // Left first: the one on the avatar's left.
            let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
            chains.sort { simd_dot(position($0[0]), lateral) > simd_dot(position($1[0]), lateral) }
            found = legs(chains)
        }
        self.legs = found
        self.hips = found.isEmpty ? nil : hips
        // The feet: the ankle's height over the lowest joint of the foot, how
        // far forward the ball is, and how far apart the two stand. A foot
        // carried this high off the floor is a digitigrade one, standing on
        // its toes with no heel to strike with.
        if found.count == 2, let hips {
            // The heel is whatever of the foot reaches back from the ankle
            // (the Synth's rear claw), or a third of the way to the ball when
            // nothing does.
            var ankleHeight: Float = 0, ball: Float = 0, heel: Float = 0, sole: Float = 0
            for leg in found {
                let foot = subtree(leg.ankle)
                let lowest = foot.map { simd_dot(position($0), up) }.min()!
                let height = simd_dot(position(leg.ankle), up) - lowest
                let toes = leg.toes.map { ahead($0, of: leg.ankle) }
                let forwardBall = toes.isEmpty ? 1.6 * height : toes.reduce(0, +) / Float(toes.count)
                let back = -(foot.map { ahead($0, of: leg.ankle) }.min() ?? 0)
                ankleHeight += height / 2
                sole += lowest / 2
                ball += forwardBall / 2
                heel += (back > 0.1 * forwardBall ? back : 0.35 * forwardBall) / 2
            }
            let digitigrade = ankleHeight / max(found[0].length, 1e-4) > LegArchitecture.digitigradeThreshold
            let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
            feet = Feet(ankleHeight: ankleHeight, heel: digitigrade ? 0 : max(heel, 0),
                        ball: max(ball, 0.2 * ankleHeight),
                        width: abs(simd_dot(position(found[0].ankle) - position(found[1].ankle), lateral)),
                        sole: sole, hips: simd_dot(position(hips), up))
        } else {
            feet = nil
        }

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

        // Which way about the avatar's lateral axis lowers the chin. The chin
        // is in front of the hinge on any humanoid, so that is the direction
        // used, not the jaw's children: the Synth's first child is a tongue
        // root behind and below the hinge, and lowering that raised the chin.
        var sign: Float = 1
        if skeleton.jaw != nil {
            let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
            sign = simd_dot(simd_cross(lateral, forward), -up) >= 0 ? 1 : -1
        }
        jawAxisSign = sign
    }

    /// Where to put the avatar's model space in tracking space for it to be
    /// the performer's own body, seen from inside: facing their forward,
    /// sized so its arms are as long as the rig takes theirs to be, and its
    /// shoulders centred on theirs. Solved with this as `placement`, its
    /// hands reach the tracked wrists.
    ///
    /// - Parameter pose: the pose whose shoulders to centre, the base the
    ///   solve will start from (an idle clip sways them); the rest pose when
    ///   nil.
    public func ownBodyPlacement(calibration: PerformerCalibration, pose: [JointPose]? = nil) -> simd_float4x4 {
        let performer = Self.frame(up: SIMD3<Float>(0, 1, 0), forward: calibration.forward)
        // Model → body coordinates → tracking: the inverse of the solve's
        // unmirrored `toModel`.
        let rotation = simd_normalize(performer * avatarFrame.inverse)
        let scale = calibration.armLength / max(armLength, 1e-4)
        let shoulders = calibration.neutralShoulders
        let model = pose.flatMap { $0.count == skeleton.rest.count ? solver.modelMatrices(of: $0) : nil } ?? restModel
        let own = (PoseSolver.translation(of: model[leftArmChain.joints[0]])
                   + PoseSolver.translation(of: model[rightArmChain.joints[0]])) / 2
        let translation = (shoulders.left + shoulders.right) / 2 - rotation.act(own * scale)
        var matrix = simd_float4x4(rotation) * simd_float4x4(diagonal: SIMD4<Float>(scale, scale, scale, 1))
        matrix.columns.3 = SIMD4<Float>(translation, 1)
        return matrix
    }

    /// Tracking metres per model unit in `ownBodyPlacement`: the avatar's arm
    /// length against the performer's.
    public func ownBodyScale(calibration: PerformerCalibration) -> Float {
        calibration.armLength / max(armLength, 1e-4)
    }

    /// The avatar's feet as `PerformerGait` models a foot, at `scale`
    /// (`ownBodyScale`): handed to the gait, it lands this avatar's feet
    /// exactly, heel and ball where its own are. Nil without legs.
    public func footShape(scale: Float) -> PerformerGait.FootShape? {
        guard let feet else { return nil }
        return PerformerGait.FootShape(ankleHeight: (feet.ankleHeight + soleDepth) * scale,
                                       heel: feet.heel * scale, ball: feet.ball * scale)
    }

    /// The lowest foot joint's height along `skeleton.up` as built, model
    /// units: what the skin under the feet is measured from for `soleDepth`.
    public var lowestFootJoint: Float? { feet?.sole }

    /// Ankle to ankle across the avatar's body as built, at `scale`.
    public func stanceWidth(scale: Float) -> Float? {
        feet.map { $0.width * scale }
    }

    /// The legs folded as if on a chair, thighs forward and shins down, by
    /// `weight` (0 leaves them, 1 is seated): for a performer sitting down,
    /// whose own body would otherwise stand through the floor under them.
    public func seatLegs(_ pose: [JointPose], weight: Float) -> [JointPose] {
        guard weight > 0.001, !legs.isEmpty, pose.count == skeleton.rest.count else { return pose }
        var pose = pose
        var model = solver.modelMatrices(of: pose)
        let forward = avatarFrame.act(SIMD3<Float>(0, 0, 1)), up = avatarFrame.act(SIMD3<Float>(0, 1, 0))
        // A seat slopes back a little.
        let thigh = simd_normalize(forward - up * 0.15)
        for leg in legs {
            point([leg.thigh, leg.knee, leg.ankle], along: [thigh, -up], weight: min(weight, 1),
                  pose: &pose, model: &model)
        }
        return pose
    }

    /// Clears the hand weights, so the next solve eases in from the base pose.
    public mutating func reset() {
        hands = (HandState(), HandState())
        clearanceStep = 0
    }

    /// The skin an own body keeps out of the eyes: bind-pose points with the
    /// joint that carries each, from the host's mesh. Only the torso's are
    /// kept, which is everything but the limbs and the head: the arms answer
    /// to the hands, the legs to the feet, and the neck and head an own body
    /// hides. Chest skin can hang off joints beside the spine (the Synth's
    /// ribs), so the torso is what is left rather than a list. `radius` is in
    /// tracking metres.
    public mutating func keepClear(of surface: [(joint: Int, position: SIMD3<Float>)], radius: Float = 0.1) {
        var limbs: Set<Int> = [skeleton.neck ?? skeleton.head]
        for arm in [skeleton.leftArm, skeleton.rightArm] { limbs.insert(arm[arm.count - 3]) }
        for leg in legs { limbs.insert(leg.thigh) }
        func inTorso(_ joint: Int) -> Bool {
            var cursor: Int? = joint
            var steps = 0
            while let at = cursor, steps < skeleton.parents.count {
                if limbs.contains(at) { return false }
                cursor = skeleton.parents[at]
                steps += 1
            }
            return true
        }
        let points = surface.compactMap { point -> EyeClearance.Point? in
            guard point.joint >= 0, point.joint < restModel.count, inTorso(point.joint) else { return nil }
            let local = restModel[point.joint].inverse * SIMD4<Float>(point.position, 1)
            return EyeClearance.Point(joint: point.joint, local: SIMD3<Float>(local.x, local.y, local.z))
        }
        clearance = points.isEmpty ? nil : EyeClearance(points: points, radius: radius)
        clearanceStep = 0
    }

    /// `placement` (`ownBodyPlacement`) moved back as far as the skin needs
    /// to be out of the eyes: what to solve the own body with, and place it by.
    public func cleared(_ placement: simd_float4x4, calibration: PerformerCalibration) -> simd_float4x4 {
        guard clearanceStep > 0 else { return placement }
        var moved = placement
        moved.columns.3 -= SIMD4<Float>(calibration.forward * clearanceStep, 0)
        return moved
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
    ///   - placement: where the avatar's model space sits in tracking space,
    ///     when the avatar is the performer's own body (`ownBodyPlacement`,
    ///     never mirrored). Its hands then reach the tracked wrists
    ///     themselves, not an offset from the estimated shoulders scaled to
    ///     its arms, so they land on the performer's.
    ///   - lowerBody: the pelvis and feet, made up (`PerformerGait`) or
    ///     tracked, for an unmirrored solve. The legs reach the feet, measured
    ///     through `placement` (or the own-body placement when there is none:
    ///     the pose is the same either way), and arms nothing tracks swing
    ///     with the walk. Nil keeps the base pose's legs.
    public mutating func solve(base: [JointPose], frame: PerformerFrame?, calibration: PerformerCalibration,
                               mirrored: Bool, mouthOpen: Float = 0, deltaTime: Float,
                               placement: simd_float4x4? = nil,
                               lowerBody: PerformerLowerBody? = nil) -> [JointPose] {
        guard base.count == skeleton.rest.count else { return base }
        let fromTracking = placement.map { $0.inverse }
        func inModel(_ point: SIMD3<Float>, _ m: simd_float4x4) -> SIMD3<Float> {
            let p = m * SIMD4<Float>(point, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
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
        func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { return .pi }
            return acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
        }
        /// The hand to pose this frame: the live one, or one bridging its
        /// loss. A tracking blink is held where it was; a hand hidden behind
        /// the other moves with that one for `occludedHold`; one lost in plain
        /// view is held a little longer; then it fades rather than drops. A
        /// hand that comes back eases from where it was bridged.
        func resolve(_ hand: PerformerHand?, partner live: PerformerHand?, partnerState: HandState,
                     state: inout HandState) -> PerformerHand? {
            if var hand, hand.isComplete {
                let handFrame = Self.palmFrame(base: hand.wrist, fingerRoots: (0..<4).compactMap { hand.knuckle($0) },
                                               thumbRoot: hand.thumb.first)
                if let forearm = hand.forearm, let handFrame {
                    state.forearmLocal = handFrame.inverse.act(forearm - hand.wrist)
                    state.forearmAge = 0
                } else if hand.forearm == nil, let local = state.forearmLocal, let handFrame,
                          state.forearmAge < tuning.forearmHold {
                    state.forearmAge += deltaTime
                    hand.forearm = hand.wrist + handFrame.act(local)
                }
                if state.lost > 0 { state.sinceReturn = 0 }
                if let last = state.lastWrist, deltaTime > 0 {
                    let velocity = (hand.wrist - last) / deltaTime
                    state.velocity += (velocity - state.velocity) * min(1, deltaTime / 0.05)
                } else {
                    state.velocity = .zero
                }
                state.lastWrist = hand.wrist
                state.held = hand
                state.lost = 0
                state.partner = nil
                state.bridge = "tracked"
                state.weight = ease(state.weight, tracked: true)
                var out = hand
                if state.sinceReturn < tuning.returnTime, let posed = state.posed {
                    state.sinceReturn += deltaTime
                    out = posed.moved(toward: hand, by: tuning.returnEasing > 0
                                      ? min(1, deltaTime / tuning.returnEasing) : 1)
                }
                state.posed = out
                return out
            }
            let partner = live.flatMap { $0.isComplete ? $0 : nil }
            // For spotting a hidden hand, the other one as last seen will do
            // if it went only a moment ago.
            let partnerSeen = partner ?? (partnerState.lost < tuning.partnerMemory ? partnerState.held : nil)
            state.lastWrist = nil
            if state.lost == 0, let held = state.held {
                // Just lost: how long to bridge it depends on why it went.
                state.hold = tuning.handHold
                state.bridge = "blink"
                let speed = simd_length(state.velocity)
                if speed > tuning.coastSpeed { state.velocity *= tuning.coastSpeed / speed }
                if let head = frame?.head, let other = partnerSeen {
                    let points = [other.wrist] + (other.forearm.map { [$0] } ?? []) + other.thumb
                        + other.fingers.flatMap { $0 }
                    let nearest = points.map { angle(held.wrist - head, $0 - head) }.min() ?? .pi
                    let apart = simd_distance(held.wrist, other.wrist)
                    if nearest < tuning.occlusionAngle || apart < tuning.hiddenDistance {
                        state.hold = tuning.occludedHold
                        // Riding needs the other hand in view to ride on.
                        let together = partner != nil
                            && simd_length(state.velocity - partnerState.velocity) < tuning.togetherSpeed
                        if together, let partner { state.partner = partner.wrist }
                        state.bridge = String(format: "hidden %.0f° %.2fm %@", nearest * 180 / .pi, apart,
                                              together ? "riding" : "coasting")
                    }
                }
                if state.bridge == "blink", let frame {
                    let off = angle(held.wrist - frame.head, frame.headRotation.act(SIMD3<Float>(0, 0, -1)))
                    if off < tuning.inViewAngle {
                        state.hold = tuning.inViewHold
                        state.bridge = String(format: "inView %.0f°", off * 180 / .pi)
                    }
                }
            }
            state.lost += deltaTime
            if let anchor = state.partner {
                if let partner {
                    state.held = state.held?.translated(by: partner.wrist - anchor)
                    state.partner = partner.wrist
                } else {
                    // Both gone: nothing left to ride on.
                    state.partner = nil
                    state.hold = min(state.hold, state.lost + tuning.handHold)
                }
            } else if tuning.coastTime > 0, simd_length(state.velocity) > 1e-3 {
                state.held = state.held?.translated(by: state.velocity * deltaTime)
                state.velocity *= exp(-deltaTime / tuning.coastTime)
            }
            state.weight = ease(state.weight, tracked: state.lost < state.hold && state.held != nil)
            if state.lost >= state.hold, state.held != nil { state.bridge = "fading" }
            if state.weight <= 0 {
                state.held = nil
                state.bridge = "none"
            }
            state.posed = state.held
            return state.held
        }
        let posedHands = (left: resolve(live.left, partner: live.right, partnerState: hands.right,
                                        state: &hands.left),
                          right: resolve(live.right, partner: live.left, partnerState: hands.left,
                                         state: &hands.right))
        report.leftWeight = hands.left.weight
        report.rightWeight = hands.right.weight
        report.leftHidden = hands.left.bridge.hasPrefix("hidden")
        report.rightHidden = hands.right.bridge.hasPrefix("hidden")
        report.leftBridge = hands.left.bridge
        report.rightBridge = hands.right.bridge

        var model = solver.modelMatrices(of: pose)
        var bodyTurn = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        var shoulders: (left: SIMD3<Float>, right: SIMD3<Float>)?

        // The pelvis and the legs, when something says where they are: before
        // the spine, whose lean is measured from wherever the pelvis went.
        var pelvisShift = SIMD3<Float>.zero
        if let lowerBody, lowerBody.weight > 0.001, hips != nil {
            let lower = mirrored ? lowerBody.reflected(calibration: calibration) : lowerBody
            let legPlacement = placement ?? ownBodyPlacement(calibration: calibration, pose: base)
            pelvisShift = poseLegs(lower, calibration: calibration, placement: legPlacement, performer: performer,
                                   report: &report, pose: &pose, model: &model)
        }

        if let frame {
            // The head's turn away from looking straight down `forward`.
            let neutral = Self.neutralHead(performer: performer)
            let headTurn = simd_normalize(frame.headRotation * neutral.inverse)
            let headInModel = rotationToModel(headTurn)
            report.headDegrees = headTurn.angle * 180 / .pi

            // The torso, as a segment pivoting at hips the headset can't see:
            // the top of the neck (behind and below the eyes) moved off where
            // it sits when neutral is the lean.
            let atlasOffset = PerformerCalibration.atlasOffset * k
            let atlas = frame.head + frame.headRotation.act(atlasOffset)
            let neutralAtlas = calibration.head + neutral.act(atlasOffset)
            let neckBase = calibration.neutralNeck
            let hips = calibration.neutralHips + pelvisShift
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
            var torsoTracking = simd_normalize(lean * performer * simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                                               * performer.inverse)
            if let torso = frame.torso {
                let measured = simd_normalize(torso.rotation * performer.inverse)
                torsoTracking = simd_slerp(torsoTracking, measured, min(1, max(0, torso.weight)))
            }
            bodyTurn = rotationToModel(torsoTracking)

            // The performer's shoulders ride the same torso.
            let lateral = performer.act(SIMD3<Float>(1, 0, 0))
            let currentNeck = hips + torsoTracking.act(neckBase - hips)
            func shoulder(_ side: Float) -> SIMD3<Float> {
                currentNeck + torsoTracking.act(lateral * (PerformerCalibration.shoulderHalfWidth * k * side)
                                                - SIMD3<Float>(0, PerformerCalibration.shoulderDrop * k, 0))
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

        // Arms nothing tracks swing with a walk, against the legs; a tracked
        // hand takes its arm from there.
        if let lower = lowerBody, !mirrored, abs(lower.armSwing) > 0.001, tuning.armSwing > 0 {
            let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
            for (chain, sign) in [(leftArmChain, Float(1)), (rightArmChain, Float(-1))] {
                let forward = lower.armSwing * sign
                turn(chain.joints[0], by: simd_quatf(angle: -forward * tuning.armSwing, axis: lateral),
                     pose: &pose, model: &model)
                let bend = (0.3 + 0.5 * max(forward, 0)) * abs(lower.armSwing) * tuning.armSwing
                turn(chain.joints[1], by: simd_quatf(angle: -bend, axis: lateral), pose: &pose, model: &model)
            }
        }

        // Arms and hands, each side on its own weight.
        model = solver.modelMatrices(of: pose)
        let scale = armLength / calibration.armLength
        for side in [Side.left, .right] {
            let weight = side == .left ? hands.left.weight : hands.right.weight
            guard weight > 0.001, let hand = side == .left ? posedHands.left : posedHands.right,
                  let shoulders else {
                if side == .left { hands.left.bend = nil } else { hands.right.bend = nil }
                continue
            }
            // Mirrored, the avatar's left hand is the performer's right, so it
            // is measured from the performer's right shoulder.
            let performerShoulder = (side == .left) != mirrored ? shoulders.left : shoulders.right
            let chain = side == .left ? leftArmChain : rightArmChain
            let upper = chain.joints[0], hand_ = chain.joints[2]
            let shoulderModel = PoseSolver.translation(of: model[upper])
            let target = fromTracking.map { inModel(hand.wrist, $0) }
                ?? shoulderModel + toModel(hand.wrist - performerShoulder) * scale

            // The elbow bends toward where the performer's is: the forearm
            // points back to it. Only the part of that off the shoulder-to-
            // hand line says which way, and near a straight arm it is a few
            // millimetres of tracking noise. Normalised, it swung the avatar's
            // elbow (still bent: its arm is another length) from one side of
            // the line to the other as the hand moved a centimetre. So it is
            // weighed by its size against a default bend, out, down and a
            // little back, which carries a straight arm, and eased over time.
            let reach = target - shoulderModel
            let line = simd_length(reach) > 1e-4 ? simd_normalize(reach) : avatarFrame.act(SIMD3<Float>(0, -1, 0))
            func offLine(_ v: SIMD3<Float>) -> SIMD3<Float> { v - simd_dot(v, line) * line }
            let out: Float = side == .left ? 1 : -1
            var bend = offLine(avatarFrame.act(simd_normalize(SIMD3<Float>(0.45 * out, -0.8, -0.35))))
                * tuning.elbowDefaultBend
            if let forearm = hand.forearm, simd_distance(forearm, hand.wrist) > 0.02 {
                let elbow = hand.wrist + simd_normalize(forearm - hand.wrist) * 0.146 * calibration.height
                bend += offLine(fromTracking.map { inModel(elbow, $0) - shoulderModel }
                                ?? toModel(elbow - performerShoulder) * scale)
            }
            let previous = side == .left ? hands.left.bend : hands.right.bend
            if let previous, tuning.elbowSmoothing > 0 {
                bend = previous + (bend - previous) * min(1, deltaTime / tuning.elbowSmoothing)
            }
            if side == .left { hands.left.bend = bend } else { hands.right.bend = bend }
            let reached = solver.solveLeg(chain: chain, target: target, pole: bend, weight: weight,
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

        // An own body's skin out of the eyes, for next frame's placement.
        // The step is exact for the pose just solved, measured from where it
        // stands now; it is taken at once and given back slowly.
        var wanted: Float = 0
        if let placement, let frame, let clearance, !mirrored {
            let model = solver.modelMatrices(of: pose)
            if let more = clearance.step(root: placement, model: model, eye: frame.head,
                                         forward: calibration.forward) {
                wanted = max(0, clearanceStep + more)
            }
        }
        let easing: Float = wanted > clearanceStep ? 0.03 : 0.3
        clearanceStep += (wanted - clearanceStep) * min(1, deltaTime / easing)
        report.clearance = clearanceStep

        self.report = report
        return pose
    }

    private enum Side { case left, right }

    // MARK: - Legs

    /// Moves the pelvis and bends the legs onto `lower`, and says how far the
    /// pelvis moved, in tracking space: the lean is measured from there.
    private func poseLegs(_ lower: PerformerLowerBody, calibration: PerformerCalibration, placement: simd_float4x4,
                          performer: simd_quatf, report: inout Report,
                          pose: inout [JointPose], model: inout [float4x4]) -> SIMD3<Float> {
        guard let hips, let feet, legs.count == 2 else { return .zero }
        let weight = min(lower.weight, 1)
        let fromTracking = placement.inverse
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let m = fromTracking * SIMD4<Float>(p, 1)
            return SIMD3<Float>(m.x, m.y, m.z)
        }
        func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let m = fromTracking * SIMD4<Float>(v, 0)
            return SIMD3<Float>(m.x, m.y, m.z)
        }
        // A rotation in tracking space, as a change from the body's frame, in
        // model space.
        func change(_ q: simd_quatf) -> simd_quatf {
            simd_normalize(avatarFrame * performer.inverse * q * avatarFrame.inverse)
        }
        let up = avatarFrame.act(SIMD3<Float>(0, 1, 0))
        let lateral = avatarFrame.act(SIMD3<Float>(1, 0, 0))
        let scale = max(simd_length(SIMD3<Float>(placement.columns.0.x, placement.columns.0.y, placement.columns.0.z)),
                        1e-4)

        func moveHips(by offset: SIMD3<Float>) {
            let parent = parentMatrix(of: hips, model: model)
            let at = PoseSolver.translation(of: model[hips]) + offset
            let local = parent.inverse * SIMD4<Float>(at, 1)
            pose[hips].translation = SIMD3<Float>(local.x, local.y, local.z)
            model[hips] = parent * pose[hips].matrix
            refresh(below: hips, pose: pose, model: &model)
        }

        // The pelvis: moved and turned as the lower body has it, the torso
        // turned back so only the pelvis twists under it.
        var shift = (lower.pelvis - calibration.neutralHips) * weight
        moveHips(by: direction(shift))
        let pelvisTurn = simd_slerp(Self.identity, change(lower.pelvisRotation), weight)
        turn(hips, by: pelvisTurn, pose: &pose, model: &model)
        if let spineRoot = skeleton.spine.first {
            turn(spineRoot, by: pelvisTurn.inverse, pose: &pose, model: &model)
        }

        // The floor, for this avatar. Its legs at full length stand on the
        // floor through the performer's, a little long or short for the
        // height they were scaled to. Long, they would have to crouch to
        // stand on the real floor, so the feet stand a little into it
        // instead; short, the pelvis drops below for them to reach. Measured
        // as the performer would stand at their height, not where the head
        // is: a body carried down with the head (a squat, a recentre while
        // stooping) bends its knees rather than sinking its feet.
        let restSole = PoseSolver.translation(of: restModel[hips]) - up * (feet.hips - feet.sole + soleDepth)
        let standing = lower.floor + PerformerCalibration.eyeHeight * calibration.height - calibration.head.y
        let restSoleHeight = (placement * SIMD4<Float>(restSole, 1)).y + standing
        let sink = min(0, restSoleHeight - lower.floor)
        let targets = [lower.left, lower.right].map { point($0.ankle + SIMD3<Float>(0, sink, 0)) }

        // Legs too short for where the feet are: the pelvis comes down until
        // both reach.
        var drop: Float = 0
        for (leg, target) in zip(legs, targets) {
            let longest = leg.length * 0.999
            let reach = target - PoseSolver.translation(of: model[leg.thigh])
            guard simd_length(reach) > longest else { continue }
            let below = simd_dot(reach, up)
            let across = simd_length_squared(reach) - below * below
            let needed = -(max(longest * longest - across, 0)).squareRoot() - below
            drop = max(drop, min(needed, 0.3 * leg.length))
        }
        if drop > 0 {
            moveHips(by: -up * drop * weight)
            shift.y -= drop * weight * scale
        }
        report.pelvisDrop = drop * weight * scale

        for (index, (leg, target)) in zip(legs, targets).enumerated() {
            let foot = index == 0 ? lower.left : lower.right
            let footTurn = change(foot.rotation)
            var along = footTurn.act(avatarFrame.act(SIMD3<Float>(0, 0, 1)))
            along -= simd_dot(along, up) * up
            along = simd_length(along) > 1e-4 ? simd_normalize(along) : avatarFrame.act(SIMD3<Float>(0, 0, 1))
            // Knees go the way the foot points, a touch outward: the
            // direction a leg is never asked to reach along, so the bend
            // plane holds.
            let side: Float = index == 0 ? 1 : -1
            var pole = simd_normalize(along + lateral * (0.25 * side))
            if let knee = foot.knee {
                let thigh = PoseSolver.translation(of: model[leg.thigh])
                let axis = target - thigh
                let delta = point(knee) - thigh
                let bend = delta - axis * (simd_dot(delta, axis) / max(simd_length_squared(axis), 1e-6))
                if simd_length(bend) > 0.01 {
                    let blended = pole + (simd_normalize(bend) - pole) * min(1, max(0, foot.kneeWeight))
                    if simd_length(blended) > 1e-5 { pole = simd_normalize(blended) }
                }
            }
            let reached = solver.solveLeg(chain: leg.chain, target: target, pole: pole, weight: weight,
                                          reachLimit: 0.999, pose: &pose, model: &model)
            if index == 0 { report.leftFootError = reached.error } else { report.rightFootError = reached.error }

            // The foot lies as the lower body has it, against the way it
            // lies as built (flat, facing forward); the toes bend from it.
            let ankleNow = PoseSolver.rotation(of: currentModel(leg.ankle, pose: pose, model: model))
            let ankleWanted = footTurn * PoseSolver.rotation(of: restModel[leg.ankle])
            set(leg.ankle, modelRotation: simd_slerp(ankleNow, simd_normalize(ankleWanted), weight),
                pose: &pose, model: &model)
            let bend = simd_quatf(angle: -foot.toeBend, axis: simd_normalize(footTurn.act(lateral)))
            for toe in leg.toes {
                let toeNow = PoseSolver.rotation(of: currentModel(toe, pose: pose, model: model))
                let toeWanted = bend * footTurn * PoseSolver.rotation(of: restModel[toe])
                set(toe, modelRotation: simd_slerp(toeNow, simd_normalize(toeWanted), weight),
                    pose: &pose, model: &model)
            }
        }
        return shift
    }

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
