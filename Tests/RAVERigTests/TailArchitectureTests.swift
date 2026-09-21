import Testing
import simd
@testable import RAVERig

/// A tail has to be found from where its joints sit, because user content
/// calls them anything. These build the pelvis of a creature by hand — legs,
/// spine, a tail, and the things that look like tails but are not — so the
/// choice is pinned to geometry.
@Suite struct TailArchitectureTests {

    /// A pelvis at (0, 1, 0) with two legs, a spine, and whatever `extras`
    /// adds under the pelvis. Returns the rig and landmarks the inference
    /// would produce for it.
    private func creature(extras: (inout [RigSkeleton.Joint]) -> Void)
        -> (RigSkeleton, HumanoidLandmarks) {
        var joints: [RigSkeleton.Joint] = [
            .init(name: "pelvis", parent: nil, restHead: [0, 1, 0], weightedVertices: 100),
            .init(name: "spine", parent: 0, restHead: [0, 1.2, 0], weightedVertices: 100),
            .init(name: "chest", parent: 1, restHead: [0, 1.4, 0], weightedVertices: 100),
            .init(name: "head", parent: 2, restHead: [0, 1.7, 0], weightedVertices: 100),
            .init(name: "thighL", parent: 0, restHead: [0.1, 0.95, 0], weightedVertices: 100),
            .init(name: "shinL", parent: 4, restHead: [0.1, 0.5, 0], weightedVertices: 100),
            .init(name: "footL", parent: 5, restHead: [0.1, 0.0, 0], weightedVertices: 100),
            .init(name: "thighR", parent: 0, restHead: [-0.1, 0.95, 0], weightedVertices: 100),
            .init(name: "shinR", parent: 7, restHead: [-0.1, 0.5, 0], weightedVertices: 100),
            .init(name: "footR", parent: 8, restHead: [-0.1, 0.0, 0], weightedVertices: 100),
        ]
        extras(&joints)
        let rig = RigSkeleton(joints: joints, meshBoundsMin: [-0.3, 0, -0.3], meshBoundsMax: [0.3, 1.8, 0.3])
        let landmarks = HumanoidLandmarks(hips: 0, spine: [1], chest: 2, neck: nil, head: 3,
                                          leftArm: [], rightArm: [],
                                          leftLeg: [4, 5, 6], rightLeg: [7, 8, 9])
        return (rig, landmarks)
    }

    /// Appends a straight chain of `count` joints from `parent`, each `step`
    /// further along.
    private func chain(_ joints: inout [RigSkeleton.Joint], name: String, parent: Int,
                       from start: SIMD3<Float>, step: SIMD3<Float>, count: Int, weight: Int) {
        var previous = parent
        for i in 0..<count {
            joints.append(.init(name: "\(name)\(i)", parent: previous,
                                restHead: start + step * Float(i), weightedVertices: weight))
            previous = joints.count - 1
        }
    }

    @Test func aBackwardChainOffThePelvisIsATail() throws {
        let (rig, landmarks) = creature { joints in
            chain(&joints, name: "tail", parent: 0, from: [0, 1, 0.05], step: [0, 0, 0.12], count: 10, weight: 50)
        }
        let tail = try #require(TailArchitecture.find(landmarks: landmarks, rig: rig))
        #expect(tail.chain.count == 10)
        #expect(rig.joints[tail.base].name == "tail0")
        #expect(rig.joints[tail.tip].name == "tail9")
        #expect(abs(tail.length - 1.08) < 1e-4)
    }

    @Test func aHangingTailIsATailToo() throws {
        let (rig, landmarks) = creature { joints in
            chain(&joints, name: "tail", parent: 0, from: [0, 0.95, 0.1], step: [0, -0.1, 0.03], count: 6, weight: 50)
        }
        let tail = try #require(TailArchitecture.find(landmarks: landmarks, rig: rig))
        #expect(tail.chain.count == 6)
    }

    @Test func legsAreNotTails() {
        let (rig, landmarks) = creature { _ in }
        #expect(TailArchitecture.find(landmarks: landmarks, rig: rig) == nil)
    }

    @Test func aWeightlessChainIsNotATail() {
        // Synth's unused plantigrade legs: full length, no skin.
        let (rig, landmarks) = creature { joints in
            chain(&joints, name: "plantie", parent: 0, from: [0.15, 0.95, 0], step: [0, -0.3, 0], count: 4, weight: 0)
        }
        #expect(TailArchitecture.find(landmarks: landmarks, rig: rig) == nil)
    }

    @Test func singleJointsAndSidewaysBranchesAreNotTails() {
        let (rig, landmarks) = creature { joints in
            // Pelvis plates: one joint each, weighted.
            joints.append(.init(name: "plateL", parent: 0, restHead: [0.15, 1, 0], weightedVertices: 80))
            joints.append(.init(name: "plateR", parent: 0, restHead: [-0.15, 1, 0], weightedVertices: 80))
            // A hip ornament out to the side, long enough to count.
            chain(&joints, name: "hipChain", parent: 0, from: [0.2, 1, 0], step: [0.1, 0, 0], count: 4, weight: 40)
        }
        #expect(TailArchitecture.find(landmarks: landmarks, rig: rig) == nil)
    }

    @Test func theLongestTailWinsAndATailOffThePelvisParentIsFound() throws {
        // The inference read `spine` as the hips; the real tail hangs off
        // the joint above it.
        let (rig, landmarks) = creature { joints in
            chain(&joints, name: "stub", parent: 1, from: [0, 1.2, 0.05], step: [0, 0, 0.05], count: 3, weight: 10)
            chain(&joints, name: "tail", parent: 0, from: [0, 1, 0.05], step: [0, 0, 0.1], count: 8, weight: 50)
        }
        var moved = landmarks
        moved.hips = 1
        moved.spine = []
        let tail = try #require(TailArchitecture.find(landmarks: moved, rig: rig))
        #expect(rig.joints[tail.base].name == "tail0")
        #expect(tail.chain.count == 8)
    }
}
