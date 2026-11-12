import Foundation
import Testing
import simd
@testable import RAVERig

/// The layers are judged on the pose they leave behind, read back through
/// forward kinematics the way a renderer would: the face points at what it
/// looks at and stays level, the tail's joints sit where its simulation put
/// them, and a layer that is switched off gives the pose back untouched.
@Suite struct BodyLayersTests {

    // MARK: A small character: spine, neck, head, and a tail off the hips

    static let joints: [(String, SIMD3<Float>)] = [
        ("Root", [0, 0, 0]),
        ("Root/Hips", [0, 0.95, 0]),
        ("Root/Hips/Spine", [0, 0.25, 0]),
        ("Root/Hips/Spine/Neck", [0, 0.3, 0]),
        ("Root/Hips/Spine/Neck/Head", [0, 0.1, 0]),
        ("Root/Hips/Tail_1", [0, 0, -0.1]),
        ("Root/Hips/Tail_1/Tail_2", [0, 0, -0.2]),
        ("Root/Hips/Tail_1/Tail_2/Tail_3", [0, 0, -0.2]),
        ("Root/Hips/Tail_1/Tail_2/Tail_3/Tail_4", [0, 0, -0.2]),
        ("Root/Hips/Tail_1/Tail_2/Tail_3/Tail_4/Tail_5", [0, 0, -0.2]),
        ("Root/Hips/Thigh_L", [0.1, -0.05, 0]),
        ("Root/Hips/Thigh_L/Shin_L", [0, -0.45, 0]),
        ("Root/Hips/Thigh_L/Shin_L/Foot_L", [0, -0.42, 0]),
        ("Root/Hips/Thigh_R", [-0.1, -0.05, 0]),
        ("Root/Hips/Thigh_R/Shin_R", [0, -0.45, 0]),
        ("Root/Hips/Thigh_R/Shin_R/Foot_R", [0, -0.42, 0]),
    ]
    static let names = joints.map(\.0)
    static let parents = PoseSolver.parents(fromPaths: names)
    static let rest = joints.map { JointPose(translation: $0.1) }
    static let neck = 3, head = 4
    static let tail = [5, 6, 7, 8, 9]
    static let hips = 1
    static let rig = BodyLayers.Rig(head: "Head", neck: ["Neck"], tail: tail.map { names[$0] }, hips: "Hips",
                                    legs: [["Thigh_L", "Shin_L", "Foot_L"], ["Thigh_R", "Shin_R", "Foot_R"]])
    static let solver = PoseSolver(parents: parents)

    private func layers(rig: BodyLayers.Rig = BodyLayersTests.rig, jiggle: [JiggleSpec] = []) -> BodyLayers {
        BodyLayers(jointNames: Self.names, parents: Self.parents, rest: Self.rest, rig: rig, jiggle: jiggle)
    }

    private func frame(lookAt: SIMD3<Float>? = nil, fps: Float = 90, floor: Float? = nil,
                       hands: [BodyLayers.Hand] = [], obstacles: [ChainDynamics.Sphere] = [],
                       modelToWorld: float4x4 = matrix_identity_float4x4) -> BodyLayers.Frame {
        BodyLayers.Frame(modelToWorld: modelToWorld, deltaTime: 1 / fps, lookAt: lookAt, floor: floor,
                         hands: hands, obstacles: obstacles)
    }

    /// A hand with its grip at `point`: an open palm under it when `palm`,
    /// else nothing solid, so a hold can be measured without the push.
    private func hand(at point: SIMD3<Float>, closure: Float, palm: Bool = false, id: Int = 0) -> BodyLayers.Hand {
        BodyLayers.Hand(id: id, spheres: palm ? [.init(center: point, radius: 0.045)] : [], grip: point,
                        closure: closure)
    }

    /// A settled tail, and the hand closing on its `joint`-th joint.
    private func grabbed(joint: Int) -> (body: BodyLayers, at: SIMD3<Float>) {
        var body = layers()
        body.look = nil
        _ = run(&body, seconds: 2, frame: frame())
        let point = body.tail!.positions[joint]
        // Open on the tail, then closing.
        _ = run(&body, seconds: 0.1, frame: frame(hands: [hand(at: point, closure: 0.1)]))
        _ = run(&body, seconds: 0.1, frame: frame(hands: [hand(at: point, closure: 1)]))
        return (body, point)
    }

    /// Runs `seconds` of frames on a fresh copy of `clip` each frame, the
    /// way a host hands over a new clip pose every frame, and returns the
    /// last pose.
    private func run(_ layers: inout BodyLayers, seconds: Float, clip: [JointPose] = BodyLayersTests.rest,
                     frame: BodyLayers.Frame) -> [JointPose] {
        var pose = clip
        for _ in 0..<Int(seconds / frame.deltaTime) {
            pose = clip
            layers.apply(to: &pose, frame: frame)
        }
        return pose
    }

    private func degrees(between a: SIMD3<Float>, and b: SIMD3<Float>) -> Float {
        acos(simd_clamp(simd_dot(simd_normalize(a), simd_normalize(b)), -1, 1)) * 180 / .pi
    }

    private func headAxes(_ pose: [JointPose]) -> (position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let model = Self.solver.modelMatrices(of: pose)[Self.head]
        let rotation = PoseSolver.rotation(of: model)
        return (PoseSolver.translation(of: model), rotation.act(SIMD3(0, 0, 1)), rotation.act(SIMD3(0, 1, 0)))
    }

    // MARK: Look

    @Test func theFaceEndsUpOnTheTargetAndStaysLevel() {
        var body = layers()
        body.tail = nil
        body.look?.stabilise = 1
        // Up and to the side, well inside what a neck does.
        let target = SIMD3<Float>(1.0, 2.0, 1.5)
        let pose = run(&body, seconds: 2, frame: frame(lookAt: target))
        let face = headAxes(pose)
        #expect(degrees(between: face.forward, and: target - face.position) < 1)
        // Level: the head's side axis has no vertical part.
        let side = simd_cross(face.up, face.forward)
        #expect(abs(side.y) < 0.01)
        #expect(body.look?.aimed == true)
    }

    @Test func theNeckTakesItsShareOfTheTurn() {
        var body = layers()
        body.tail = nil
        body.look?.stabilise = 1
        let pose = run(&body, seconds: 2, frame: frame(lookAt: SIMD3(2, 1.6, 2)))
        let model = Self.solver.modelMatrices(of: pose)
        let neckTurn = degrees(between: PoseSolver.rotation(of: model[Self.neck]).act(SIMD3(0, 0, 1)), and: SIMD3(0, 0, 1))
        let headTurn = degrees(between: PoseSolver.rotation(of: model[Self.head]).act(SIMD3(0, 0, 1)), and: SIMD3(0, 0, 1))
        #expect(headTurn > 40)
        #expect(abs(neckTurn / headTurn - (1 - LookLayer.headShare)) < 0.05)
    }

    @Test func aTargetBehindIsClampedToWhatANeckDoes() {
        var body = layers()
        body.tail = nil
        body.look?.stabilise = 1
        let pose = run(&body, seconds: 3, frame: frame(lookAt: SIMD3(0.3, 1.6, -3)))
        let face = headAxes(pose)
        let yaw = atan2(face.forward.x, face.forward.z) * 180 / .pi
        #expect(abs(yaw - 70) < 1.5)
        // The host turns the body on this.
        #expect(abs(body.look!.steering.wantedYaw) > body.look!.steering.maxYaw)
    }

    @Test func aNoddingClipNodsOnTopUnlessTheHeadIsHeld() {
        var nod = Self.rest
        nod[Self.head].rotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3(1, 0, 0))
        let target = SIMD3<Float>(1.2, 1.6, 2)

        var held = layers()
        held.tail = nil
        held.look?.stabilise = 1
        let heldFace = headAxes(run(&held, seconds: 2, clip: nod, frame: frame(lookAt: target)))
        #expect(degrees(between: heldFace.forward, and: target - heldFace.position) < 1)

        var added = layers()
        added.tail = nil
        added.look?.stabilise = 0
        let addedFace = headAxes(run(&added, seconds: 2, clip: nod, frame: frame(lookAt: target)))
        let off = degrees(between: addedFace.forward, and: target - addedFace.position)
        #expect(off > 15 && off < 25)
    }

    @Test func aBlenderSkeletonLooksTheSameWay() {
        // Z-up bones, stood upright by the entity above them, as a Blender
        // export arrives: model up is +Z and the character faces -Y.
        let upright = float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
        let toZUp = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        let rest = Self.joints.map { JointPose(translation: toZUp.act($0.1)) }
        var body = BodyLayers(jointNames: Self.names, parents: Self.parents, rest: rest,
                              rig: BodyLayers.Rig(head: "Head", neck: ["Neck"],
                                                  forward: toZUp.act(SIMD3(0, 0, 1)), up: toZUp.act(SIMD3(0, 1, 0))))
        body.look?.stabilise = 1
        let target = SIMD3<Float>(-1.0, 1.9, 1.5)
        var pose = rest
        for _ in 0..<180 {
            pose = rest
            body.apply(to: &pose, frame: frame(lookAt: target, modelToWorld: upright))
        }
        let model = upright * Self.solver.modelMatrices(of: pose)[Self.head]
        let forward = PoseSolver.rotation(of: model).act(toZUp.act(SIMD3(0, 0, 1)))
        #expect(degrees(between: forward, and: target - PoseSolver.translation(of: model)) < 1)
    }

    @Test func lettingGoGivesTheHeadBack() {
        var body = layers()
        body.tail = nil
        _ = run(&body, seconds: 1, frame: frame(lookAt: SIMD3(1, 1.6, 1)))
        let pose = run(&body, seconds: 1, frame: frame(lookAt: nil))
        #expect(body.look?.aimed == false)
        #expect(pose == Self.rest)
    }

    @Test func theHeadNeverTurnsFasterThanItsRate() {
        var body = layers()
        body.tail = nil
        var last = SIMD3<Float>(0, 0, 1)
        var worst: Float = 0
        var pose = Self.rest
        for i in 0..<270 {
            pose = Self.rest
            // The target jumps from one side to the other a second in.
            body.apply(to: &pose, frame: frame(lookAt: SIMD3(i < 90 ? 2 : -2, 1.6, 1)))
            let forward = headAxes(pose).forward
            // Once the layer has the head: the fade-in is its own motion.
            if i > 45 { worst = max(worst, degrees(between: forward, and: last) * 90) }
            last = forward
        }
        // Yaw and pitch each move at `rate`, so together a little more.
        #expect(worst > 100)
        #expect(worst < body.look!.steering.rate * 180 / .pi * 1.5)
    }

    // MARK: Laying a chain

    @Test func aLaidChainLandsOnItsPositions() {
        var pose = Self.rest
        let model = Self.solver.modelMatrices(of: pose)
        let base = PoseSolver.translation(of: model[Self.tail[0]])
        // A curve of the chain's own bone lengths, sagging and off to a side.
        var positions = [base]
        let directions: [SIMD3<Float>] = [[0.2, -0.3, -1], [0.4, -0.6, -1], [0.5, -1, -0.6], [0.2, -1, 0]]
        for direction in directions {
            positions.append(positions.last! + simd_normalize(direction) * 0.2)
        }
        Self.solver.lay(Self.tail, along: positions, in: &pose)
        let laid = Self.solver.modelMatrices(of: pose)
        for (joint, wanted) in zip(Self.tail, positions) {
            #expect(simd_distance(PoseSolver.translation(of: laid[joint]), wanted) < 1e-4)
        }
    }

    @Test func halfWeightLaysTheChainHalfWay() {
        var pose = Self.rest
        let model = Self.solver.modelMatrices(of: pose)
        let base = PoseSolver.translation(of: model[Self.tail[0]])
        // Straight down instead of straight back: a quarter turn at the base.
        let positions = (0..<5).map { base + SIMD3<Float>(0, -0.2 * Float($0), 0) }
        Self.solver.lay(Self.tail, along: positions, in: &pose, weight: 0.5)
        let laid = Self.solver.modelMatrices(of: pose)
        let first = PoseSolver.translation(of: laid[Self.tail[1]]) - base
        #expect(abs(degrees(between: first, and: SIMD3(0, 0, -1)) - 45) < 0.5)
    }

    // MARK: Tail

    @Test func theTailSagsKeepsItsLengthAndIsDrawnWhereItWasSimulated() {
        var body = layers()
        let pose = run(&body, seconds: 3, frame: frame())
        let model = Self.solver.modelMatrices(of: pose)
        let drawn = Self.tail.map { PoseSolver.translation(of: model[$0]) }
        let simulated = body.tail!.positions
        for (a, b) in zip(drawn, simulated) { #expect(simd_distance(a, b) < 1e-3) }
        // It droops, and stays the length it was modelled.
        #expect(drawn.last!.y < drawn.first!.y - 0.03)
        let length = zip(drawn, drawn.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
        #expect(abs(length - 0.8) < 1e-3)
    }

    @Test func aTailSwitchedOffIsThePoseItWasGiven() {
        var body = layers()
        _ = run(&body, seconds: 1, frame: frame())
        body.tail?.enabled = false
        let pose = run(&body, seconds: 1, frame: frame())
        #expect(pose == Self.rest)
    }

    @Test func aHandUnderTheTailLiftsIt() {
        var free = layers()
        let hanging = run(&free, seconds: 2, frame: frame())
        // The joint over the hand; the tip past it is free to drape.
        let middle = Self.tail[2]
        let freeHeight = PoseSolver.translation(of: Self.solver.modelMatrices(of: hanging)[middle]).y

        var body = layers()
        // A palm raised into where the middle of the tail hangs.
        let palm = ChainDynamics.Sphere(center: SIMD3(0, 0.9, -0.5), radius: 0.05)
        let pose = run(&body, seconds: 2, frame: frame(obstacles: [palm]))
        let held = PoseSolver.translation(of: Self.solver.modelMatrices(of: pose)[middle]).y
        #expect(body.tail?.touching == true)
        #expect(held > freeHeight + 0.01)
        // Nothing is inside the hand.
        for position in body.tail!.positions {
            #expect(simd_distance(position, palm.center) > palm.radius)
        }
    }

    @Test func theTailStaysOffTheFloor() {
        var body = layers()
        body.tail?.settings.gravityScale = 6
        let pose = run(&body, seconds: 2, frame: frame(floor: 0.8))
        let model = Self.solver.modelMatrices(of: pose)
        for joint in Self.tail.dropFirst() {
            #expect(PoseSolver.translation(of: model[joint]).y > 0.8)
        }
    }

    @Test func aMovedBodyTrailsItsTail() {
        var body = layers()
        _ = run(&body, seconds: 2, frame: frame())
        // Walk forward (+Z) at 1 m/s for a second.
        var pose = Self.rest
        var offset: Float = 0
        for _ in 0..<90 {
            offset += 1.0 / 90
            var move = matrix_identity_float4x4
            move.columns.3 = SIMD4(0, 0, offset, 1)
            pose = Self.rest
            body.apply(to: &pose, frame: frame(modelToWorld: move))
        }
        // In the body's own space the tip hangs further back than at rest.
        let model = Self.solver.modelMatrices(of: pose)
        let tip = PoseSolver.translation(of: model[Self.tail[4]])
        var still = layers()
        let resting = run(&still, seconds: 3, frame: frame())
        let restTip = PoseSolver.translation(of: Self.solver.modelMatrices(of: resting)[Self.tail[4]])
        #expect(tip.y > restTip.y)
    }

    // MARK: Hands on the tail

    @Test func aHandClosingOnTheTailTakesHoldAndTheJointGoesWithIt() {
        var (body, point) = grabbed(joint: 3)
        #expect(body.tail?.held == true)
        #expect(body.tail?.heldJoints[0] == 3)
        // Carried up and to the side, well within the tail's reach.
        let to = point + SIMD3<Float>(0.15, 0.15, 0.1)
        var pose = Self.rest
        for i in 1...60 {
            let at = point + (to - point) * (Float(i) / 60)
            pose = Self.rest
            body.apply(to: &pose, frame: frame(hands: [hand(at: at, closure: 1)]))
        }
        pose = run(&body, seconds: 0.5, frame: frame(hands: [hand(at: to, closure: 1)]))
        let drawn = Self.tail.map { PoseSolver.translation(of: Self.solver.modelMatrices(of: pose)[$0]) }
        #expect(simd_distance(drawn[3], to) < 0.01)
        let length = zip(drawn, drawn.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
        #expect(abs(length - 0.8) < 1e-3)
        // Within reach nothing pulls on the body.
        #expect(simd_length(body.tail!.pull) < 0.005)
        #expect(pose[Self.hips].translation == Self.rest[Self.hips].translation)
    }

    @Test func aFistThatArrivesClosedOnlyPushes() {
        var body = layers()
        _ = run(&body, seconds: 2, frame: frame())
        let point = body.tail!.positions[3]
        // Closed for a second somewhere else, then moved onto the tail.
        _ = run(&body, seconds: 1, frame: frame(hands: [hand(at: point + SIMD3(0, 1, 0), closure: 1, palm: true)]))
        _ = run(&body, seconds: 0.5, frame: frame(hands: [hand(at: point, closure: 1, palm: true)]))
        #expect(body.tail?.held == false)
        #expect(body.tail?.touching == true)
    }

    @Test func openingTheHandLetsGo() {
        var (body, point) = grabbed(joint: 2)
        _ = run(&body, seconds: 0.2, frame: frame(hands: [hand(at: point, closure: 0.2)]))
        #expect(body.tail?.held == false)
        #expect(body.tail?.events.isEmpty == true)
    }

    @Test func aHandThatIsLostLetsGo() {
        var (body, _) = grabbed(joint: 2)
        var pose = Self.rest
        body.apply(to: &pose, frame: frame())
        #expect(body.tail?.held == false)
        #expect(body.tail?.events == [.released(hand: 0)])
    }

    @Test func aPullPastTheTailsReachTugsTheHips() {
        var (body, _) = grabbed(joint: 4)
        body.tail?.slipStretch = 1
        let base = body.tail!.positions[0]
        // Straight back, 8 cm further than the tail is long.
        let to = base + SIMD3<Float>(0, 0, -(0.8 + 0.08))
        let pose = run(&body, seconds: 1, frame: frame(hands: [hand(at: to, closure: 1)]))
        // The hips give toward the hand, which takes up part of the pull:
        // what is left is the 8 cm shared between the tail and the body.
        let pull = body.tail!.pull
        let left = 0.08 / (1 + body.give.gain)
        #expect(abs(simd_length(pull) - left) < 0.005)
        #expect(pull.z < 0)
        let shift = pose[Self.hips].translation - Self.rest[Self.hips].translation
        #expect(abs(shift.z - -left * body.give.gain) < 0.005)
        #expect(abs(shift.x) < 0.002 && abs(shift.y) < 0.002)
        let drawn = Self.tail.map { PoseSolver.translation(of: Self.solver.modelMatrices(of: pose)[$0]) }
        #expect(abs(simd_distance(drawn[0], drawn[4]) - 0.8) < 0.005)
    }

    @Test func theHipsGiveOnlySoFar() {
        var (body, _) = grabbed(joint: 4)
        body.tail?.slipStretch = 10
        let base = body.tail!.positions[0]
        let pose = run(&body, seconds: 1, frame: frame(hands: [hand(at: base + SIMD3(0, 0, -1.8), closure: 1)]))
        let shift = pose[Self.hips].translation - Self.rest[Self.hips].translation
        #expect(abs(simd_length(shift) - body.give.limit) < 0.002)
        // Let go, and they come back.
        let after = run(&body, seconds: 1.5, frame: frame())
        #expect(simd_distance(after[Self.hips].translation, Self.rest[Self.hips].translation) < 0.001)
    }

    @Test func pulledTooHardTheTailSlidesOutOfTheHand() {
        var (body, _) = grabbed(joint: 2)
        let base = body.tail!.positions[0]
        // Well past where even the tip can reach.
        let to = base + SIMD3<Float>(0, 0, -1.2)
        var slipped = false
        var furthest = 2
        var pose = Self.rest
        for _ in 0..<90 {
            pose = Self.rest
            body.apply(to: &pose, frame: frame(hands: [hand(at: to, closure: 1)]))
            furthest = max(furthest, body.tail!.heldJoints[0] ?? furthest)
            if body.tail!.events.contains(.slipped(hand: 0)) { slipped = true }
        }
        // Joint by joint toward the tip, then free.
        #expect(furthest == 4)
        #expect(slipped)
        #expect(body.tail?.held == false)
    }

    @Test func aLooseHandHoldsLess() {
        /// The joint a hand ends up holding after pulling joint 2 15 cm
        /// past its reach for a few seconds.
        func jointHeld(closure: Float) -> Int? {
            var (body, _) = grabbed(joint: 2)
            let from = body.tail!.positions[2]
            let to = body.tail!.positions[0] + SIMD3<Float>(0, 0, -0.55)
            var pose = Self.rest
            // Drawn back over a second, not yanked.
            for i in 1...90 {
                pose = Self.rest
                body.apply(to: &pose, frame: frame(hands: [hand(at: from + (to - from) * (Float(i) / 90),
                                                               closure: closure)]))
            }
            _ = run(&body, seconds: 2, frame: frame(hands: [hand(at: to, closure: closure)]))
            return body.tail!.heldJoints[0]
        }
        // A fist keeps the joint it took. Through a half-closed hand the
        // tail slides until the hand holds a joint that reaches.
        #expect(jointHeld(closure: 1) == 2)
        #expect(jointHeld(closure: 0.65) == 3)
    }

    @Test func anAffectionateTailCurlsRoundAHand() {
        // A finer tail than the character's, as long: ten joints 9 cm apart.
        var joints: [(String, SIMD3<Float>)] = [("Root", [0, 0, 0]), ("Root/Hips", [0, 0.95, 0])]
        var path = "Root/Hips"
        for i in 1...10 {
            path += "/Tail_\(i)"
            joints.append((path, [0, 0, i == 1 ? -0.1 : -0.09]))
        }
        let names = joints.map(\.0)
        let rest = joints.map { JointPose(translation: $0.1) }
        let chain = Array(names[2...])
        /// How far round the hand the tail goes, from where it meets it to
        /// its tip, in degrees.
        func winding(affinity: Float) -> Float {
            var body = BodyLayers(jointNames: names, parents: PoseSolver.parents(fromPaths: names), rest: rest,
                                  rig: BodyLayers.Rig(tail: chain))
            body.tail?.affinity = affinity
            var pose = rest
            for _ in 0..<180 {
                pose = rest
                body.apply(to: &pose, frame: frame())
            }
            // An open palm brought up under the tail, a third of the way along.
            let under = body.tail!.positions[3] + SIMD3<Float>(0, -0.07, 0)
            for _ in 0..<270 {
                pose = rest
                body.apply(to: &pose, frame: frame(hands: [hand(at: under, closure: 0, palm: true)]))
            }
            let positions = body.tail!.positions
            // Nothing is inside the hand, however it is wrapped.
            for position in positions { #expect(simd_distance(position, under) > 0.045) }
            var total: Float = 0
            for (a, b) in zip(positions[3...], positions[4...]) {
                total += degrees(between: a - under, and: b - under)
            }
            return total
        }
        let plain = winding(affinity: 0), fond = winding(affinity: 1)
        #expect(fond > plain + 60)
        #expect(fond > 180)
    }

    @Test func aWaryTailDrawsAwayFromAHand() {
        func tip(affinity: Float) -> SIMD3<Float> {
            var body = layers()
            body.tail?.affinity = affinity
            _ = run(&body, seconds: 2, frame: frame())
            // A hand beside the tail, near but not touching.
            let beside = body.tail!.positions[3] + SIMD3<Float>(0.15, 0, 0)
            _ = run(&body, seconds: 2, frame: frame(hands: [hand(at: beside, closure: 0, palm: true)]))
            return body.tail!.positions[4]
        }
        #expect(tip(affinity: -1).x < tip(affinity: 0).x - 0.04)
    }

    @Test func theLegsAreFoundForTheTailToStayOutOf() {
        #expect(layers().legs.count == 2)
        #expect(layers(rig: BodyLayers.Rig(tail: Self.tail.map { Self.names[$0] })).legs.isEmpty)
    }

    // MARK: The stack

    @Test func aJiggleRequestOnTheTailIsTheTailLayers() {
        let body = layers(jiggle: [.tail("Tail_1", chainLength: 5)])
        #expect(body.jiggle == nil)
        #expect(body.jiggleOnTail == ["Tail_1"])
        #expect(body.tail != nil)
    }

    @Test func aCharacterWithNoTailOrHeadGetsNoLayers() {
        let body = layers(rig: BodyLayers.Rig())
        #expect(body.look == nil && body.tail == nil && body.jiggle == nil)
        var pose = Self.rest
        var copy = body
        copy.apply(to: &pose, frame: frame(lookAt: SIMD3(1, 1, 1)))
        #expect(pose == Self.rest)
    }

    @Test func aRigNamingJointsThePoseLacksIsLeftAlone() {
        let body = layers(rig: BodyLayers.Rig(head: "Skull", tail: ["Tail_1", "Tail_2", "Nope"]))
        #expect(body.look == nil && body.tail == nil)
    }
}
