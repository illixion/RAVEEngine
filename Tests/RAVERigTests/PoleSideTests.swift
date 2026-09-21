import XCTest
import simd
@testable import RAVERig

/// The pole fixes the bend plane always; whether it also picks the side of
/// the bend is `bendTowardPole`'s call.
final class PoleSideTests: XCTestCase {

    // A two-segment arm hanging from the origin, elbow already bent toward
    // -X. Targets in front of it (+Z) with a pole toward +X.
    let chain = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(-3, 0, 4), SIMD3<Float>(0, 0, 8)]
    let target = SIMD3<Float>(0, 0, 7)
    let pole = SIMD3<Float>(1, 0, 0)

    func side(_ s: FABRIK.Solution) -> Float { simd_dot(s.positions[1], pole) }

    func testSeedKeepsItsSideByDefault() {
        let s = FABRIK.solve(chain: chain, target: target, pole: pole, iterations: 32)
        XCTAssertTrue(s.reached)
        XCTAssertLessThan(side(s), 0, "the seed had the elbow away from the pole and nothing asked to change that")
    }

    func testBendTowardPoleMirrorsTheElbow() {
        let s = FABRIK.solve(chain: chain, target: target, pole: pole, bendTowardPole: true, iterations: 32)
        XCTAssertTrue(s.reached)
        XCTAssertGreaterThan(side(s), 0, "the elbow should now sit on the pole's side")
        // Same plane, same lengths, mirror image.
        let plain = FABRIK.solve(chain: chain, target: target, pole: pole, iterations: 32)
        XCTAssertEqual(abs(side(s)), abs(side(plain)), accuracy: 1e-3)
        XCTAssertEqual(s.positions[1].y, 0, accuracy: 1e-5)
        for (a, b) in zip(FABRIK.lengths(of: s.positions), FABRIK.lengths(of: chain)) {
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    func testAlreadyOnThePoleSideIsUntouched() {
        let bent = [chain[0], SIMD3<Float>(3, 0, 4), chain[2]]
        let a = FABRIK.solve(chain: bent, target: target, pole: pole, bendTowardPole: true, iterations: 32)
        let b = FABRIK.solve(chain: bent, target: target, pole: pole, iterations: 32)
        XCTAssertEqual(simd_distance(a.positions[1], b.positions[1]), 0, accuracy: 1e-5)
    }

    func testDegeneratePlaneLeavesTheChainAlone() {
        // Pole along the target line: no plane, so no side to choose.
        let s = FABRIK.solve(chain: chain, target: target, pole: SIMD3<Float>(0, 0, 1), bendTowardPole: true, iterations: 32)
        XCTAssertTrue(s.reached)
        XCTAssertLessThan(s.positions[1].x, 0)
    }

    func testPoseSolverPassesItThrough() {
        // Three joints in a straight vertical chain, elbow seeded toward -X
        // via a small rotation; solve with the pole toward +X.
        let parents: [Int?] = [nil, 0, 1]
        var pose = [JointPose(rotation: simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0)), translation: .zero),
                    JointPose(rotation: simd_quatf(angle: -1.2, axis: SIMD3<Float>(0, 1, 0)), translation: SIMD3<Float>(0, 0, 5)),
                    JointPose(rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), translation: SIMD3<Float>(0, 0, 5))]
        let solver = PoseSolver(parents: parents)
        var model = solver.modelMatrices(of: pose)
        let seedElbow = PoseSolver.translation(of: model[1])
        let chain = solver.chain([0, 1, 2])!
        let t = SIMD3<Float>(0, 0, 8)
        let dir: SIMD3<Float> = seedElbow.x < 0 ? SIMD3(1, 0, 0) : SIMD3(-1, 0, 0)   // opposite the seed
        solver.solve(chain: chain, target: t, pole: dir, bendTowardPole: true, iterations: 32,
                     pose: &pose, model: &model)
        let elbow = PoseSolver.translation(of: model[1])
        XCTAssertGreaterThan(simd_dot(elbow, dir), 0.5)
        XCTAssertEqual(simd_distance(PoseSolver.translation(of: model[2]), t), 0, accuracy: 1e-2)
    }
}
