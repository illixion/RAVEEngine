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
    ]
    static let names = joints.map(\.0)
    static let parents = PoseSolver.parents(fromPaths: names)
    static let rest = joints.map { JointPose(translation: $0.1) }
    static let neck = 3, head = 4
    static let tail = [5, 6, 7, 8, 9]
    static let rig = BodyLayers.Rig(head: "Head", neck: ["Neck"], tail: tail.map { names[$0] })
    static let solver = PoseSolver(parents: parents)

    private func layers(rig: BodyLayers.Rig = BodyLayersTests.rig, jiggle: [JiggleSpec] = []) -> BodyLayers {
        BodyLayers(jointNames: Self.names, parents: Self.parents, rest: Self.rest, rig: rig, jiggle: jiggle)
    }

    private func frame(lookAt: SIMD3<Float>? = nil, fps: Float = 90, floor: Float? = nil,
                       obstacles: [ChainDynamics.Sphere] = [],
                       modelToWorld: float4x4 = matrix_identity_float4x4) -> BodyLayers.Frame {
        BodyLayers.Frame(modelToWorld: modelToWorld, deltaTime: 1 / fps, lookAt: lookAt, floor: floor,
                         obstacles: obstacles)
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
