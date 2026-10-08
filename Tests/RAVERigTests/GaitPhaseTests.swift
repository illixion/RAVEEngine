import Testing
import simd
@testable import RAVERig

/// One foot over a walk cycle of `n` frames: carried backward along `axis`
/// for `stance` of it, then swung forward, landing at frame `land`.
private func foot(frames n: Int, land: Int, stance: Float = 0.62,
                  axis: SIMD3<Float> = [0, 0, 1]) -> [SIMD3<Float>] {
    (0..<n).map { i in
        let local = Float((i - land + n) % n) / Float(n)
        let s: Float = local < stance
            ? 0.2 - 0.4 * local / stance
            : -0.2 + 0.4 * (local - stance) / (1 - stance)
        return axis * s + SIMD3<Float>(0, -0.8, 0)
    }
}

@Test func touchdownIsWhereTheFootIsFurthestForward() throws {
    let phase = try #require(GaitPhase.touchdown(footRelativeToHips: foot(frames: 30, land: 9)))
    #expect(abs(phase - 0.3) < 0.02)
}

@Test func touchdownDoesNotDependOnWhichWayTheClipFaces() throws {
    let facing: [SIMD3<Float>] = [[0, 0, 1], [0, 0, -1], [1, 0, 0], simd_normalize([1, 0, -1])]
    for axis in facing {
        let phase = try #require(GaitPhase.touchdown(footRelativeToHips: foot(frames: 30, land: 21, axis: axis)))
        #expect(abs(phase - 0.7) < 0.02, "facing \(axis)")
    }
}

@Test func aFootThatDoesNotMoveHasNoTouchdown() {
    let still = [SIMD3<Float>](repeating: [0, -0.8, 0], count: 20)
    #expect(GaitPhase.touchdown(footRelativeToHips: still) == nil)
}

@Test func clipPhaseWraps() {
    #expect(abs(GaitPhase.clipPhase(stepperPhase: 0.9, touchdown: 0.3) - 0.2) < 1e-5)
    #expect(abs(GaitPhase.clipPhase(stepperPhase: 0, touchdown: 0.3) - 0.3) < 1e-5)
}

@Test func rescalingTheStepKeepsThePhase() {
    var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.2)
    _ = stepper.step(hips: .zero, forward: [0, 0, 1], travelled: 0.1, floor: { _ in 0 })
    let before = stepper.phase
    stepper.rescale(stepLength: 0.8)
    #expect(abs(stepper.phase - before) < 1e-5)
    #expect(stepper.stepLength == 0.8)
}

@Test func playerShowsTheClipAtTheTimeItIsGiven() {
    let clip = PoseClip(frames: [[JointPose()], [JointPose(translation: [1, 0, 0])]],
                        frameInterval: 0.5, loops: true)
    var player = PosePlayer()
    player.play(clip, fade: 0)
    let pose = player.advance(0.016, at: 0.25)
    #expect(abs(pose[0].translation.x - 0.5) < 1e-5)
    #expect(player.time == 0.25)
}
