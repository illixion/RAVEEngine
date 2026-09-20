import Testing
import simd
@testable import RAVERig

/// FABRIK is here to replace a whole-body solver, so these test the
/// properties that solver failed at rather than the algorithm in the
/// abstract: the root stays put, the bones keep their length, the answer
/// does not depend on history, and the chain cannot drift sideways.
@Suite struct FABRIKTests {

    /// A digitigrade leg, roughly Synth-shaped: thigh, shin, hock, toe.
    private var leg: [SIMD3<Float>] {
        [SIMD3(0, 0.90, 0), SIMD3(0, 0.55, 0.05), SIMD3(0, 0.28, -0.08), SIMD3(0, 0.04, 0.06)]
    }

    private func lengths(_ chain: [SIMD3<Float>]) -> [Float] {
        zip(chain, chain.dropFirst()).map { simd_length($1 - $0) }
    }

    @Test func reachesATargetInsideItsRange() {
        let target = SIMD3<Float>(0.08, 0.15, 0.2)
        let solution = FABRIK.solve(chain: leg, target: target, pole: SIMD3(0, 0, 1))
        #expect(!solution.outOfReach)
        #expect(!solution.extended)
        #expect(solution.error < 1e-3)
        #expect(simd_distance(solution.positions.last!, target) < 1e-3)
    }

    /// The default iteration count has to be right across the whole range a
    /// step actually uses, not just the comfortable middle — this is the
    /// measurement `reachLimit` was chosen from.
    @Test func staysAccurateAtEveryExtensionAStepUses() {
        let total = lengths(leg).reduce(0, +)
        let direction = simd_normalize(SIMD3<Float>(0.1, -0.88, 0.25))
        for fraction in [Float(0.5), 0.7, 0.85, 0.95, 0.98] {
            let target = leg[0] + direction * (total * fraction)
            let solution = FABRIK.solve(chain: leg, target: target, pole: SIMD3(0, 0, 1))
            #expect(solution.error < 1e-3,
                    "at \(fraction) of reach the tip was \(solution.error) m short")
        }
    }

    /// Asked to lock the leg straight, it stops short and says so rather than
    /// hyperextending — and the shortfall is small enough to read as a
    /// straight leg.
    @Test func keepsTheLegOffItsStops() {
        let total = lengths(leg).reduce(0, +)
        let target = leg[0] + simd_normalize(SIMD3<Float>(0, -1, 0.2)) * total
        let solution = FABRIK.solve(chain: leg, target: target, pole: SIMD3(0, 0, 1))
        #expect(solution.extended)
        #expect(!solution.outOfReach)
        #expect(solution.error > 0.005)
        #expect(solution.error < 0.03)
    }

    @Test func leavesTheRootWhereItWas() {
        let solution = FABRIK.solve(chain: leg, target: SIMD3(0.2, 0.0, 0.3),
                                    pole: SIMD3(0, 0, 1))
        #expect(simd_distance(solution.positions[0], leg[0]) < 1e-5)
    }

    /// The property the whole thing rests on: a solved leg is the same leg.
    @Test func keepsEverySegmentLength() {
        let before = lengths(leg)
        let solution = FABRIK.solve(chain: leg, target: SIMD3(-0.15, 0.05, 0.2),
                                    pole: SIMD3(0, 0, 1), iterations: 20)
        let after = lengths(solution.positions)
        #expect(before.count == after.count)
        for (a, b) in zip(before, after) {
            #expect(abs(a - b) < 1e-4, "segment changed from \(a) to \(b)")
        }
    }

    /// An unreachable target must be reported, not silently approximated.
    /// A leg that is permanently short means the step length or the floor
    /// height is wrong, and that has to be visible rather than absorbed.
    @Test func reportsATargetItCannotReach() {
        let solution = FABRIK.solve(chain: leg, target: SIMD3(0, 0.9, 5),
                                    pole: SIMD3(0, 0, 1))
        #expect(solution.outOfReach)
        #expect(!solution.reached)
        #expect(solution.error > 4)
        let after = lengths(solution.positions)
        for (a, b) in zip(lengths(leg), after) { #expect(abs(a - b) < 1e-4) }
    }

    /// No state, so no drift. The old solver accumulated: the legs crept
    /// inward a little further with every step until the character tiptoed.
    /// Solving the same frame a hundred times running must not move it.
    @Test func doesNotDriftWhenRunRepeatedly() {
        let target = SIMD3<Float>(0.05, 0.2, 0.22)
        let first = FABRIK.solve(chain: leg, target: target, pole: SIMD3(0, 0, 1))
        var chain = leg
        for _ in 0..<100 {
            chain = FABRIK.solve(chain: chain, target: target, pole: SIMD3(0, 0, 1)).positions
        }
        for (a, b) in zip(first.positions, chain) {
            #expect(simd_distance(a, b) < 1e-3)
        }
    }

    /// The pole plane is what stops a leg answering a reach it is short of by
    /// swinging inward, which is exactly how the tiptoe walk looked.
    @Test func staysInThePolePlane() {
        // Plane through the hip containing the target and forward; its normal
        // is sideways, so every joint must keep the hip's x.
        let target = SIMD3<Float>(0, 0.02, 0.3)
        let solution = FABRIK.solve(chain: leg, target: target, pole: SIMD3(0, 0, 1),
                                    iterations: 20)
        for point in solution.positions {
            #expect(abs(point.x - leg[0].x) < 1e-3, "drifted sideways to \(point)")
        }
    }

    /// A leg started sideways is pulled into the plane rather than solved
    /// where it was, because the plane is the constraint the clip lacks.
    @Test func flattensASidewaysStart() {
        var splayed = leg
        splayed[1].x += 0.2
        splayed[2].x += 0.3
        let solution = FABRIK.solve(chain: splayed, target: SIMD3(0, 0.02, 0.3),
                                    pole: SIMD3(0, 0, 1), iterations: 20)
        for point in solution.positions { #expect(abs(point.x) < 1e-3) }
    }

    @Test func survivesADegenerateChain() {
        let single = [SIMD3<Float>(0, 1, 0)]
        let solution = FABRIK.solve(chain: single, target: .zero, pole: SIMD3(0, 0, 1))
        #expect(solution.positions == single)
        #expect(solution.iterations == 0)
    }
}
