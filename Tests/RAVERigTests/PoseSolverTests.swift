import Testing
import simd
@testable import RAVERig

/// The property that matters for `PoseSolver` is not that FABRIK found an
/// answer — `FABRIKTests` covers that — but that the answer survives the trip
/// back into joint rotations. A solved chain is useless if replaying the pose
/// through ordinary forward kinematics lands somewhere else, and that is
/// exactly what a wrong change-of-basis or a stale parent matrix produces.
@Suite("PoseSolver")
struct PoseSolverTests {

    /// Three joints hanging straight down, one unit apart: root, mid, tip.
    private static func straightChain() -> (solver: PoseSolver, pose: [JointPose]) {
        let pose = [
            JointPose(),
            JointPose(translation: SIMD3<Float>(0, -1, 0)),
            JointPose(translation: SIMD3<Float>(0, -1, 0)),
        ]
        return (PoseSolver(parents: [nil, 0, 1]), pose)
    }

    private static func tip(_ solver: PoseSolver, _ pose: [JointPose]) -> SIMD3<Float> {
        PoseSolver.translation(of: solver.modelMatrices(of: pose)[2])
    }

    @Test("the rest pose measures as built")
    func restPose() {
        let (solver, pose) = Self.straightChain()
        #expect(Self.tip(solver, pose) == SIMD3<Float>(0, -2, 0))
    }

    @Test("a solved chain replays to the same place through forward kinematics")
    func rotationsReproduceSolvedPositions() {
        let (solver, rest) = Self.straightChain()
        var pose = rest
        var model = solver.modelMatrices(of: pose)
        let chain = try! #require(solver.chain([0, 1, 2]))
        let target = SIMD3<Float>(1, -1, 0)

        let report = solver.solve(chain: chain, target: target, pose: &pose, model: &model)
        #expect(report.reached)
        #expect(!report.outOfReach)

        // The solver's own running matrices put the tip on the target...
        #expect(simd_distance(PoseSolver.translation(of: model[2]), target) < 1e-3)
        // ...and so does a clean forward-kinematics pass over the rotations it
        // wrote. This is the check that catches a bad change of basis: the
        // two agree only if each joint's stored rotation really is expressed
        // in its parent's space.
        #expect(simd_distance(Self.tip(solver, pose), target) < 1e-3)
    }

    @Test("segment lengths are preserved")
    func lengthsPreserved() {
        let (solver, rest) = Self.straightChain()
        var pose = rest
        var model = solver.modelMatrices(of: pose)
        let chain = try! #require(solver.chain([0, 1, 2]))
        solver.solve(chain: chain, target: SIMD3<Float>(1.2, -0.8, 0.3), pose: &pose, model: &model)

        let m = solver.modelMatrices(of: pose)
        let p = (0...2).map { PoseSolver.translation(of: m[$0]) }
        #expect(abs(simd_distance(p[0], p[1]) - 1) < 1e-4)
        #expect(abs(simd_distance(p[1], p[2]) - 1) < 1e-4)
    }

    @Test("an unreachable target is reported, not faked")
    func outOfReach() {
        let (solver, rest) = Self.straightChain()
        var pose = rest
        var model = solver.modelMatrices(of: pose)
        let chain = try! #require(solver.chain([0, 1, 2]))
        let report = solver.solve(chain: chain, target: SIMD3<Float>(0, -10, 0),
                                  pose: &pose, model: &model)
        #expect(report.outOfReach)
        #expect(!report.reached)
        // Still points at it, at full usable extension rather than stretched.
        let reach = simd_length(Self.tip(solver, pose))
        #expect(reach <= 2.0001)
        #expect(reach > 1.9)
    }

    @Test("zero weight leaves the pose alone")
    func zeroWeightIsIdentity() {
        let (solver, rest) = Self.straightChain()
        var pose = rest
        var model = solver.modelMatrices(of: pose)
        let chain = try! #require(solver.chain([0, 1, 2]))
        solver.solve(chain: chain, target: SIMD3<Float>(1, -1, 0), weight: 0,
                     pose: &pose, model: &model)
        #expect(simd_distance(Self.tip(solver, pose), SIMD3<Float>(0, -2, 0)) < 1e-4)
    }

    @Test("a chain that is not a run down the skeleton is refused")
    func chainValidation() {
        // 0 -> 1 -> 2, and a sibling 3 hanging off the root.
        let solver = PoseSolver(parents: [nil, 0, 1, 0])
        #expect(solver.chain([0, 1, 2]) != nil)
        #expect(solver.chain([0, 2]) != nil)      // through 1, a segment
        #expect(solver.chain([0, 1, 3]) == nil)   // 3's parent is 0, not 1
        #expect(solver.chain([2, 1, 0]) == nil)   // right joints, wrong direction
        #expect(solver.chain([1]) == nil)         // too short
        #expect(solver.chain([0, 99]) == nil)     // out of range
    }

    @Test("traversal order puts parents first even when declaration order does not")
    func traversalOrderSortsByDepth() {
        // Declared tip-first: 0 is the leaf, 2 is the root.
        let parents: [Int?] = [1, 2, nil]
        let order = PoseSolver.traversalOrder(parents: parents)
        #expect(order == [2, 1, 0])

        // And forward kinematics over that order still accumulates correctly.
        let solver = PoseSolver(parents: parents)
        let pose = [
            JointPose(translation: SIMD3<Float>(0, -1, 0)),
            JointPose(translation: SIMD3<Float>(0, -1, 0)),
            JointPose(translation: SIMD3<Float>(0, 3, 0)),
        ]
        let m = solver.modelMatrices(of: pose)
        #expect(PoseSolver.translation(of: m[0]) == SIMD3<Float>(0, 1, 0))
    }

    @Test("a cyclic parent list is treated as rooted rather than hanging")
    func cycleIsSurvivable() {
        let order = PoseSolver.traversalOrder(parents: [1, 0])
        #expect(order.count == 2)
        #expect(Set(order) == Set([0, 1]))
    }

    @Test("parents can be read off hierarchical joint names")
    func parentsFromPaths() {
        let names = ["root", "root/hip", "root/hip/knee", "root/spine"]
        #expect(PoseSolver.parents(fromPaths: names) == [nil, 0, 1, 0])
    }

    @Test("a joint's scale is carried through the solve")
    func scaleIsRespected() {
        // A mid joint scaled 2x doubles the length of the segment below it, and
        // the solver must rebuild that length rather than the rest length.
        let solver = PoseSolver(parents: [nil, 0, 1])
        var pose = [
            JointPose(),
            JointPose(translation: SIMD3<Float>(0, -1, 0), scale: SIMD3<Float>(repeating: 2)),
            JointPose(translation: SIMD3<Float>(0, -1, 0)),
        ]
        var model = solver.modelMatrices(of: pose)
        #expect(simd_distance(PoseSolver.translation(of: model[2]), SIMD3<Float>(0, -3, 0)) < 1e-4)

        let chain = try! #require(solver.chain([0, 1, 2]))
        solver.solve(chain: chain, target: SIMD3<Float>(2, -1, 0), pose: &pose, model: &model)
        let m = solver.modelMatrices(of: pose)
        let p = (0...2).map { PoseSolver.translation(of: m[$0]) }
        #expect(abs(simd_distance(p[0], p[1]) - 1) < 1e-4)
        #expect(abs(simd_distance(p[1], p[2]) - 2) < 1e-4)
    }

    /// Blender's Rigify splits every limb bone in two: shoulder,
    /// `upper_arm.001`, elbow, `forearm.001`, hand, each half a bone long.
    /// The solve treats shoulder → elbow → hand as two bones, and the halves
    /// ride on the joint above them, staying on its bone.
    @Test("a limb split into segments solves as two bones, its segments riding along")
    func segmentedLimb() throws {
        let half = JointPose(translation: SIMD3<Float>(0, -0.5, 0))
        let rest = [JointPose(), half, half, half, half]
        let solver = PoseSolver(parents: [nil, 0, 1, 2, 3])
        #expect(solver.segments(from: 0, to: 2) == [1])
        #expect(solver.segments(from: 0, to: 1) == [])
        #expect(solver.chain([0, 4]) == nil)          // three between: not a limb bone
        let chain = try #require(solver.chain([0, 2, 4]))

        for closedForm in [false, true] {
            var pose = rest
            var model = solver.modelMatrices(of: pose)
            let target = SIMD3<Float>(0.9, -1.1, 0.2)
            let report = closedForm
                ? solver.solveLeg(chain: chain, target: target, pole: SIMD3(0, 0, 1), pose: &pose, model: &model)
                : solver.solve(chain: chain, target: target, pole: SIMD3(0, 0, 1), pose: &pose, model: &model)
            #expect(report.reached)
            // Forward kinematics agrees with the solver's running matrices,
            // segments included: they were kept current, not left stale.
            let replay = solver.modelMatrices(of: pose)
            for joint in 0..<5 {
                #expect(simd_distance(PoseSolver.translation(of: replay[joint]),
                                      PoseSolver.translation(of: model[joint])) < 1e-4)
            }
            let p = (0..<5).map { PoseSolver.translation(of: replay[$0]) }
            #expect(simd_distance(p[4], target) < 2e-3)
            // Each segment sits halfway along its bone, which stayed straight.
            #expect(simd_distance(p[1], (p[0] + p[2]) / 2) < 1e-4)
            #expect(simd_distance(p[3], (p[2] + p[4]) / 2) < 1e-4)
            #expect(abs(simd_distance(p[0], p[2]) - 1) < 1e-4)
            // It bent: the elbow is off the shoulder-to-hand line.
            let line = simd_normalize(p[4] - p[0])
            let off = (p[2] - p[0]) - simd_dot(p[2] - p[0], line) * line
            #expect(simd_length(off) > 0.1)
        }
    }
}
