import Testing
@testable import RAVERig

/// A biped whose hands are built to order, in the shape the two real cases
/// take: a Mixamo-style five-digit hand (four bones and a weightless tip
/// marker per digit) and a three-digit avatar hand (thumb, index, middle,
/// three joints each).
private func rig(thumb: Bool = true, fingers: Int, joints: Int, marker: Bool) -> RigSkeleton {
    var out: [RigSkeleton.Joint] = []
    @discardableResult
    func add(_ name: String, _ parent: String?, _ p: SIMD3<Float>, weight: Int = 100) -> String {
        out.append(.init(name: name, parent: parent.flatMap { n in out.firstIndex { $0.name == n } },
                         restHead: p, restTail: nil, weightedVertices: weight))
        return name
    }
    add("pelvis", nil, [0, 0.95, 0])
    add("chest", "pelvis", [0, 1.30, 0])
    add("neck", "chest", [0, 1.50, 0])
    add("head", "neck", [0, 1.62, 0], weight: 900)
    for (side, sign) in [("L", Float(1)), ("R", Float(-1))] {
        add("upperarm\(side)", "chest", [sign * 0.17, 1.44, 0])
        add("forearm\(side)", "upperarm\(side)", [sign * 0.42, 1.44, 0])
        let hand = add("hand\(side)", "forearm\(side)", [sign * 0.64, 1.44, 0])
        // Digits point along +x (mirrored on the right); the thumb angles
        // forward, out of the fingers' plane of travel.
        func digit(_ name: String, root: SIMD3<Float>, step: SIMD3<Float>) {
            var parent = hand
            for n in 1...joints {
                parent = add("\(name)\(n)\(side)", parent, root + step * Float(n - 1))
            }
            if marker { add("\(name)\(joints + 1)\(side)", parent, root + step * Float(joints), weight: 0) }
        }
        if thumb {
            digit("thumb", root: [sign * 0.67, 1.43, 0.03], step: [sign * 0.015, -0.005, 0.02])
        }
        for (n, name) in ["index", "middle", "ring", "pinky"].prefix(fingers).enumerated() {
            digit(name, root: [sign * 0.72, 1.44, 0.02 - Float(n) * 0.02], step: [sign * 0.03, 0, 0])
        }
        add("thigh\(side)", "pelvis", [sign * 0.16, 0.86, 0])
        add("shin\(side)", "thigh\(side)", [sign * 0.16, 0.48, 0])
        add("foot\(side)", "shin\(side)", [sign * 0.16, 0.10, 0])
    }
    return RigSkeleton(joints: out, meshBoundsMin: [-0.8, 0, -0.2], meshBoundsMax: [0.8, 1.8, 0.2])
}

private func names(_ chain: [Int]?, _ rig: RigSkeleton) -> [String] {
    (chain ?? []).map { rig.joints[$0].name }
}

@Test func findsTheThumbAndOrdersFingersFromIt() throws {
    let source = rig(fingers: 4, joints: 4, marker: true)
    let hand = try #require(source.index(ofJointNamed: "handL"))
    let digits = HandDigitMatching.digits(of: source, hand: hand)
    #expect(names(digits.thumb, source) == ["thumb1L", "thumb2L", "thumb3L", "thumb4L", "thumb5L"])
    #expect(digits.fingers.map { source.joints[$0[0]].name } == ["index1L", "middle1L", "ring1L", "pinky1L"])
}

@Test func parallelDigitsHaveNoThumb() throws {
    let mitten = rig(thumb: false, fingers: 3, joints: 3, marker: false)
    let hand = try #require(mitten.index(ofJointNamed: "handR"))
    #expect(HandDigitMatching.digits(of: mitten, hand: hand).thumb == nil)
}

@Test func cutsTheSourceHandToTheTargetsDigits() throws {
    let source = rig(fingers: 4, joints: 4, marker: true)
    let target = rig(fingers: 2, joints: 3, marker: false)
    let candidates = HandDigitMatching.candidates(
        source: source, sourceAnalysis: try HumanoidInference.analyse(source),
        target: target, targetAnalysis: try HumanoidInference.analyse(target))

    // Index-for-index first, then the nearest substitutes.
    #expect(candidates.map(\.fingerPicks).prefix(3) == [[0, 1], [0, 2], [0, 3]])

    let best = try #require(candidates.first)
    func kept(_ name: String) throws -> Bool { best.keep.contains(try #require(source.index(ofJointNamed: name))) }
    // Each digit cut to three joints from the root: the fourth bone and the
    // weightless tip marker go, which is what stops the matcher aligning the
    // chain from its tip and skipping the middle knuckle.
    for side in ["L", "R"] {
        for digit in ["thumb", "index", "middle"] {
            #expect(try kept("\(digit)3\(side)"))
            #expect(try !kept("\(digit)4\(side)"))
            #expect(try !kept("\(digit)5\(side)"))
        }
        #expect(try !kept("ring1\(side)"))
        #expect(try !kept("pinky1\(side)"))
        #expect(try kept("hand\(side)"))
    }
    // The pairing the caller's probe has to confirm: three digits a hand.
    let pairs = best.expected.map { "\(source.joints[$0.source].name)>\(target.joints[$0.target].name)" }
    #expect(Set(pairs) == ["thumb1L>thumb1L", "index1L>index1L", "middle1L>middle1L",
                           "thumb1R>thumb1R", "index1R>index1R", "middle1R>middle1R"])
}

@Test func matchingHandsNeedNoCandidates() throws {
    let a = rig(fingers: 4, joints: 3, marker: false)
    let candidates = HandDigitMatching.candidates(
        source: a, sourceAnalysis: try HumanoidInference.analyse(a),
        target: a, targetAnalysis: try HumanoidInference.analyse(a))
    #expect(candidates.isEmpty)
}
