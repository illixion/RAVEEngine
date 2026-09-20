import Testing
import simd
@testable import RAVERig

/// A chain cannot fold through itself. FABRIK already guarded the far stop —
/// a limb pulled taut — and this is the near one, which misbehaves the same
/// way for the same reason and had no guard at all.
@Suite("Folding")
struct FoldTests {

    /// A Half-Life arm, in the shape a rest pose actually has: upper 11.59,
    /// forearm 10.13, already carrying a little bend. Starting from a bend is
    /// not stacking the deck — a chain handed to the solver comes from an
    /// authored pose, and the perfectly straight case is covered on its own
    /// in `straightChainsStillBend`.
    private static let arm: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(0, -11.59, 0), SIMD3(3.0, -21.28, 0),
    ]
    private static let total: Float = 11.59 + 10.13
    private static let foldRadius: Float = (11.59 + 10.13) * 0.25

    @Test("the minimum reach is what the longest segment cannot fold away")
    func minimumReach() {
        #expect(abs(FABRIK.minimumReach(of: [11.59, 10.13]) - 1.46) < 0.01)
        // Evenly matched segments fold to a point.
        #expect(FABRIK.minimumReach(of: [10, 10]) == 0)
        // So does anything with enough links to close the polygon.
        #expect(FABRIK.minimumReach(of: [4, 3, 3]) == 0)
        // One dominant segment leaves a hole the rest cannot cover.
        #expect(FABRIK.minimumReach(of: [10, 2, 2]) == 6)
        #expect(FABRIK.minimumReach(of: []) == 0)
    }

    @Test("a target inside the fold radius is reported, not silently missed")
    func foldedIsReported() {
        let s = FABRIK.solve(chain: Self.arm, target: SIMD3<Float>(0.5, -2, 0), iterations: 32)
        #expect(s.folded)
        #expect(!s.outOfReach)
        #expect(!s.reached)
        // The error is measured against the real target, not the clamped aim,
        // so a caller can see how far the stop is from what it asked for.
        let asked = simd_length(SIMD3<Float>(0.5, -2, 0))
        #expect(abs(s.error - (Self.foldRadius - asked)) < 0.1)
    }

    @Test("a folded tip stops at the limit rather than crossing it")
    func foldedStopsAtTheLimit() {
        for dir in [SIMD3<Float>(0, -1, 0), simd_normalize(SIMD3<Float>(0.6, -0.8, 0.1)),
                    SIMD3<Float>(1, 0, 0)] {
            for d in [Float(0.2), 1, 3, 5] {
                let s = FABRIK.solve(chain: Self.arm, target: dir * d, iterations: 32)
                let reach = simd_length(s.positions.last!)
                #expect(s.folded)
                #expect(abs(reach - Self.foldRadius) < 0.05,
                        "aiming \(d) along \(dir) left the tip \(reach) out")
            }
        }
    }

    @Test("clamping keeps the solver out of the slow neighbourhood")
    func clampedIsStable() {
        // Inside the limit the answer stops depending on how many iterations
        // were spent, because the aim is a point the chain reaches comfortably
        // rather than one it can only creep up on.
        let target = SIMD3<Float>(0.3, -0.4, 0.2)
        let tips = [32, 64, 128].map {
            FABRIK.solve(chain: Self.arm, target: target, iterations: $0).positions.last!
        }
        for tip in tips.dropFirst() { #expect(simd_distance(tip, tips[0]) < 1e-2) }
    }

    @Test("a reachable target is not flagged as folded")
    func reachableIsNotFolded() {
        let s = FABRIK.solve(chain: Self.arm, target: SIMD3<Float>(8, -8, 0))
        #expect(!s.folded)
        #expect(!s.extended)
        #expect(s.reached)
    }

    /// The measurement that motivated the clamp: eight iterations were 130 mm
    /// adrift partway into the fold. Everything the limits leave in play is
    /// now exact at an iteration count cheap enough to ship.
    @Test("the whole usable volume is accurate at a shippable iteration count")
    func accurateWhereItMatters() {
        var checked = 0
        for r in stride(from: Float(0.5), through: 22, by: 0.25) {
            let target = simd_normalize(SIMD3<Float>(0.6, -0.8, 0.1)) * r
            let s = FABRIK.solve(chain: Self.arm, target: target, iterations: 32)
            if s.folded || s.extended { continue }
            checked += 1
            #expect(s.error < 2e-3, "distance \(r) left \(s.error) of error")
        }
        #expect(checked > 50)
    }

    /// The degeneracy the fold limit alone does not cure.
    ///
    /// A chain already lying along the line to its target has no bend plane:
    /// every FABRIK step moves a point along a line between two points already
    /// on it. Left alone the chain flips between fully folded and fully
    /// extended once per iteration and the answer depends on whether the loop
    /// stopped on an odd or an even pass. A standing leg reaching for the
    /// ground beneath it is exactly this shape, so it is worth a test of its
    /// own.
    @Test("a chain collinear with its target still bends")
    func straightChainsStillBend() {
        let straight: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, -11.59, 0), SIMD3(0, -21.72, 0),
        ]
        for d in [Float(7), 10, 14, 18] {
            let s = FABRIK.solve(chain: straight, target: SIMD3<Float>(0, -d, 0), iterations: 32)
            #expect(s.error < 2e-3, "aiming straight down at \(d) left \(s.error)")
            #expect(abs(simd_length(s.positions.last!) - d) < 2e-3)
            // And it really bent rather than telescoping: the elbow left the line.
            #expect(abs(s.positions[1].x) + abs(s.positions[1].z) > 1e-3)
        }
    }

    @Test("the pole decides which way a collinear chain bends")
    func poleBreaksTheTie() {
        let straight: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, -11.59, 0), SIMD3(0, -21.72, 0),
        ]
        let forward = FABRIK.solve(chain: straight, target: SIMD3<Float>(0, -14, 0),
                                   pole: SIMD3<Float>(1, 0, 0), iterations: 32)
        let backward = FABRIK.solve(chain: straight, target: SIMD3<Float>(0, -14, 0),
                                    pole: SIMD3<Float>(-1, 0, 0), iterations: 32)
        #expect(forward.positions[1].x > 0.1)
        #expect(backward.positions[1].x < -0.1)
    }

    @Test("turning the fold limit off trades accuracy for range, and says so")
    func foldLimitIsOptional() {
        let target = SIMD3<Float>(0, -2, 0)     // outside the 1.46 geometric floor
        let clamped = FABRIK.solve(chain: Self.arm, target: target, iterations: 32)
        let open = FABRIK.solve(chain: Self.arm, target: target, iterations: 32, foldLimit: 0)
        #expect(clamped.folded)
        #expect(!open.folded)
        // Unclamped it gets much closer — that is the point of the option —
        // but it is deep in the slow neighbourhood, so it does not get there.
        #expect(open.error < clamped.error)
        #expect(!open.reached)
    }

    @Test("the geometric minimum still holds when the fold limit is off")
    func geometricMinimumIsAFloor() {
        let uneven: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, -10, 0), SIMD3(0.3, -11.99, 0)]
        let s = FABRIK.solve(chain: uneven, target: .zero, iterations: 32, foldLimit: 0)
        #expect(s.folded)                       // the root is inside the ~8-unit hole
        #expect(simd_length(s.positions.last!) > 7.5)
    }
}
