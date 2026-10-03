import Foundation

/// One hand's digits, found from geometry: which chain is the thumb, and the
/// fingers in order across the hand from the thumb side.
public struct HandDigits: Sendable, Equatable {
    /// The thumb's chain, root first. `nil` when the hand has no digit that
    /// stands apart from the others, a mitten or a single finger.
    public var thumb: [Int]?
    /// The remaining digits' chains, root first, ordered from the one nearest
    /// the thumb outward (index, middle, ring, pinky on a human hand).
    public var fingers: [[Int]]
}

/// Which source digits to hand the biped matcher, so each target digit is
/// driven by its anatomical counterpart and through all of its joints.
///
/// `automatchBiped` maps hands badly when the two rigs disagree on digits,
/// and an avatar with three fingers rarely agrees with Mixamo's five. Measured
/// on Synth (index, middle, thumb, three joints each) it drove the index from
/// Mixamo's RING and the middle from its PINKY, while Mixamo's index and
/// middle drove nothing. It also aligns each chain from the tip, so a
/// five-joint source finger (four bones plus the weightless tip marker) skips
/// the target's middle knuckle: joints 1 and 4 drove it, 2 and 3 drove nothing.
///
/// The matcher cannot be told a mapping, only fed a skeleton, so the fix is
/// on the source side: prune its hand down to as many fingers as the target
/// has, each cut to the target digit's joint count. Which fingers to keep is
/// then a guess about an opaque matcher — on Synth, keeping index and middle
/// comes out SWAPPED while index and ring maps straight — so `candidates`
/// returns choices best-first and the caller keeps the first one a probe
/// confirms (`Retargeter.correspondences`).
public enum HandDigitMatching {

    /// A source keep set to try, and the pairing it is meant to produce.
    public struct Candidate: Sendable, Equatable {
        /// The source joints to keep: the analysis' keep set with its hands
        /// cut down to the chosen digits.
        public var keep: Set<Int>
        /// Source digit root → the target digit root it should drive, both
        /// hands. The probe confirms these.
        public var expected: [(source: Int, target: Int)]
        /// Which source fingers, by position from the thumb (0 = index), for
        /// the log.
        public var fingerPicks: [Int]

        public static func == (a: Candidate, b: Candidate) -> Bool {
            a.keep == b.keep && a.fingerPicks == b.fingerPicks
                && a.expected.map(\.source) == b.expected.map(\.source)
                && a.expected.map(\.target) == b.expected.map(\.target)
        }
    }

    /// The digits hanging off a hand joint.
    public static func digits(of rig: RigSkeleton, hand: Int, within keep: Set<Int>? = nil) -> HandDigits {
        let children = rig.childIndices
        let roots = children[hand].filter { i in
            (keep?.contains(i) ?? true) && rig.subtreeWeight(from: i) > 0
        }
        // Follow the furthest-travelling child to the tip. Digits are chains;
        // anything that forks further is not one, and the walk takes the
        // longer arm of the fork.
        func chain(_ root: Int) -> [Int] {
            var out = [root], cursor = root
            while let next = children[cursor]
                .filter({ keep?.contains($0) ?? true })
                .max(by: { rig.subtreeReach(from: $0) < rig.subtreeReach(from: $1) }) {
                out.append(next)
                cursor = next
            }
            return out
        }
        var chains = roots.map(chain)
        guard chains.count >= 2 else { return HandDigits(thumb: nil, fingers: chains) }

        // Fingers run parallel to one another; the thumb runs parallel to
        // none of them. So the thumb is the digit least parallel to its
        // closest sibling. Direction, not position: a thumb root can sit level
        // with the index root (Synth) or back towards the wrist (Mixamo).
        // Measured against the hand's mean direction instead, the thumb only
        // stood 0.046 apart on Synth, whose three digits skew the mean; this
        // way it is 0.08 (Synth) and 0.17 (Mixamo).
        func tip(_ c: [Int]) -> SIMD3<Float> { rig.joints[c.last!].restTail ?? rig.joints[c.last!].restHead }
        let directions = chains.map { simd_normalize_f(tip($0) - rig.joints[$0[0]].restHead) }
        let closest = directions.indices.map { i in
            directions.indices.filter { $0 != i }.map { simd_dot_f(directions[i], directions[$0]) }.max()!
        }
        let ranked = chains.indices.sorted { closest[$0] < closest[$1] }
        // Only call it a thumb when it clearly stands apart — on a hand of
        // parallel fingers the least parallel one is just a finger.
        let gap = closest[ranked[1]] - closest[ranked[0]]
        guard gap > 0.03 else {
            return HandDigits(thumb: nil, fingers: ordered(chains, from: nil, rig: rig))
        }
        let thumb = chains.remove(at: ranked[0])
        return HandDigits(thumb: thumb, fingers: ordered(chains, from: thumb, rig: rig))
    }

    /// Fingers ordered by how far their root is from the thumb's. Without a
    /// thumb, the order they were found in.
    private static func ordered(_ fingers: [[Int]], from thumb: [Int]?, rig: RigSkeleton) -> [[Int]] {
        guard let thumb else { return fingers }
        let anchor = rig.joints[thumb[0]].restHead
        return fingers.sorted {
            simd_length_f(rig.joints[$0[0]].restHead - anchor) < simd_length_f(rig.joints[$1[0]].restHead - anchor)
        }
    }

    /// Source keep sets to try, best guess first. Empty when the hands already
    /// agree, or when either rig has no hands to speak of.
    public static func candidates(source: RigSkeleton, sourceAnalysis: HumanoidAnalysis,
                                  target: RigSkeleton, targetAnalysis: HumanoidAnalysis) -> [Candidate] {
        let sides: [(Int?, Int?)] = [
            (sourceAnalysis.landmarks.leftHand, targetAnalysis.landmarks.leftHand),
            (sourceAnalysis.landmarks.rightHand, targetAnalysis.landmarks.rightHand),
        ]
        let hands = sides.compactMap { s, t -> (HandDigits, HandDigits, Int)? in
            guard let s, let t else { return nil }
            return (digits(of: source, hand: s, within: sourceAnalysis.keep),
                    digits(of: target, hand: t, within: targetAnalysis.keep), s)
        }
        guard hands.count == 2 else { return [] }

        let k = hands.map { $0.1.fingers.count }.min() ?? 0
        let m = hands.map { $0.0.fingers.count }.min() ?? 0
        guard k > 0, m >= k else { return [] }
        let agree = hands.allSatisfy { s, t, _ in
            s.fingers.map(\.count) == t.fingers.map(\.count) && s.thumb?.count == t.thumb?.count
        }
        if agree { return [] }

        // Every in-order choice of k source fingers, ranked by how far each
        // pick sits from the finger it stands in for. Index-for-index first;
        // the same choice on both hands, since the rigs are mirror images.
        let picks = combinations(of: k, from: m).sorted {
            displacement($0) < displacement($1) || (displacement($0) == displacement($1) && $0.lexicographicallyPrecedes($1))
        }

        return picks.map { pick in
            var keep = sourceAnalysis.keep
            var expected: [(source: Int, target: Int)] = []
            for (sourceHand, targetHand, sourceHandIndex) in hands {
                for root in source.childIndices[sourceHandIndex] { keep.subtract(source.subtree(from: root)) }
                // Thumb to thumb; a target without one leaves the source's out.
                if let s = sourceHand.thumb, let t = targetHand.thumb {
                    keep.formUnion(s.prefix(t.count))
                    expected.append((s[0], t[0]))
                }
                for (targetSlot, sourceSlot) in pick.enumerated() {
                    let s = sourceHand.fingers[sourceSlot], t = targetHand.fingers[targetSlot]
                    // Cut to the target's joint count: from the tip, so the
                    // weightless tip marker and the last real bone go first.
                    keep.formUnion(s.prefix(t.count))
                    expected.append((s[0], t[0]))
                }
            }
            return Candidate(keep: keep, expected: expected, fingerPicks: pick)
        }
    }

    private static func displacement(_ pick: [Int]) -> Int {
        pick.enumerated().reduce(0) { $0 + abs($1.element - $1.offset) }
    }

    private static func combinations(of k: Int, from n: Int) -> [[Int]] {
        guard k > 0 else { return [[]] }
        guard n >= k else { return [] }
        var out: [[Int]] = []
        func walk(_ start: Int, _ acc: [Int]) {
            if acc.count == k { out.append(acc); return }
            guard start < n else { return }
            for i in start..<n { walk(i + 1, acc + [i]) }
        }
        walk(0, [])
        return out
    }
}
