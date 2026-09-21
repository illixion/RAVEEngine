import Foundation
import simd

/// A tail, as found in a rig: the chain of joints from where it leaves the
/// body to its tip.
public struct TailProfile: Sendable, Equatable {
    /// Joint indices from the base — the joint attached to the body — to the
    /// tip. Every entry is the direct parent of the next.
    public var chain: [Int]
    /// Base to tip, summed along the chain.
    public var length: Float

    public var base: Int { chain[0] }
    public var tip: Int { chain[chain.count - 1] }

    public init(chain: [Int], length: Float) {
        self.chain = chain
        self.length = length
    }
}

/// Finds a tail from geometry, the way the legs are found: by where the
/// joints sit, never by what they are called.
///
/// A tail is a chain that leaves the pelvis, carries skin, is not one of the
/// limbs the humanoid inference already claimed, and runs away from the body
/// rather than out to a side. The Synth's is ten joints in a straight line
/// backward at hip height; a hanging tail runs downward instead, and both
/// read as a tail here. The pelvis plates beside it are single joints, the
/// unused plantigrade leg chain carries no skin, and the spine and legs are
/// landmarks — so each of the branches that could be mistaken for a tail is
/// ruled out by a measurement rather than by a name.
public enum TailArchitecture {

    /// Fewer joints than this is an ornament, not something worth simulating.
    public static let minimumJoints = 3

    /// The longest tail-shaped chain hanging off the pelvis, or nil.
    ///
    /// Candidates are the children of the hips landmark, of its parent — a
    /// rig may put its true pelvis one joint above what the inference read
    /// as the hips, since both sit at the same height — and of the lowest
    /// spine joint. A candidate whose subtree holds any landmark is a limb or
    /// the torso and is skipped.
    public static func find(landmarks: HumanoidLandmarks, rig: RigSkeleton) -> TailProfile? {
        let children = rig.childIndices
        let claimed = Set(landmarks.all)
        var roots: [Int] = [landmarks.hips]
        if let parent = rig.joints[landmarks.hips].parent { roots.append(parent) }
        if let spine = landmarks.spine.first { roots.append(spine) }

        var best: TailProfile?
        var seen = Set<Int>()
        for root in roots {
            for candidate in children[root] where !seen.contains(candidate) {
                seen.insert(candidate)
                guard let profile = profile(from: candidate, in: rig, hips: landmarks.hips,
                                            claimed: claimed) else { continue }
                if best == nil || profile.length > best!.length { best = profile }
            }
        }
        return best
    }

    /// Reads one candidate branch as a tail, or nil when it is not one.
    static func profile(from candidate: Int, in rig: RigSkeleton, hips: Int,
                        claimed: Set<Int>) -> TailProfile? {
        let subtree = rig.subtree(from: candidate)
        guard subtree.allSatisfy({ !claimed.contains($0) }) else { return nil }
        // Something has to be attached to it.
        guard rig.subtreeWeight(from: candidate) > 0 else { return nil }

        let chain = longestChain(from: candidate, in: rig)
        guard chain.count >= minimumJoints else { return nil }

        var length: Float = 0
        for (a, b) in zip(chain, chain.dropFirst()) {
            length += simd_length(rig.joints[b].restHead - rig.joints[a].restHead)
        }
        guard length > 1e-3 else { return nil }

        // Away from the body: backward (+Z in this space) or down, and not
        // out to one side. A lateral branch at the hips is a leg or a hip
        // ornament, whatever it weighs.
        let offset = rig.joints[chain[chain.count - 1]].restHead - rig.joints[hips].restHead
        let reach = simd_length(offset)
        guard reach > 1e-3 else { return nil }
        let lateral = abs(offset.x) / reach
        let upward = offset.y / reach
        guard lateral < 0.5, upward < 0.5 else { return nil }

        return TailProfile(chain: chain, length: length)
    }

    /// The joints from `root` down its longest run of descendants, by
    /// summed bone length.
    static func longestChain(from root: Int, in rig: RigSkeleton) -> [Int] {
        let children = rig.childIndices
        func longest(_ i: Int) -> (length: Float, chain: [Int]) {
            let own = rig.joints[i].restHead
            var best: (length: Float, chain: [Int]) = (0, [i])
            for child in children[i] {
                let below = longest(child)
                let length = simd_length(rig.joints[child].restHead - own) + below.length
                if length > best.length { best = (length, [i] + below.chain) }
            }
            return best
        }
        return longest(root).chain
    }
}
