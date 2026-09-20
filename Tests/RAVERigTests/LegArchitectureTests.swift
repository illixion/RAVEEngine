import Testing
import simd
@testable import RAVERig

/// Leg architecture has to be read off the rest pose, because user content
/// names joints anything at all. These build the two shapes by hand so the
/// classification is pinned to geometry rather than to the two rigs that
/// happen to be in the repo.
@Suite struct LegArchitectureTests {

    /// thigh, shin, ankle, toe at the given heights, one unit apart in x.
    private func leg(_ heights: [Float]) -> (RigSkeleton, [Int]) {
        let joints = heights.enumerated().map { index, y in
            RigSkeleton.Joint(name: "j\(index)", parent: index == 0 ? nil : index - 1,
                              restHead: SIMD3<Float>(0, y, 0), weightedVertices: 1)
        }
        return (RigSkeleton(joints: joints), Array(heights.indices))
    }

    @Test func aHumanLegIsPlantigrade() throws {
        // Hip 1.0, knee 0.5, ankle 0.1, toe 0.0 — the ankle is on the floor.
        let (rig, chain) = leg([1.0, 0.5, 0.1, 0.0])
        let profile = try #require(LegArchitecture.profile(ofLeg: chain, in: rig))
        #expect(profile.architecture == .plantigrade)
        #expect(profile.groundContact == 3)
        #expect(profile.ankle == 2)
        #expect(abs(profile.legLength - 1.0) < 1e-5)
    }

    @Test func aRaisedAnkleIsDigitigrade() throws {
        // Hip 1.0, knee 0.55, hock 0.35, toe 0.0 — the hock is carried high.
        let (rig, chain) = leg([1.0, 0.55, 0.35, 0.0])
        let profile = try #require(LegArchitecture.profile(ofLeg: chain, in: rig))
        #expect(profile.architecture == .digitigrade)
        // The joint that meets the floor is the toe, not the one a human rig
        // would call the foot — this is the whole point of the measurement.
        #expect(profile.groundContact == 3)
        #expect(profile.ankle == 2)
        #expect(profile.ankleLift > LegArchitecture.digitigradeThreshold)
    }

    /// The lowest joint wins even when it is not last in the chain, so a rig
    /// with a trailing heel or an unmeasured marker bone still plants right.
    @Test func groundContactIsTheLowestJointNotTheLastOne() throws {
        let (rig, chain) = leg([1.0, 0.5, 0.0, 0.3])
        let profile = try #require(LegArchitecture.profile(ofLeg: chain, in: rig))
        #expect(profile.groundContact == 2)
        #expect(profile.ankle == 1)
    }

    @Test func tooShortAChainIsNotALeg() {
        let (rig, chain) = leg([1.0])
        #expect(LegArchitecture.profile(ofLeg: chain, in: rig) == nil)
    }
}
