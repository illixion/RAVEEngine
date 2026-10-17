import Testing
import simd
@testable import RAVERig

/// A small biped facing +Z, Y up, in metres: a spine of three, a neck and a
/// head, and T-posed arms with a thumb and two two-joint fingers per hand,
/// palms down. The performer stands at the origin facing −Z — the two face
/// each other, which is exactly the mirror case — and every expectation is
/// written in terms of whose left is where, since that is what a mirror gets
/// wrong.
@Suite("PerformerRig")
struct PerformerRigTests {

    // Joint indices.
    static let hips = 0, spine = 1, chest = 2, neck = 3, head = 4
    static let leftUpper = 5, leftFore = 6, leftHand = 7
    static let leftIndex = [8, 9], leftMiddle = [10, 11], leftThumb = [12, 13]
    static let rightUpper = 14, rightFore = 15, rightHand = 16
    static let rightIndex = [17, 18], rightMiddle = [19, 20], rightThumb = [21, 22]

    /// `metacarpals` starts each finger inside the palm, the way the Synth's
    /// do, with the knuckle at its second joint.
    static func skeleton(metacarpals: Bool = false) -> PerformerRig.Skeleton {
        func j(_ x: Float, _ y: Float, _ z: Float) -> JointPose { JointPose(translation: SIMD3(x, y, z)) }
        // The avatar faces +Z, so its left is +X.
        func arm(_ side: Float) -> [JointPose] {
            let (root, next): (Float, Float) = metacarpals ? (0.03, 0.06) : (0.08, 0.03)
            return [j(0.2 * side, 0.1, 0), j(0.25 * side, 0, 0), j(0.25 * side, 0, 0),
                    j(root * side, 0, 0.02), j(next * side, 0, 0),
                    j(root * side, 0, -0.02), j(next * side, 0, 0),
                    j(0.02 * side, 0, 0.04), j(0.03 * side, 0, 0.01)]
        }
        let rest = [j(0, 1, 0), j(0, 0.15, 0), j(0, 0.15, 0), j(0, 0.15, 0), j(0, 0.1, 0)] + arm(1) + arm(-1)
        func armParents(_ base: Int) -> [Int?] {
            [chest, base, base + 1, base + 2, base + 3, base + 2, base + 5, base + 2, base + 7]
        }
        let parents: [Int?] = [nil, 0, 1, 2, 3] + armParents(5) + armParents(14)
        return PerformerRig.Skeleton(
            parents: parents, rest: rest, spine: [spine, chest], neck: neck, head: head, jaw: nil,
            leftArm: [leftUpper, leftFore, leftHand], rightArm: [rightUpper, rightFore, rightHand],
            leftDigits: .init(thumb: leftThumb, fingers: [leftIndex, leftMiddle]),
            rightDigits: .init(thumb: rightThumb, fingers: [rightIndex, rightMiddle]),
            forward: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0))
    }

    /// The performer faces −Z, so their left is −X.
    static let calibration = PerformerCalibration(head: SIMD3(0, 1.6, 0), forward: SIMD3(0, 0, -1), height: 1.7)

    static func level(yawDegrees: Float = 0) -> simd_quatf {
        simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3(0, 1, 0))
    }

    /// A flat hand at `wrist`, fingers along `along`, palm facing `palm`,
    /// thumb toward `thumbSide`; `curl` bends every finger joint down toward
    /// the palm by that many degrees.
    static func hand(wrist: SIMD3<Float>, along: SIMD3<Float>, palm: SIMD3<Float>,
                     thumbSide: SIMD3<Float>, curl: Float = 0) -> PerformerHand {
        func finger(offset: Float) -> [SIMD3<Float>] {
            var points = [wrist + thumbSide * offset * 0.5 + along * 0.02]
            var cursor = wrist + thumbSide * offset + along * 0.09
            points.append(cursor)
            var direction = along
            for _ in 0..<3 {
                direction = simd_normalize(simd_quatf(angle: curl * .pi / 180, axis: simd_cross(along, palm))
                    .act(direction))
                cursor += direction * 0.03
                points.append(cursor)
            }
            return points
        }
        let thumbBase = wrist + thumbSide * 0.03 + along * 0.02
        let thumb = [thumbBase, thumbBase + (along + thumbSide) * 0.02,
                     thumbBase + (along + thumbSide) * 0.04, thumbBase + (along + thumbSide) * 0.06]
        return PerformerHand(wrist: wrist, thumb: thumb,
                             fingers: [finger(offset: 0.03), finger(offset: 0.01),
                                       finger(offset: -0.01), finger(offset: -0.03)])
    }

    /// The Synth's jaw has a tongue chain whose root sits behind and below
    /// the hinge. Opening the mouth must still lower the chin, which is in
    /// front of the hinge whatever the jaw's children are.
    @Test func theJawOpensDownwardWhateverItsChildren() throws {
        let base = Self.skeleton()
        let jaw = base.rest.count, tongue = jaw + 1
        let skeleton = PerformerRig.Skeleton(
            parents: base.parents + [Self.head, jaw],
            rest: base.rest + [JointPose(translation: SIMD3(0, 0.02, 0.04)),
                               JointPose(translation: SIMD3(0, -0.03, -0.05))],
            spine: base.spine, neck: base.neck, head: base.head, jaw: jaw,
            leftArm: base.leftArm, rightArm: base.rightArm,
            leftDigits: base.leftDigits, rightDigits: base.rightDigits,
            forward: base.forward, up: base.up)
        #expect(skeleton.parents[tongue] == jaw)
        var rig = try #require(PerformerRig(skeleton))
        func chin(mouthOpen: Float) -> Float {
            let pose = rig.solve(base: skeleton.rest, frame: nil, calibration: Self.calibration,
                                 mirrored: false, mouthOpen: mouthOpen, deltaTime: 1 / 90)
            let m = Self.model(rig, pose)[jaw]
            return (m * SIMD4<Float>(0, 0, 0.08, 1)).y
        }
        #expect(chin(mouthOpen: 1) < chin(mouthOpen: 0) - 0.01)
    }

    /// A performer's nearly straight arm puts the forearm-derived elbow a
    /// few millimetres off the shoulder-to-hand line, on whichever side the
    /// tracking noise says. The avatar's arm is shorter and still bent, and
    /// its elbow must not swing around the line with that noise.
    @Test func aNearlyStraightArmDoesNotFlipTheElbow() throws {
        // Where the rig estimates the performer's left shoulder for this
        // calibration: the neck below and behind the eyes, 17 cm out.
        let shoulder = SIMD3<Float>(-0.17, 1.39, 0.08)
        let wrist = shoulder + SIMD3<Float>(-0.25, -0.15, -0.2)
        let back = simd_normalize(shoulder - wrist)
        let across = simd_normalize(simd_cross(back, SIMD3<Float>(0, 1, 0)))
        func elbow(noise: Float) throws -> SIMD3<Float> {
            var rig = try #require(PerformerRig(Self.skeleton()))
            var hand = Self.hand(wrist: wrist, along: SIMD3(-1, 0, 0), palm: SIMD3(0, -1, 0),
                                 thumbSide: SIMD3(0, 0, -1))
            hand.forearm = wrist + back * 0.1 + across * noise
            let frame = PerformerFrame(head: Self.calibration.head, headRotation: Self.level(), left: hand)
            let pose = rig.solve(base: Self.skeleton().rest, frame: frame, calibration: Self.calibration,
                                 mirrored: false, mouthOpen: 0, deltaTime: 1)
            let m = Self.model(rig, pose)[Self.leftFore]
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        let one = try elbow(noise: 0.002), other = try elbow(noise: -0.002)
        #expect(simd_distance(one, other) < 0.06)
    }

    static func model(_ rig: PerformerRig, _ pose: [JointPose]) -> [float4x4] {
        PoseSolver(parents: rig.skeleton.parents).modelMatrices(of: pose)
    }

    static func forward(of joint: Int, in model: [float4x4]) -> SIMD3<Float> {
        PoseSolver.rotation(of: model[joint]).act(SIMD3(0, 0, 1))
    }

    @Test("a performer looking straight ahead leaves the head at rest")
    func neutralHead() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let frame = PerformerFrame(head: Self.calibration.head, headRotation: Self.level())
        let pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                             mirrored: false, deltaTime: 1 / 90)
        let looking = Self.forward(of: Self.head, in: Self.model(rig, pose))
        #expect(simd_distance(looking, SIMD3(0, 0, 1)) < 1e-3)
    }

    @Test("turning to the left turns the avatar to its left, and its reflection to its right")
    func headTurnAndMirror() throws {
        let frame = PerformerFrame(head: Self.calibration.head, headRotation: Self.level(yawDegrees: 30))
        var rig = try #require(PerformerRig(Self.skeleton()))
        let straight = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                                 mirrored: false, deltaTime: 1 / 90)
        // The avatar's left is +X: its head now looks partly that way.
        let looking = Self.forward(of: Self.head, in: Self.model(rig, straight))
        #expect(abs(looking.x - sin(30 * Float.pi / 180)) < 0.01)

        var mirror = try #require(PerformerRig(Self.skeleton()))
        let reflected = mirror.solve(base: mirror.skeleton.rest, frame: frame, calibration: Self.calibration,
                                     mirrored: true, deltaTime: 1 / 90)
        let mirrorLooking = Self.forward(of: Self.head, in: Self.model(mirror, reflected))
        #expect(abs(mirrorLooking.x + sin(30 * Float.pi / 180)) < 0.01)
    }

    @Test("the neck takes its share of the turn")
    func neckShare() throws {
        let frame = PerformerFrame(head: Self.calibration.head, headRotation: Self.level(yawDegrees: 40))
        var rig = try #require(PerformerRig(Self.skeleton()))
        let pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                             mirrored: false, deltaTime: 1 / 90)
        let neckYaw = PoseSolver.rotation(of: Self.model(rig, pose)[Self.neck]).angle * 180 / .pi
        #expect(neckYaw > 10 && neckYaw < 30)
    }

    /// Frames for a hand held straight out to the performer's left at
    /// shoulder height, palm down.
    static func leftArmOut() -> PerformerFrame {
        // Performer's left is −X; the shoulder sits about 0.17·k out and a
        // little under the neck.
        let wrist = SIMD3<Float>(-0.55, 1.42, 0.05)
        let left = hand(wrist: wrist, along: SIMD3(-1, 0, 0), palm: SIMD3(0, -1, 0), thumbSide: SIMD3(0, 0, -1))
        return PerformerFrame(head: calibration.head, headRotation: level(), left: left)
    }

    static func solveFully(_ rig: inout PerformerRig, _ frame: PerformerFrame, mirrored: Bool) -> [JointPose] {
        var pose = rig.skeleton.rest
        // Long enough for the hand to ease all the way in.
        for _ in 0..<30 {
            pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: calibration,
                             mirrored: mirrored, deltaTime: 1 / 90)
        }
        return pose
    }

    @Test("a hand held out to the side reaches out on the avatar's same side")
    func armReaches() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let pose = Self.solveFully(&rig, Self.leftArmOut(), mirrored: false)
        #expect(rig.report.leftWeight == 1)
        let model = Self.model(rig, pose)
        let hand = PoseSolver.translation(of: model[Self.leftHand])
        let shoulder = PoseSolver.translation(of: model[Self.leftUpper])
        // Out along the avatar's left (+X), at about shoulder height.
        #expect(hand.x - shoulder.x > 0.3)
        #expect(abs(hand.y - shoulder.y) < 0.08)
        // The right arm had no hand and stays at rest.
        let restModel = Self.model(rig, rig.skeleton.rest)
        #expect(simd_distance(PoseSolver.translation(of: model[Self.rightHand]),
                              PoseSolver.translation(of: restModel[Self.rightHand])) < 1e-4)
    }

    @Test("mirrored, the performer's left hand drives the avatar's right")
    func mirrorSwapsHands() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let pose = Self.solveFully(&rig, Self.leftArmOut(), mirrored: true)
        #expect(rig.report.rightWeight == 1)
        #expect(rig.report.leftWeight == 0)
        let model = Self.model(rig, pose)
        let hand = PoseSolver.translation(of: model[Self.rightHand])
        let shoulder = PoseSolver.translation(of: model[Self.rightUpper])
        // The avatar's right is −X.
        #expect(shoulder.x - hand.x > 0.3)
    }

    @Test("a palm turned up turns the avatar's palm up")
    func palmFollows() throws {
        var frame = Self.leftArmOut()
        let wrist = frame.left!.wrist
        frame.left = Self.hand(wrist: wrist, along: SIMD3(-1, 0, 0), palm: SIMD3(0, 1, 0), thumbSide: SIMD3(0, 0, 1))
        var rig = try #require(PerformerRig(Self.skeleton()))
        let pose = Self.solveFully(&rig, frame, mirrored: false)
        let model = Self.model(rig, pose)
        // The index finger root sits on the thumb side; with the palm up, the
        // thumb side has swung from +Z (palm down, arm along +X) to −Z.
        let hand = PoseSolver.translation(of: model[Self.leftHand])
        let index = PoseSolver.translation(of: model[Self.leftIndex[0]])
        let middle = PoseSolver.translation(of: model[Self.leftMiddle[0]])
        #expect(index.z < middle.z)
        #expect(index.x > hand.x)
    }

    @Test("curled fingers curl the avatar's")
    func fingersCurl() throws {
        var frame = Self.leftArmOut()
        let wrist = frame.left!.wrist
        frame.left = Self.hand(wrist: wrist, along: SIMD3(-1, 0, 0), palm: SIMD3(0, -1, 0),
                               thumbSide: SIMD3(0, 0, -1), curl: 40)
        var rig = try #require(PerformerRig(Self.skeleton()))
        let pose = Self.solveFully(&rig, frame, mirrored: false)
        let model = Self.model(rig, pose)
        // The fingertip's bone points down (−Y) toward the palm side.
        let tipDirection = PoseSolver.rotation(of: model[Self.leftIndex[1]]).act(SIMD3(1, 0, 0))
        #expect(tipDirection.y < -0.5)
    }

    @Test("a finger starting inside the palm bends at the knuckle, not in the palm")
    func metacarpalStaysInThePalm() throws {
        var frame = Self.leftArmOut()
        let wrist = frame.left!.wrist
        frame.left = Self.hand(wrist: wrist, along: SIMD3(-1, 0, 0), palm: SIMD3(0, -1, 0),
                               thumbSide: SIMD3(0, 0, -1), curl: 40)
        var rig = try #require(PerformerRig(Self.skeleton(metacarpals: true)))
        let pose = Self.solveFully(&rig, frame, mirrored: false)
        let model = Self.model(rig, pose)
        func bone(_ from: Int, _ to: Int) -> SIMD3<Float> {
            simd_normalize(PoseSolver.translation(of: model[to]) - PoseSolver.translation(of: model[from]))
        }
        // The metacarpal keeps to the palm, out along the arm...
        let palm = bone(Self.leftIndex[0], Self.leftIndex[1])
        #expect(abs(palm.y) < 0.15)
        #expect(palm.x > 0.9)
        // ...and the finger bends down from the knuckle.
        let finger = PoseSolver.rotation(of: model[Self.leftIndex[1]]).act(SIMD3(1, 0, 0))
        #expect(finger.y < -0.4)
    }

    @Test("bones are matched from the knuckle on any finger")
    func fingerBoneMatching() {
        #expect(PerformerRig.fingerBones(joints: 3, metacarpal: true).map { $0?.0 } == [0, 1, 2])
        #expect(PerformerRig.fingerBones(joints: 3, metacarpal: true).map { $0?.1 } == [1, 2, 4])
        #expect(PerformerRig.fingerBones(joints: 3, metacarpal: false).map { $0?.0 } == [1, 2, 3])
        #expect(PerformerRig.fingerBones(joints: 4, metacarpal: true).map { $0?.0 } == [0, 1, 2, 3])
        #expect(PerformerRig.fingerBones(joints: 5, metacarpal: false).map { $0?.0 } == [nil, nil, 1, 2, 3])
        #expect(PerformerRig.thumbBones(joints: 3).map { $0?.0 } == [0, 1, 2])
    }

    @Test("a hand that leaves view eases back to the base pose")
    func handEasesOut() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        _ = Self.solveFully(&rig, Self.leftArmOut(), mirrored: false)
        let gone = PerformerFrame(head: Self.calibration.head, headRotation: Self.level())
        var pose = rig.skeleton.rest
        // Held for `handHold`, then faded over `handFadeOut`.
        for _ in 0..<120 {
            pose = rig.solve(base: rig.skeleton.rest, frame: gone, calibration: Self.calibration,
                             mirrored: false, deltaTime: 1 / 90)
        }
        #expect(rig.report.leftWeight == 0)
        let model = Self.model(rig, pose)
        let restModel = Self.model(rig, rig.skeleton.rest)
        #expect(simd_distance(PoseSolver.translation(of: model[Self.leftHand]),
                              PoseSolver.translation(of: restModel[Self.leftHand])) < 1e-4)
    }

    @Test("a hand that blinks out of tracking holds where it was")
    func dropoutHolds() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let tracked = Self.solveFully(&rig, Self.leftArmOut(), mirrored: false)
        let before = PoseSolver.translation(of: Self.model(rig, tracked)[Self.leftHand])
        let gone = PerformerFrame(head: Self.calibration.head, headRotation: Self.level())
        var pose = tracked
        // Six frames at 90 Hz: a hand turned edge-on.
        for _ in 0..<6 {
            pose = rig.solve(base: rig.skeleton.rest, frame: gone, calibration: Self.calibration,
                             mirrored: false, deltaTime: 1 / 90)
        }
        #expect(rig.report.leftWeight == 1)
        let during = PoseSolver.translation(of: Self.model(rig, pose)[Self.leftHand])
        #expect(simd_distance(before, during) < 1e-3)
    }

    /// Both hands held in front, the left one behind the right as the eyes
    /// see it: the headset loses the left. It must not fade to idle, and it
    /// moves with the right hand that hides it.
    @Test func aHandHiddenBehindTheOtherMovesWithIt() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let head = Self.calibration.head
        let right = Self.hand(wrist: head + SIMD3(0.05, -0.35, -0.3), along: SIMD3(0, 0, -1), palm: SIMD3(0, -1, 0),
                              thumbSide: SIMD3(-1, 0, 0))
        // Further along nearly the same line of sight, behind the right.
        let left = Self.hand(wrist: head + SIMD3(0.06, -0.45, -0.4), along: SIMD3(0, 0, -1), palm: SIMD3(0, -1, 0),
                             thumbSide: SIMD3(1, 0, 0))
        let both = PerformerFrame(head: head, headRotation: Self.level(), left: left, right: right)
        _ = Self.solveFully(&rig, both, mirrored: false)
        let before = PoseSolver.translation(of: Self.model(rig, rig.solve(
            base: rig.skeleton.rest, frame: both, calibration: Self.calibration, mirrored: false,
            deltaTime: 1 / 90))[Self.leftHand])
        // Three seconds hidden, while the right hand drifts 10 cm to the side.
        var pose = rig.skeleton.rest
        for i in 0..<270 {
            let drift = SIMD3<Float>(0.1 * Float(i) / 270, 0, 0)
            let frame = PerformerFrame(head: head, headRotation: Self.level(), right: right.translated(by: drift))
            pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                             mirrored: false, deltaTime: 1 / 90)
        }
        #expect(rig.report.leftHidden)
        #expect(rig.report.leftWeight == 1)
        let after = PoseSolver.translation(of: Self.model(rig, pose)[Self.leftHand])
        // The avatar faces the performer: their +X drift is its −X.
        #expect(after.x < before.x - 0.03)
    }

    /// Hands waved past each other in front: the left goes behind the right
    /// while they move opposite ways. The hidden one keeps going the way it
    /// was, slowing, rather than riding the right hand back or stopping dead.
    @Test func aHandWavedPastTheOtherCoastsOnItsOwn() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let head = Self.calibration.head
        func hand(_ wrist: SIMD3<Float>, _ thumb: SIMD3<Float>) -> PerformerHand {
            Self.hand(wrist: wrist, along: SIMD3(0, 0, -1), palm: SIMD3(0, -1, 0), thumbSide: thumb)
        }
        // Half a second of the left moving right at 0.6 m/s and the right
        // moving left at the same speed, a hand's width apart in depth, so they
        // line up as the left disappears.
        var left = head + SIMD3<Float>(-0.25, -0.4, -0.45), right = head + SIMD3<Float>(0.35, -0.35, -0.3)
        let step: Float = 1 / 90, speed: Float = 0.6
        var pose = rig.skeleton.rest
        for _ in 0..<45 {
            left.x += speed * step
            right.x -= speed * step
            let frame = PerformerFrame(head: head, headRotation: Self.level(),
                                       left: hand(left, SIMD3(1, 0, 0)), right: hand(right, SIMD3(-1, 0, 0)))
            pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                             mirrored: false, deltaTime: step)
        }
        let before = PoseSolver.translation(of: Self.model(rig, pose)[Self.leftHand])
        // Now the left is hidden for a third of a second; the right keeps going.
        for _ in 0..<30 {
            right.x -= speed * step
            let frame = PerformerFrame(head: head, headRotation: Self.level(), right: hand(right, SIMD3(-1, 0, 0)))
            pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                             mirrored: false, deltaTime: step)
        }
        #expect(rig.report.leftBridge.contains("coasting"))
        #expect(rig.report.leftWeight == 1)
        let after = PoseSolver.translation(of: Self.model(rig, pose)[Self.leftHand])
        // The performer's +X is the avatar's −X: the hand kept going that way.
        #expect(after.x < before.x - 0.02)
    }

    /// A hand that comes back after a loss eases from where it was bridged
    /// rather than jumping to where tracking now puts it.
    @Test func aReturningHandEasesBack() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        let tracked = Self.solveFully(&rig, Self.leftArmOut(), mirrored: false)
        let held = PoseSolver.translation(of: Self.model(rig, tracked)[Self.leftHand])
        let gone = PerformerFrame(head: Self.calibration.head, headRotation: Self.level())
        for _ in 0..<6 {
            _ = rig.solve(base: rig.skeleton.rest, frame: gone, calibration: Self.calibration,
                          mirrored: false, deltaTime: 1 / 90)
        }
        // Back 15 cm lower.
        var moved = Self.leftArmOut()
        moved.left = moved.left?.translated(by: SIMD3(0, -0.15, 0))
        let first = rig.solve(base: rig.skeleton.rest, frame: moved, calibration: Self.calibration,
                              mirrored: false, deltaTime: 1 / 90)
        let step = PoseSolver.translation(of: Self.model(rig, first)[Self.leftHand])
        #expect(simd_distance(step, held) < 0.05)
        let settled = Self.solveFully(&rig, moved, mirrored: false)
        #expect(simd_distance(PoseSolver.translation(of: Self.model(rig, settled)[Self.leftHand]), held) > 0.1)
    }

    @Test("leaning forward bends the spine forward")
    func leanForward() throws {
        var rig = try #require(PerformerRig(Self.skeleton()))
        // Head 15 cm further toward −Z (the performer's forward) and a little lower.
        let frame = PerformerFrame(head: Self.calibration.head + SIMD3(0, -0.03, -0.15), headRotation: Self.level())
        let pose = rig.solve(base: rig.skeleton.rest, frame: frame, calibration: Self.calibration,
                             mirrored: false, deltaTime: 1 / 90)
        #expect(rig.report.leanDegrees > 5)
        let model = Self.model(rig, pose)
        // The avatar's forward is +Z: the chest has moved that way.
        #expect(PoseSolver.translation(of: model[Self.neck]).z > 0.03)
    }

    @Test("the palm frame is right-handed and matches its inputs")
    func palmFrame() throws {
        let frame = try #require(PerformerRig.palmFrame(
            base: .zero, fingerRoots: [SIMD3(0.1, 0, 0.02), SIMD3(0.1, 0, -0.02)], thumbRoot: nil))
        let m = float3x3(frame)
        #expect(abs(simd_determinant(m) - 1) < 1e-4)
        #expect(simd_distance(m.columns.2, SIMD3(1, 0, 0)) < 1e-4)
        #expect(simd_distance(m.columns.0, SIMD3(0, 0, 1)) < 1e-4)
    }

    @Test("the 1€ filter passes a still point and follows a moving one")
    func oneEuro() {
        var filter = OneEuroFilter()
        var out = SIMD3<Float>.zero
        for _ in 0..<10 { out = filter.filter(SIMD3(1, 1, 1), deltaTime: 1 / 90) }
        #expect(simd_distance(out, SIMD3(1, 1, 1)) < 1e-5)
        for i in 0..<90 { out = filter.filter(SIMD3(1 + Float(i) / 90, 1, 1), deltaTime: 1 / 90) }
        #expect(abs(out.x - 2) < 0.05)
    }
}
