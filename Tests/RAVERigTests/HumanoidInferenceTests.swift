import Testing
@testable import RAVERig

/// Builds rigs by hand so each test states the pathology it is about.
///
/// The fixtures are synthetic rather than a dump of a real avatar: the
/// behaviours worth guarding are structural (an unweighted duplicate chain, a
/// branch that fans into digits, a bone that sits above the head), and a
/// synthetic rig names them instead of burying them in 85 rows of a licensed
/// third-party model.
private struct RigBuilder {
    var joints: [RigSkeleton.Joint] = []

    @discardableResult
    mutating func add(_ name: String,
                      parent: String? = nil,
                      _ x: Float, _ y: Float, _ z: Float = 0,
                      tail: SIMD3<Float>? = nil,
                      weight: Int = 100) -> String {
        let parentIndex = parent.flatMap { p in joints.firstIndex { $0.name == p } }
        joints.append(.init(name: name,
                            parent: parentIndex,
                            restHead: SIMD3(x, y, z),
                            restTail: tail ?? SIMD3(x, y + 0.05, z),
                            weightedVertices: weight))
        return name
    }

    /// A plain 1.8 m biped: pelvis, three spine joints, neck, head, two arms
    /// ending in three fingers each, two legs ending in three toes each.
    static func biped() -> RigBuilder {
        var b = RigBuilder()
        b.add("pelvis", 0, 0.95)
        b.add("spine1", parent: "pelvis", 0, 1.05)
        b.add("spine2", parent: "spine1", 0, 1.18)
        b.add("chest", parent: "spine2", 0, 1.30)
        b.add("neck", parent: "chest", 0, 1.50)
        b.add("head", parent: "neck", 0, 1.62, tail: SIMD3(0, 1.80, 0), weight: 900)
        for (side, sign) in [("L", Float(1)), ("R", Float(-1))] {
            b.add("clavicle\(side)", parent: "chest", sign * 0.04, 1.44)
            b.add("upperarm\(side)", parent: "clavicle\(side)", sign * 0.17, 1.44)
            b.add("forearm\(side)", parent: "upperarm\(side)", sign * 0.42, 1.28)
            b.add("hand\(side)", parent: "forearm\(side)", sign * 0.64, 1.13)
            for (n, finger) in ["thumb", "index", "middle"].enumerated() {
                b.add("\(finger)1\(side)", parent: "hand\(side)", sign * 0.68, 1.10 - Float(n) * 0.01, weight: 40)
                b.add("\(finger)2\(side)", parent: "\(finger)1\(side)", sign * 0.74, 1.05 - Float(n) * 0.01, weight: 30)
            }
            b.add("thigh\(side)", parent: "pelvis", sign * 0.16, 0.86)
            b.add("shin\(side)", parent: "thigh\(side)", sign * 0.16, 0.48)
            b.add("foot\(side)", parent: "shin\(side)", sign * 0.16, 0.10)
            b.add("toebase\(side)", parent: "foot\(side)", sign * 0.16, 0.03)
            for (n, toe) in ["big", "mid", "little"].enumerated() {
                b.add("toe\(toe)1\(side)", parent: "toebase\(side)", sign * (0.12 + Float(n) * 0.04), 0.03, weight: 20)
                b.add("toe\(toe)2\(side)", parent: "toe\(toe)1\(side)", sign * (0.12 + Float(n) * 0.04), 0.02, weight: 20)
            }
        }
        return b
    }

    func build() -> RigSkeleton {
        RigSkeleton(joints: joints,
                    meshBoundsMin: SIMD3(-0.8, 0, -0.2),
                    meshBoundsMax: SIMD3(0.8, 1.80, 0.2))
    }
}

@Test func findsThePlainBiped() throws {
    let rig = RigBuilder.biped().build()
    let analysis = try HumanoidInference.analyse(rig)
    let lm = analysis.landmarks
    func name(_ i: Int) -> String { rig.joints[i].name }

    #expect(name(lm.hips) == "pelvis")
    #expect(name(lm.chest) == "chest")
    #expect(name(lm.head) == "head")
    #expect(lm.neck.map(name) == "neck")
    #expect(lm.spine.map(name) == ["spine1", "spine2"])
    #expect(lm.leftArm.map(name) == ["clavicleL", "upperarmL", "forearmL", "handL"])
    #expect(lm.rightArm.map(name) == ["clavicleR", "upperarmR", "forearmR", "handR"])
    #expect(lm.leftLeg.map(name) == ["thighL", "shinL", "footL", "toebaseL"])
    #expect(analysis.pruned.isEmpty, "a clean biped has nothing to prune")
}

@Test func keepsFingersAndToes() throws {
    let rig = RigBuilder.biped().build()
    let analysis = try HumanoidInference.analyse(rig)
    // Digits hang off a joint the matcher has already placed, so they cost it
    // nothing and are worth retargeting.
    for name in ["index1L", "index2L", "thumb1R", "toebig1L", "toelittle2R"] {
        let i = try #require(rig.index(ofJointNamed: name))
        #expect(analysis.keep.contains(i), "\(name) should be kept")
    }
}

@Test func dropsAnUnweightedDuplicateLegChain() throws {
    // Synth ships a complete second, plantigrade leg chain that no vertex
    // references. It is the same length and the same shape as the real legs,
    // so only the skin weight tells them apart.
    var b = RigBuilder.biped()
    for (side, sign) in [("L", Float(1)), ("R", Float(-1))] {
        b.add("altthigh\(side)", parent: "pelvis", sign * 0.16, 0.86, weight: 0)
        b.add("altshin\(side)", parent: "altthigh\(side)", sign * 0.16, 0.42, weight: 0)
        b.add("altfoot\(side)", parent: "altshin\(side)", sign * 0.16, 0.04, weight: 0)
    }
    let rig = b.build()
    let analysis = try HumanoidInference.analyse(rig)

    #expect(rig.joints[analysis.landmarks.leftLeg[0]].name == "thighL")
    #expect(analysis.prunedNames(in: rig) == ["altthighL", "altthighR"])
    let reason = try #require(analysis.pruned.first?.reason)
    #expect(reason.contains("no mesh vertex"))
}

@Test func dropsOrnamentsThatCarryRealWeight() throws {
    // A tail and a jiggle cluster are skinned to plenty of geometry; weight
    // cannot reject them, only reach and topology can.
    var b = RigBuilder.biped()
    var previous = "pelvis"
    for n in 1...10 {
        previous = b.add("tail\(n)", parent: previous, 0, 0.95, -0.1 * Float(n), weight: 600)
    }
    b.add("ribsL", parent: "chest", 0, 1.30, weight: 690)
    b.add("ribsR", parent: "chest", 0, 1.30, weight: 690)
    for n in 1...3 { b.add("jiggle\(n)", parent: "pelvis", 0, 0.88, weight: 800) }

    let rig = b.build()
    let analysis = try HumanoidInference.analyse(rig)
    #expect(analysis.prunedNames(in: rig) == ["jiggle1", "jiggle2", "jiggle3", "ribsL", "ribsR", "tail1"])
    // The whole tail goes as one branch, not ten.
    let tail = try #require(analysis.pruned.first { $0.name == "tail1" })
    #expect(tail.jointCount == 10)
}

@Test func headIsTheHeaviestJointNotTheHighest() throws {
    // A jaw bone routinely sits ABOVE the skull joint it hangs off, so picking
    // the topmost joint on the upward chain picks the jaw.
    var b = RigBuilder.biped()
    b.add("jaw", parent: "head", 0, 1.68, weight: 120)
    b.add("tongue", parent: "jaw", 0, 1.66, weight: 30)
    let rig = b.build()
    let analysis = try HumanoidInference.analyse(rig)
    #expect(rig.joints[analysis.landmarks.head].name == "head")
    #expect(analysis.prunedNames(in: rig) == ["jaw"])
}

@Test func limbEndsWhereDigitsFanOutEvenWhenUneven() throws {
    // Synth's pinky toe has three bones to the other toes' two, so a
    // "children reach the same distance" test alone walks down the long digit
    // and reports it as part of the leg.
    var b = RigBuilder.biped()
    b.add("toelittle3L", parent: "toelittle2L", 0.20, 0.005, weight: 20)
    let rig = b.build()
    let analysis = try HumanoidInference.analyse(rig)
    func name(_ i: Int) -> String { rig.joints[i].name }
    #expect(analysis.landmarks.leftLeg.map(name) == ["thighL", "shinL", "footL", "toebaseL"])
}

@Test func spineIsNotMistakenForAnArm() throws {
    // The chest reaches to both fingertips, so by raw lateral reach it beats
    // either shoulder. Only "a limb stays on one side of the midline" rejects it.
    let rig = RigBuilder.biped().build()
    let analysis = try HumanoidInference.analyse(rig)
    #expect(rig.joints[analysis.landmarks.leftArm[0]].name == "clavicleL")
    #expect(rig.joints[analysis.landmarks.rightArm[0]].name == "clavicleR")
}

@Test func measuresFromGeometryNotJoints() throws {
    let rig = RigBuilder.biped().build()
    #expect(abs(rig.meshHeight - 1.80) < 0.001)
    #expect(abs(rig.groundOffset) < 0.001)
}

@Test func findsArmsOnAPosedRestPoseInCentimetres() throws {
    // Mixamo's Idle.usdz is the source every clip is authored against, and its
    // rest pose is a posed idle, not a T-pose: the arms hang at the sides and
    // displace almost nothing laterally. It is also authored in centimetres.
    // Both broke the first version of this inference.
    var b = RigBuilder()
    let scale: Float = 100
    b.add("Hips", 0.5 * scale, 1.02 * scale, 0.02 * scale)
    b.add("Spine", parent: "Hips", 0.01 * scale, 1.12 * scale, 0.02 * scale)
    b.add("Spine1", parent: "Spine", 0.02 * scale, 1.22 * scale, 0)
    b.add("Spine2", parent: "Spine1", 0.01 * scale, 1.31 * scale, -0.01 * scale)
    b.add("Neck", parent: "Spine2", 0, 1.44 * scale, -0.01 * scale)
    b.add("Head", parent: "Neck", 0, 1.52 * scale, 0, tail: SIMD3(0, 1.70 * scale, 0), weight: 900)
    for (side, sign) in [("Left", Float(1)), ("Right", Float(-1))] {
        // Arms hang nearly straight down: total lateral travel ~7 cm.
        b.add("\(side)Shoulder", parent: "Spine2", sign * 0.05 * scale, 1.38 * scale, 0)
        b.add("\(side)Arm", parent: "\(side)Shoulder", sign * 0.17 * scale, 1.36 * scale, 0)
        b.add("\(side)ForeArm", parent: "\(side)Arm", sign * 0.21 * scale, 1.10 * scale, 0.01 * scale)
        b.add("\(side)Hand", parent: "\(side)ForeArm", sign * 0.24 * scale, 0.86 * scale, 0.02 * scale)
        b.add("\(side)UpLeg", parent: "Hips", sign * 0.08 * scale, 0.95 * scale, 0)
        b.add("\(side)Leg", parent: "\(side)UpLeg", sign * 0.09 * scale, 0.52 * scale, 0.02 * scale)
        b.add("\(side)Foot", parent: "\(side)Leg", sign * 0.10 * scale, 0.09 * scale, -0.02 * scale)
    }
    var rig = b.build()
    rig.meshBoundsMin = SIMD3(-0.22 * scale, 0, -0.08 * scale)
    rig.meshBoundsMax = SIMD3(0.35 * scale, 2.015 * scale, 0.31 * scale)

    let analysis = try HumanoidInference.analyse(rig)
    func name(_ i: Int) -> String { rig.joints[analysis.landmarks.leftArm.isEmpty ? i : i].name }
    let lm = analysis.landmarks
    #expect(rig.joints[lm.hips].name == "Hips")
    #expect(rig.joints[lm.head].name == "Head")
    #expect(rig.joints[lm.leftArm[0]].name == "LeftShoulder")
    #expect(rig.joints[lm.rightArm[0]].name == "RightShoulder")
    #expect(rig.joints[lm.leftLeg[0]].name == "LeftUpLeg")
    #expect(rig.joints[lm.rightLeg[0]].name == "RightUpLeg")
    #expect(analysis.pruned.isEmpty)
}

@Test func pairsLimbsByRootOffsetNotByTipSwing() throws {
    // Mixamo's idle rest pose swings one foot out to x = +35 cm while the
    // other stays at x = -8. Comparing the two sides on their subtree EXTREMES
    // then rejects the legs as unmatched, the arms get chosen as legs instead,
    // and nothing is left to be the arms. Limb roots barely move under pose.
    var b = RigBuilder.biped()
    let swung = try #require(b.joints.firstIndex { $0.name == "footL" })
    b.joints[swung].restHead = SIMD3(0.42, 0.10, 0.18)
    b.joints[swung].restTail = SIMD3(0.42, 0.06, 0.18)
    let shin = try #require(b.joints.firstIndex { $0.name == "shinL" })
    b.joints[shin].restHead = SIMD3(0.30, 0.48, 0.09)

    let rig = b.build()
    let analysis = try HumanoidInference.analyse(rig)
    func name(_ i: Int) -> String { rig.joints[i].name }
    #expect(name(analysis.landmarks.leftLeg[0]) == "thighL")
    #expect(name(analysis.landmarks.rightLeg[0]) == "thighR")
    #expect(name(analysis.landmarks.leftArm[0]) == "clavicleL")
    #expect(name(analysis.landmarks.rightArm[0]) == "clavicleR")
}

@Test func warnsWhenAModelIsAuthoredInCentimetres() throws {
    var rig = RigBuilder.biped().build()
    for i in rig.joints.indices { rig.joints[i].restHead *= 100 }
    for i in rig.joints.indices { rig.joints[i].restTail.map { rig.joints[i].restTail = $0 * 100 } }
    rig.meshBoundsMin *= 100
    rig.meshBoundsMax *= 100
    let analysis = try HumanoidInference.analyse(rig)
    let report = BindPoseCheck.run(rig, landmarks: analysis.landmarks)
    #expect(report.findings.contains { $0.message.contains("centimetres") })
}
