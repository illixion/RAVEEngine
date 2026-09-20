import Foundation

/// The biped chains found in an arbitrary rig, as indices into `RigSkeleton`.
///
/// This is not a bone *map* — `automatchBiped` produces that, and it is opaque.
/// It is the answer to the only question the retargeter actually needs help
/// with: which branches are the humanoid, and which are ornament.
public struct HumanoidLandmarks: Sendable, Codable, Equatable {
    public var hips: Int
    /// Between hips and chest, ascending. May be empty on a 2-bone spine.
    public var spine: [Int]
    public var chest: Int
    public var neck: Int?
    public var head: Int
    /// Shoulder (or upper arm) through hand, in order.
    public var leftArm: [Int]
    public var rightArm: [Int]
    /// Thigh through foot, in order.
    public var leftLeg: [Int]
    public var rightLeg: [Int]

    public var leftHand: Int? { leftArm.last }
    public var rightHand: Int? { rightArm.last }
    public var leftFoot: Int? { leftLeg.last }
    public var rightFoot: Int? { rightLeg.last }

    public var all: [Int] {
        [hips, chest, head] + spine + (neck.map { [$0] } ?? [])
            + leftArm + rightArm + leftLeg + rightLeg
    }
}

/// Why a branch was dropped — surfaced in the importer so a wrong call is
/// visible and correctable rather than silent.
public struct PrunedBranch: Sendable, Codable, Equatable {
    public var rootIndex: Int
    public var name: String
    public var jointCount: Int
    public var weightedVertices: Int
    public var reason: String
}

public struct HumanoidAnalysis: Sendable, Codable, Equatable {
    public var landmarks: HumanoidLandmarks
    /// Joints to keep in the skeleton handed to `automatchBiped`.
    public var keep: Set<Int>
    /// Maximal subtrees to drop, each with the reason it lost.
    public var pruned: [PrunedBranch]
    /// Human-readable trace of how each landmark was chosen.
    public var notes: [String]

    /// Leaf names of every joint to drop — the form a manifest stores and the
    /// visionOS side matches on.
    public func prunedNames(in rig: RigSkeleton) -> [String] {
        pruned.map { rig.joints[$0.rootIndex].name }.sorted()
    }
}

public enum HumanoidInferenceError: Error, CustomStringConvertible {
    case noRoot
    case noLegPair
    case noArmPair
    case noHead

    public var description: String {
        switch self {
        case .noRoot: "skeleton has no root joint"
        case .noLegPair:
            """
            could not find a mirrored pair of weighted downward limbs (legs). \
            Check the rig is Y-up: if its vertical extent runs along Z the \
            model is still in Blender space, which happens when a skeleton is \
            read in its own space while its up-axis conversion sits on the \
            entity hierarchy above it.
            """
        case .noArmPair: "could not find a mirrored pair of weighted lateral limbs (arms)"
        case .noHead: "could not find an upward chain above the chest (head)"
        }
    }
}

/// Finds the humanoid core of a rig from geometry and skin weights alone.
///
/// Name matching is deliberately absent from the decision path. Synth alone
/// spells the same joint three ways (`Def_Shoulder_L`, `Def_shoulder_r`,
/// `Def_hand_l`), and a rig in another language shares no tokens at all. Names
/// are used only to *explain* a choice after it is made.
///
/// Two measurements do the work:
///
///   - **Skin weight.** Synth carries a complete second leg chain
///     (`Plantie_Thigh/Shin/Foot`) that no vertex references; every bone reads
///     `weightedVertices == 0` while the real digitigrade legs read 300–600.
///   - **Reach.** A limb is a branch that travels. Ribs, jiggle clusters and
///     tongues stay near their parent; arms and legs do not.
public enum HumanoidInference {

    /// A branch must move at least this share of the heaviest sibling's
    /// vertices to count as a limb candidate.
    static let weightShareFloor: Float = 0.05
    /// A limb must travel at least this share of body height.
    static let reachShareFloor: Float = 0.08

    public static func analyse(_ rig: RigSkeleton) throws -> HumanoidAnalysis {
        guard let root = rig.rootIndex else { throw HumanoidInferenceError.noRoot }
        var notes: [String] = []

        let height = rig.meshHeight > 0.01
            ? rig.meshHeight
            : (rig.joints.map(\.restHead.y).max() ?? 1) - (rig.joints.map(\.restHead.y).min() ?? 0)
        notes.append("body height \(fmt(height)) m")

        // --- Limb pairs: mirrored branches that are long and carry weight ---
        // Deliberately NOT "branches that travel down" / "travel sideways".
        // A source rig's rest pose is often a posed idle rather than a T-pose
        // — Mixamo's is — and arms hanging at the sides displace almost
        // nothing laterally. Chain LENGTH does not care how a limb is posed.
        let pairs = mirroredPairs(in: rig, below: root, height: height)
        guard let legPair = pairs.min(by: { tipHeight(rig, $0) < tipHeight(rig, $1) }) else {
            throw HumanoidInferenceError.noLegPair
        }
        let legJoints = Set(rig.subtree(from: legPair.left) + rig.subtree(from: legPair.right))
        guard let armPair = pairs
            .filter({ !legJoints.contains($0.left) && !legJoints.contains($0.right) })
            .max(by: { rootHeight(rig, $0) < rootHeight(rig, $1) })
        else { throw HumanoidInferenceError.noArmPair }

        notes.append("legs = \(rig.joints[legPair.left].name) / \(rig.joints[legPair.right].name) "
            + "(chain \(fmt(rig.chainLength(from: legPair.left))) m, tips at y=\(fmt(tipHeight(rig, legPair))))")
        notes.append("arms = \(rig.joints[armPair.left].name) / \(rig.joints[armPair.right].name) "
            + "(chain \(fmt(rig.chainLength(from: armPair.left))) m, roots at y=\(fmt(rootHeight(rig, armPair))))")
        let others = pairs.filter { $0.left != legPair.left && $0.left != armPair.left }
        if !others.isEmpty {
            notes.append("  other mirrored pairs rejected: "
                + others.map { rig.joints[$0.left].name }.joined(separator: " "))
        }

        // --- Hips: where the two legs meet ----------------------------------
        let hips = lowestCommonAncestor(rig, legPair.left, legPair.right)
        notes.append("hips = \(rig.joints[hips].name) (common ancestor of the legs)")

        // --- Chest: where the two arms meet ---------------------------------
        let chest = lowestCommonAncestor(rig, armPair.left, armPair.right)
        notes.append("chest = \(rig.joints[chest].name) (common ancestor of the arms)")

        // --- Head: the highest-reaching chain off the chest, minus the arms --
        let armJoints = Set(rig.subtree(from: armPair.left) + rig.subtree(from: armPair.right))
        let headChain = try upwardChain(rig, from: chest, excluding: armJoints)
        let head = headChain.last!
        notes.append("head = \(rig.joints[head].name) via \(headChain.map { rig.joints[$0].name }.joined(separator: " > "))")

        // --- Assemble the chains --------------------------------------------
        let spine = path(rig, from: hips, to: chest).dropFirst().dropLast().map { $0 }
        let reach = { (i: Int) in rig.subtreeReach(from: i) }
        let leftArm = chain(rig, from: armPair.left, tipward: reach)
        let rightArm = chain(rig, from: armPair.right, tipward: reach)
        let leftLeg = chain(rig, from: legPair.left, tipward: reach)
        let rightLeg = chain(rig, from: legPair.right, tipward: reach)

        let landmarks = HumanoidLandmarks(
            hips: hips, spine: spine, chest: chest,
            neck: headChain.count > 1 ? headChain.first : nil,
            head: head,
            leftArm: leftArm, rightArm: rightArm,
            leftLeg: leftLeg, rightLeg: rightLeg)

        // --- Keep set -------------------------------------------------------
        // Chains themselves, plus everything below the hands and feet: fingers
        // and toes are wanted and cost the matcher nothing, because they hang
        // off a joint the matcher has already placed. Head *descendants* (jaw,
        // tongue, ears, hair) are not kept — they are pure noise to a biped
        // matcher, and the manifest names the ones that matter (gaze, visemes)
        // separately against the unpruned skeleton.
        var keep = Set(landmarks.all)
        keep.formUnion(rig.ancestors(of: hips))
        for tip in [landmarks.leftHand, landmarks.rightHand, landmarks.leftFoot, landmarks.rightFoot] {
            if let tip { keep.formUnion(rig.subtree(from: tip)) }
        }

        // Tempting and wrong: also dropping every zero-weight subtree here.
        // A weightless joint cannot move the mesh, so it looks like free
        // accuracy — but measured on Synth it took validation from 13/15 down
        // to 11/15. It strips Mixamo's finger tips as well as its end markers,
        // leaving the source hand three joints shorter than the target's, and
        // the feet then align one joint out in the other direction. The
        // weightless *branch roots* that mislead the matcher are already gone
        // via the prune list; the tips are load-bearing for alignment.

        // --- Prune list: maximal subtrees disjoint from the keep set ---------
        var pruned: [PrunedBranch] = []
        let children = rig.childIndices
        func walk(_ i: Int) {
            if keep.contains(i) {
                for c in children[i] { walk(c) }
                return
            }
            let sub = rig.subtree(from: i)
            pruned.append(PrunedBranch(
                rootIndex: i,
                name: rig.joints[i].name,
                jointCount: sub.count,
                weightedVertices: rig.subtreeWeight(from: i),
                reason: reason(rig, i, height: height)))
        }
        walk(root)

        return HumanoidAnalysis(landmarks: landmarks, keep: keep, pruned: pruned, notes: notes)
    }

    // MARK: - Limb pairing

    struct LimbPair: Sendable, Equatable { var left: Int; var right: Int }

    private static func tipHeight(_ rig: RigSkeleton, _ pair: LimbPair) -> Float {
        func lowest(_ i: Int) -> Float {
            rig.subtree(from: i).map { rig.joints[$0].restHead.y }.min() ?? 0
        }
        return (lowest(pair.left) + lowest(pair.right)) / 2
    }

    private static func rootHeight(_ rig: RigSkeleton, _ pair: LimbPair) -> Float {
        (rig.joints[pair.left].restHead.y + rig.joints[pair.right].restHead.y) / 2
    }

    /// Every mirrored pair of limb-like branches in the rig.
    ///
    /// A limb is a branch that is long, carries skin weight, and stays on one
    /// side of the midline. Which pair is the legs and which the arms is then
    /// decided by where they sit, not by how they happen to be posed.
    private static func mirroredPairs(
        in rig: RigSkeleton, below ancestor: Int, height: Float
    ) -> [LimbPair] {
        let heaviest = Float(rig.joints.map(\.weightedVertices).max() ?? 1)
        // `side` says which side of the body the branch is on, taken from the
        // subtree's extreme so a clavicle sitting at x = 0 still resolves.
        // `offset` is how far the branch ROOT sits from the midline, which is
        // what the two sides are compared on: a posed rig swings its limb TIPS
        // (Mixamo's idle puts one foot at x = +35 and the other at x = -8) but
        // barely moves the hip and shoulder joints they hang from.
        var candidates: [(index: Int, side: Float, offset: Float, length: Float, weight: Int)] = []

        for i in rig.subtree(from: ancestor) where i != ancestor {
            let weight = rig.subtreeWeight(from: i)
            let length = rig.chainLength(from: i)
            guard length >= height * reachShareFloor else { continue }
            // A branch nothing is skinned to is not a limb, however long it is.
            guard Float(weight) >= heaviest * weightShareFloor else { continue }
            guard let side = lateralSide(rig, i), abs(side) > 1e-4 else { continue }
            // A limb lives on one side of the body. Without this the spine
            // itself is the longest "one-sided" branch there is, because both
            // arms hang below it.
            guard isLateralised(rig, i, tolerance: height * 0.03) else { continue }
            candidates.append((i, side, abs(rig.joints[i].restHead.x), length, weight))
        }

        // Every joint along a limb qualifies on its own; the one to name is
        // the shallowest, so drop any candidate that has a candidate above it.
        let candidateSet = Set(candidates.map(\.index))
        let roots = candidates.filter { c in
            !rig.ancestors(of: c.index).dropFirst().contains { candidateSet.contains($0) }
        }

        var pairs: [(pair: LimbPair, score: Float)] = []
        for l in roots where l.side > 0 {
            for r in roots where r.side < 0 {
                let widest = max(l.offset, r.offset)
                // Two roots both on the midline (paired clavicles, say) are
                // perfectly symmetric, not undefined.
                let sideMatch = widest < height * 0.005
                    ? 1
                    : 1 - abs(l.offset - r.offset) / widest
                let lengthMatch = 1 - abs(l.length - r.length) / max(l.length, r.length, 1e-4)
                guard sideMatch > 0.5, lengthMatch > 0.7 else { continue }
                pairs.append((LimbPair(left: l.index, right: r.index),
                              min(l.length, r.length) * Float(min(l.weight, r.weight)) * sideMatch * lengthMatch))
            }
        }

        // One branch cannot belong to two pairs; best score wins it.
        var taken = Set<Int>()
        var result: [LimbPair] = []
        for entry in pairs.sorted(by: { $0.score > $1.score }) {
            guard !taken.contains(entry.pair.left), !taken.contains(entry.pair.right) else { continue }
            taken.insert(entry.pair.left); taken.insert(entry.pair.right)
            result.append(entry.pair)
        }
        return result
    }

    /// Whether a branch stays on one side of the midline. A shoulder does; the
    /// chest it hangs off does not, because its subtree holds the other arm.
    private static func isLateralised(_ rig: RigSkeleton, _ index: Int, tolerance: Float) -> Bool {
        var minX = Float.infinity, maxX = -Float.infinity
        for j in rig.subtree(from: index) {
            for p in [rig.joints[j].restHead, rig.joints[j].restTail].compactMap({ $0 }) {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
            }
        }
        return !(maxX > tolerance && minX < -tolerance)
    }

    /// Which side of the midline a branch ends up on, judged by the point in
    /// its subtree furthest from the midline — a shoulder bone can sit at
    /// x ~ 0 while the arm it roots plainly does not.
    private static func lateralSide(_ rig: RigSkeleton, _ index: Int) -> Float? {
        var extreme: Float = 0
        for j in rig.subtree(from: index) {
            for p in [rig.joints[j].restHead, rig.joints[j].restTail].compactMap({ $0 }) {
                if abs(p.x) > abs(extreme) { extreme = p.x }
            }
        }
        return extreme
    }

    // MARK: - Chain walking

    /// Walks from a branch root outward, always taking the child that travels
    /// furthest, and stops where the branch fans out into digits.
    private static func chain(_ rig: RigSkeleton, from root: Int, tipward: (Int) -> Float) -> [Int] {
        let children = rig.childIndices
        var out = [root]
        var cursor = root
        while true {
            let kids = children[cursor]
            if kids.isEmpty { break }
            // A joint that fans into three or more children is a hand or a
            // foot; the limb ends there and the digits hang off it. Two
            // children count as a fan only if both travel comparably — Synth's
            // pinky toe has three bones to the other toes' two, so a
            // similar-reach test alone walks straight down the longest digit.
            if kids.count >= 3 { break }
            if kids.count == 2 {
                let reaches = kids.map(tipward).sorted(by: >)
                if reaches[1] > reaches[0] * 0.6 { break }
            }
            guard let next = kids.max(by: { tipward($0) < tipward($1) }) else { break }
            if tipward(next) <= 0 { break }
            out.append(next)
            cursor = next
        }
        return out
    }

    /// The chain above the chest that climbs highest, ignoring the arms.
    private static func upwardChain(_ rig: RigSkeleton, from chest: Int, excluding: Set<Int>) throws -> [Int] {
        let children = rig.childIndices
        func topY(_ i: Int) -> Float {
            rig.subtree(from: i).map { rig.joints[$0].restHead.y }.max() ?? -.infinity
        }
        var out: [Int] = []
        var cursor = chest
        while true {
            let kids = children[cursor].filter { !excluding.contains($0) }
            guard let next = kids.max(by: { topY($0) < topY($1) }),
                  topY(next) > rig.joints[cursor].restHead.y else { break }
            out.append(next)
            cursor = next
        }
        guard !out.isEmpty else { throw HumanoidInferenceError.noHead }
        // Stop where the chain stops being structure and starts being detail.
        // A jaw bone can sit HIGHER than the skull joint it hangs off, so the
        // topmost joint is not the head; the heaviest one is. Synth reads
        // neck 1500 -> head 1981 -> jaw 635, and the drop at the jaw is the
        // boundary.
        var running = 0
        var end = 0
        for (n, i) in out.enumerated() {
            let weight = rig.joints[i].weightedVertices
            if n > 0, Float(weight) < Float(running) * 0.4 { break }
            running = max(running, weight)
            end = n
        }
        return Array(out.prefix(end + 1))
    }

    // MARK: - Tree helpers

    private static func path(_ rig: RigSkeleton, from ancestor: Int, to descendant: Int) -> [Int] {
        var out: [Int] = []
        var cursor: Int? = descendant
        while let i = cursor {
            out.append(i)
            if i == ancestor { break }
            cursor = rig.joints[i].parent
        }
        return out.reversed()
    }

    private static func lowestCommonAncestor(_ rig: RigSkeleton, _ a: Int, _ b: Int) -> Int {
        let ancestorsA = rig.ancestors(of: a)
        let setB = Set(rig.ancestors(of: b))
        return ancestorsA.first { setB.contains($0) } ?? (rig.rootIndex ?? a)
    }

    private static func reason(_ rig: RigSkeleton, _ i: Int, height: Float) -> String {
        let weight = rig.subtreeWeight(from: i)
        let reach = rig.subtreeReach(from: i)
        let count = rig.subtree(from: i).count
        if weight == 0 { return "no mesh vertex is weighted to it (\(count) joints)" }
        if reach < height * reachShareFloor {
            return "stays within \(fmt(reach)) m of its parent — not a limb (\(count) joints, \(weight) verts)"
        }
        return "not on a humanoid chain (\(count) joints, \(weight) verts, reach \(fmt(reach)) m)"
    }
}

private func fmt(_ v: Float) -> String { String(format: "%.3f", v) }

// MARK: - Directional reach

extension RigSkeleton {
    /// Length of the longest joint-to-joint path through a branch, summed
    /// along the bones rather than measured end to end. An arm is this long
    /// whether it is outstretched or hanging at the side, which a straight-line
    /// reach is not.
    func chainLength(from index: Int) -> Float {
        let children = childIndices
        func longest(_ i: Int) -> Float {
            let own = joints[i].restHead
            return children[i].map { simd_length_f(joints[$0].restHead - own) + longest($0) }.max() ?? 0
        }
        return longest(index)
    }

    /// How far below its own origin a branch descends.
    func downwardReach(from index: Int) -> Float {
        let origin = joints[index].restHead.y
        let lowest = subtree(from: index)
            .flatMap { [joints[$0].restHead, joints[$0].restTail].compactMap { $0 } }
            .map(\.y).min() ?? origin
        return max(0, origin - lowest)
    }

    /// How far from the midline a branch travels, measured from its own origin
    /// so a shoulder already offset from centre is not credited twice.
    func lateralReach(from index: Int) -> Float {
        let origin = abs(joints[index].restHead.x)
        let furthest = subtree(from: index)
            .flatMap { [joints[$0].restHead, joints[$0].restTail].compactMap { $0 } }
            .map { abs($0.x) }.max() ?? origin
        return max(0, furthest - origin)
    }
}
