import Testing
import simd
@testable import RAVERig

/// A digitigrade leg as the Synth has one: hip, knee forward, hock back, and a
/// foot segment from the hock down to the toe. Lengths in metres, +z forward.
private func digitigrade() -> (solver: PoseSolver, pose: [JointPose], chain: PoseSolver.Chain) {
    let pose = [
        JointPose(translation: [0, 0.9, 0]),       // hip
        JointPose(translation: [0, -0.35, 0.12]),  // knee, ahead of the hip
        JointPose(translation: [0, -0.33, -0.15]), // hock, behind the knee
        JointPose(translation: [0, -0.2, 0.06]),   // toe on the floor
    ]
    let solver = PoseSolver(parents: [nil, 0, 1, 2])
    return (solver, pose, solver.chain([0, 1, 2, 3])!)
}

private func points(_ solver: PoseSolver, _ pose: [JointPose]) -> [SIMD3<Float>] {
    solver.modelMatrices(of: pose).map(PoseSolver.translation(of:))
}

@Test func aDigitigradeLegReachesAndKeepsItsFoot() {
    let (solver, rest, chain) = digitigrade()
    let before = points(solver, rest)
    var pose = rest
    var model = solver.modelMatrices(of: pose)
    let target = SIMD3<Float>(0.05, 0.08, 0.25)
    let report = solver.solveLeg(chain: chain, target: target, pole: [0, 0, 1], pose: &pose, model: &model)
    let after = points(solver, pose)
    #expect(report.reached, "error \(report.error)")
    #expect(simd_distance(after[3], target) < 1e-3, "forward kinematics agrees with the solve")
    // The foot segment keeps its direction; only the thigh and shin bend.
    #expect(simd_distance(after[3] - after[2], before[3] - before[2]) < 1e-3)
    // Bone lengths survive.
    for i in 1..<4 {
        #expect(abs(simd_distance(after[i], after[i - 1]) - simd_distance(before[i], before[i - 1])) < 1e-4)
    }
    #expect(after[1].z > after[0].z, "the knee bends toward the pole")
}

@Test func neighbouringTargetsGiveNeighbouringLegs() {
    // The property FABRIK lacked on device: a foot moving a millimetre at a
    // time must never make the knee jump.
    let (solver, rest, chain) = digitigrade()
    var lastKnee: SIMD3<Float>?
    var worst: Float = 0
    for step in 0...300 {
        let t = Float(step) / 300
        let target = SIMD3<Float>(0.08 * sin(t * 6), 0.04 + 0.1 * max(0, sin(t * 12)), -0.3 + 0.6 * t)
        var pose = rest
        var model = solver.modelMatrices(of: pose)
        solver.solveLeg(chain: chain, target: target, pole: [0, 0, 1], pose: &pose, model: &model)
        let knee = points(solver, pose)[1]
        if let lastKnee { worst = max(worst, simd_distance(knee, lastKnee)) }
        lastKnee = knee
    }
    #expect(worst < 0.02, "largest knee jump between neighbouring frames: \(worst) m")
}

@Test func anOutOfReachTargetStretchesWithoutFlipping() {
    let (solver, rest, chain) = digitigrade()
    var pose = rest
    var model = solver.modelMatrices(of: pose)
    let report = solver.solveLeg(chain: chain, target: [0, -1, 0.2], pole: [0, 0, 1], pose: &pose, model: &model)
    #expect(report.outOfReach)
    #expect(report.extended)
    let after = points(solver, pose)
    #expect(after[1].z >= after[0].z - 1e-3, "still bent the right way at full stretch")
}

@Test func aTwoBoneLegIsTheTextbookSolve() {
    let solver = PoseSolver(parents: [nil, 0, 1])
    let rest = [JointPose(translation: [0, 1, 0]), JointPose(translation: [0, -0.5, 0.01]),
                JointPose(translation: [0, -0.5, 0])]
    var pose = rest
    var model = solver.modelMatrices(of: pose)
    let target = SIMD3<Float>(0, 0.2, 0.3)
    let report = solver.solveLeg(chain: solver.chain([0, 1, 2])!, target: target, pole: [0, 0, 1],
                                 pose: &pose, model: &model)
    #expect(report.reached)
    let after = points(solver, pose)
    #expect(simd_distance(after[2], target) < 1e-3)
    #expect(after[1].z > 0.15, "knee forward of the hip-ankle line")
}
