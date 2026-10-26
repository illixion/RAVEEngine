import Testing
import simd
@testable import RAVERig

@Suite("Shared performer body tracking")
struct PerformerBodyTrackingTests {
    @Test("Head and tracked fingers win; cameras fill only the missing anatomy")
    func sourcePriority() throws {
        var tracking = PerformerBodyTracking()
        let head = SIMD3<Float>(0, 1.6, 0)
        let wrist = SIMD3<Float>(-0.2, 1, -0.3)
        let rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let hand = PerformerHand(wrist: wrist, thumb: [wrist], fingers: [[wrist]])
        let headset = PerformerFrame(head: head, headRotation: rotation, left: hand)
        let elbow = SIMD3<Float>(-0.2, 1.2, 0)
        let camera = PerformerBodyObservation(lower: nil, chest: rotation, chestConfidence: 0.9,
            left: .init(wrist: SIMD3(9, 9, 9), elbow: elbow, confidence: 0.9),
            right: .init(wrist: SIMD3(0.3, 1, -0.3), elbow: nil, confidence: 0.9))
        let result = tracking.update(camera, headset: headset, fallback: nil, deltaTime: 1 / 60)
        let frame = try #require(result.frame)
        #expect(frame.head == head)
        #expect(frame.left?.wrist == wrist)
        #expect(frame.left?.thumb == hand.thumb)
        #expect(frame.left?.forearm == elbow)
        #expect(frame.right?.fingers.isEmpty == true)
        #expect(result.cameraArms == [false, true])
        #expect(frame.torso != nil)
    }

    @Test("Low-confidence cameras cannot take over an arm; torso fades after loss")
    func loss() {
        var tracking = PerformerBodyTracking()
        let rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let headset = PerformerFrame(head: SIMD3(0, 1.6, 0), headRotation: rotation)
        let observation = PerformerBodyObservation(lower: nil, chest: rotation, chestConfidence: 1,
            left: .init(wrist: SIMD3(0, 1, 0), elbow: nil, confidence: 0.1))
        var result = tracking.update(observation, headset: headset, fallback: nil, deltaTime: 1)
        #expect(result.frame?.left == nil)
        #expect(result.frame?.torso?.weight == 1)
        result = tracking.update(nil, headset: headset, fallback: nil, deltaTime: 0.5)
        #expect(result.frame?.torso == nil)
    }

    @Test("Reflecting the lower body twice preserves all measurements")
    func reflection() {
        let calibration = PerformerRigTests.calibration
        let turn = simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        let lower = PerformerLowerBody(pelvis: SIMD3(0.1, 0.9, 0.2), pelvisRotation: turn,
            left: PerformerFoot(ankle: SIMD3(-0.1, 0.2, -0.3), rotation: turn, planted: false),
            right: PerformerFoot(ankle: SIMD3(0.1, 0.08, 0), rotation: turn, planted: true), floor: 0)
        let mirrored = lower.reflected(calibration: calibration)
        #expect(mirrored.left.ankle.y == lower.right.ankle.y)
        let restored = mirrored.reflected(calibration: calibration)
        #expect(simd_distance(restored.left.ankle, lower.left.ankle) < 1e-5)
        #expect(abs(simd_dot(restored.left.rotation.vector, lower.left.rotation.vector)) > 0.99999)
    }

    @Test("The mirror lifts the reflected foot from the same lower-body solve")
    func mirroredLegs() {
        var own = PerformerRigLegTests.rig()
        var mirror = PerformerRigLegTests.rig()
        var lower = PerformerRigLegTests.standing(own).lowerBody
        lower.left.ankle.y += 0.2
        lower.left.ankle.z -= 0.1
        lower.left.planted = false
        let ownPose = own.solve(base: own.skeleton.rest, frame: nil, calibration: PerformerRigTests.calibration,
                                mirrored: false, deltaTime: 1 / 60, lowerBody: lower)
        let mirrorPose = mirror.solve(base: mirror.skeleton.rest, frame: nil, calibration: PerformerRigTests.calibration,
                                     mirrored: true, deltaTime: 1 / 60, lowerBody: lower)
        let solver = PoseSolver(parents: own.skeleton.parents)
        let a = solver.modelMatrices(of: ownPose), b = solver.modelMatrices(of: mirrorPose)
        let left = PoseSolver.translation(of: a[25]), right = PoseSolver.translation(of: a[30])
        let reflected = PoseSolver.translation(of: b[30])
        #expect(left.y > right.y + 0.1)
        #expect(abs(left.y - reflected.y) < 0.002)
        #expect(abs(left.x + reflected.x) < 0.002)
    }
}
