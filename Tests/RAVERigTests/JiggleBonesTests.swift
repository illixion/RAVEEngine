import Foundation
import Testing
import simd
@testable import RAVERig

/// Jiggle has to look right for reasons that can be measured: it holds
/// still on a body that holds still, bounces at the frequency it was asked
/// for, settles, ignores steady travel, keeps inside its limits whatever is
/// done to it, and looks the same at any frame rate and any size. Measured
/// on a small skeleton with one of each kind of part.
@Suite struct JiggleBonesTests {

    // MARK: A skeleton with one of everything

    /// Joint paths and parent-relative translations, rotations identity.
    static let joints: [(String, SIMD3<Float>)] = [
        ("Root", [0, 0, 0]),
        ("Root/Spine", [0, 1.2, 0]),
        ("Root/Spine/PCP_Breast_L", [0.1, 0.2, 0.08]),
        ("Root/Spine/PCP_Breast_L/Breast_L_tip", [0, 0, 0.12]),
        ("Root/Butt_L", [0.1, 0.9, -0.1]),
        ("Root/Tail_1", [0, 0.95, -0.12]),
        ("Root/Tail_1/Tail_2", [0, 0, -0.25]),
        ("Root/Tail_1/Tail_2/Tail_3", [0, 0, -0.25]),
        ("Root/Tail_1/Tail_2/Tail_3/Tail_4", [0, 0, -0.25]),
        ("Root/Spine/Breast_L_front", [0.1, 0.2, 0.08]),
        ("Root/Spine/Breast_L_front/Breast_L_front_tip", [0, 0, 0.2]),
    ]
    static let names = joints.map(\.0)
    static let parents = PoseSolver.parents(fromPaths: names)
    static let rest = joints.map { JointPose(translation: $0.1) }
    static let breast = 2, breastTip = 3, butt = 4, tail = 5, front = 9, frontTip = 10

    private func bones(_ specs: [JiggleSpec]) -> JiggleBones {
        JiggleBones(specs: specs, jointNames: Self.names, parents: Self.parents, rest: Self.rest)
    }

    private func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    private func model(_ pose: [JointPose]) -> [float4x4] {
        PoseSolver(parents: Self.parents).modelMatrices(of: pose)
    }

    private func position(_ joint: Int, in pose: [JointPose], world: float4x4 = matrix_identity_float4x4) -> SIMD3<Float> {
        let p = world * model(pose)[joint].columns.3
        return SIMD3(p.x, p.y, p.z)
    }

    /// Runs `seconds` of a body following `path` (world offset at time t),
    /// returning the swing tip's world displacement from where a rigid body
    /// would put it, every frame.
    private func run(_ bones: inout JiggleBones, seconds: Float, fps: Float = 90, start: Float = 0,
                     scale: Float = 1, sizeScale: Float = 1, joint: Int = breastTip,
                     path: (Float) -> SIMD3<Float>) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let frames = Int((seconds * fps).rounded())
        for f in 1...frames {
            let t = start + Float(f) / fps
            var world = translation(path(t))
            world.columns.0 *= scale
            world.columns.1 *= scale
            world.columns.2 *= scale
            var pose = Self.rest
            bones.apply(to: &pose, modelToWorld: world, deltaTime: 1 / fps, sizeScale: sizeScale)
            out.append(position(joint, in: pose, world: world) - position(joint, in: Self.rest, world: world))
        }
        return out
    }

    private func deflection(_ bones: JiggleBones, _ name: String) -> Float {
        bones.parts.first { $0.name == name }?.deflection ?? .nan
    }

    // MARK: Holding still

    @Test func aStillBodyWithoutGravityHoldsItsPose() {
        var spec = JiggleSpec.breast("PCP_Breast_L")
        spec.gravity = 0
        var b = bones([spec, .butt("Butt_L").zeroGravity, JiggleSpec.tail("Tail_1", chainLength: 4).zeroGravity])
        var pose = Self.rest
        for _ in 0..<270 {
            pose = Self.rest
            b.apply(to: &pose, modelToWorld: matrix_identity_float4x4, deltaTime: 1 / 90)
        }
        for (a, r) in zip(pose, Self.rest) {
            #expect(abs(simd_dot(a.rotation.vector, r.rotation.vector)) > 0.99999)
            #expect(simd_distance(a.translation, r.translation) < 1e-5)
        }
    }

    @Test func gravitySagsALittleAndSettles() {
        var b = bones([.breast("PCP_Breast_L")])
        let shifts = run(&b, seconds: 4) { _ in .zero }
        let sag = shifts.last!
        // Down, a few millimetres: 0.15 g on a 2.2 Hz spring is 7.7 mm.
        #expect(sag.y < -0.004 && sag.y > -0.012, "sag \(sag)")
        // Settled: the last second barely moves.
        let lastSecond = shifts.suffix(90)
        let spread = lastSecond.map(\.y).max()! - lastSecond.map(\.y).min()!
        #expect(spread < 1e-4, "still moving by \(spread) m")
    }

    @Test func aPartPutDownStartsHangingRatherThanFalling() {
        // A tail held straight out, at rest: switched on (or reset) it should
        // already hang as it will settle, not drop and bounce. Started rigid,
        // Mal0's tail whipped to its 30° limit on every new hiding spot.
        var b = bones([JiggleSpec.tail("Tail_1", chainLength: 4), .breast("PCP_Breast_L")])
        var peaks = [String: Float]()
        for _ in 0..<360 {
            var pose = Self.rest
            b.apply(to: &pose, modelToWorld: matrix_identity_float4x4, deltaTime: 1 / 90)
            for part in b.parts { peaks[part.name] = max(peaks[part.name] ?? 0, part.deflection) }
        }
        for part in b.parts {
            let peak = peaks[part.name]!
            #expect(part.deflection > 0.5, "\(part.name) does not sag at all")
            #expect(peak < part.deflection * 1.25 + 0.2,
                    "\(part.name) peaked at \(peak)° settling to \(part.deflection)°")
        }
    }

    // MARK: Bouncing

    @Test func steadyTravelIsNotFeltButAStopIs() {
        var spec = JiggleSpec.breast("PCP_Breast_L")
        spec.gravity = 0
        var b = bones([spec])
        // 1 m/s along +X for three seconds, then a dead stop.
        let path: (Float) -> SIMD3<Float> = { t in SIMD3(min(t, 3), 0, 0) }
        let shifts = run(&b, seconds: 6, path: path)
        let cruising = shifts[(2 * 90)..<(3 * 90)].map { simd_length($0) }.max()!
        let afterStop = shifts[(3 * 90)..<(4 * 90)].map { simd_length($0) }.max()!
        let settled = shifts.suffix(45).map { simd_length($0) }.max()!
        #expect(cruising < 1e-3, "trailed \(cruising) m at a steady walk")
        #expect(afterStop > 0.01, "a stop moved the tip only \(afterStop) m")
        #expect(settled < 1e-3, "still \(settled) m off three seconds after")
        // Forward first: the flesh carries on when the body stops.
        let firstBig = shifts[(3 * 90)...].first { simd_length($0) > 0.002 }!
        #expect(firstBig.x > 0)
    }

    @Test func itBouncesAtTheFrequencyAskedFor() {
        var spec = JiggleSpec(.swing, joint: "PCP_Breast_L", frequency: 2, damping: 0.03, gravity: 0, maxAngle: 80)
        spec.radius = 0
        var b = bones([spec])
        _ = run(&b, seconds: 0.1) { _ in .zero }
        b.kick(SIMD3(0.3, 0, 0))
        let x = run(&b, seconds: 3, start: 0.1) { _ in .zero }.map(\.x)
        var crossings: [Int] = []
        for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) { crossings.append(i) }
        #expect(crossings.count >= 6)
        let periods = zip(crossings, crossings.dropFirst(2)).map { Float($1 - $0) / 90 }
        let period = periods.reduce(0, +) / Float(periods.count)
        #expect(abs(period - 0.5) < 0.03, "period \(period) s for 2 Hz")
    }

    @Test func dampingDecidesHowSoonItSettles() {
        func ringDown(_ damping: Float) -> Int {
            var spec = JiggleSpec(.swing, joint: "PCP_Breast_L", frequency: 2.5, damping: damping, gravity: 0)
            spec.maxAngle = 80
            var b = bones([spec])
            _ = run(&b, seconds: 0.1) { _ in .zero }
            b.kick(SIMD3(0.4, 0, 0))
            let shifts = run(&b, seconds: 5, start: 0.1) { _ in .zero }
            return shifts.lastIndex { simd_length($0) > 0.002 } ?? 0
        }
        #expect(ringDown(0.6) < ringDown(0.25))
        #expect(ringDown(0.25) < ringDown(0.08))
    }

    @Test func theLookDoesNotDependOnTheFrameRate() {
        func peak(fps: Float) -> Float {
            var spec = JiggleSpec.breast("PCP_Breast_L")
            spec.gravity = 0
            var b = bones([spec])
            let shifts = run(&b, seconds: 4, fps: fps) { t in SIMD3(min(t, 2) * 1.2, 0, 0) }
            return shifts[Int(2 * fps)...].map { simd_length($0) }.max()!
        }
        let fast = peak(fps: 90), slow = peak(fps: 45), fastest = peak(fps: 120)
        #expect(abs(slow - fast) / fast < 0.05, "45 Hz peak \(slow) vs 90 Hz \(fast)")
        #expect(abs(fastest - fast) / fast < 0.05, "120 Hz peak \(fastest) vs 90 Hz \(fast)")
    }

    // MARK: Limits, whatever is done to it

    @Test func aSwingStaysInsideItsConeAndKeepsItsLength() {
        var spec = JiggleSpec.breast("PCP_Breast_L")
        spec.maxAngle = 15
        var b = bones([spec])
        var worst: Float = 0
        var worstLength: Float = 0
        for f in 1...600 {
            let t = Float(f) / 90
            let world = translation(SIMD3(sin(t * 17) * 0.4, cos(t * 23) * 0.3, sin(t * 11) * 0.5))
            var pose = Self.rest
            b.apply(to: &pose, modelToWorld: world, deltaTime: 1 / 90)
            worst = max(worst, deflection(b, "PCP_Breast_L"))
            let length = simd_distance(position(Self.breastTip, in: pose), position(Self.breast, in: pose))
            worstLength = max(worstLength, abs(length - 0.12))
        }
        #expect(worst <= 15.01, "swung \(worst)°")
        #expect(worst > 10, "never reached its limit: \(worst)°")
        #expect(worstLength < 1e-4)
    }

    @Test func aSpringStaysWithinItsReach() {
        var b = bones([.butt("Butt_L")])
        var worst: Float = 0
        for f in 1...600 {
            let t = Float(f) / 90
            let world = translation(SIMD3(sin(t * 19) * 0.4, cos(t * 13) * 0.3, 0))
            var pose = Self.rest
            b.apply(to: &pose, modelToWorld: world, deltaTime: 1 / 90)
            worst = max(worst, simd_distance(pose[Self.butt].translation, Self.rest[Self.butt].translation))
        }
        #expect(worst <= 0.0201, "lagged \(worst) m")
        #expect(worst > 0.015, "barely moved: \(worst) m")
    }

    @Test func carryingTheWholeBodyLeavesOnlyTheAnimation() {
        var spec = JiggleSpec.breast("PCP_Breast_L")
        spec.carry = 1
        spec.gravity = 0
        var b = bones([spec])
        var worst: Float = 0
        for f in 1...400 {
            let t = Float(f) / 90
            var world = translation(SIMD3(sin(t * 7) * 0.6, 0, t))
            let turn = float4x4(simd_quatf(angle: sin(t * 3), axis: SIMD3(0, 1, 0)))
            world = world * turn
            var pose = Self.rest
            b.apply(to: &pose, modelToWorld: world, deltaTime: 1 / 90)
            worst = max(worst, deflection(b, "PCP_Breast_L"))
        }
        #expect(worst < 0.05, "carried body still swung \(worst)°")
    }

    @Test func aSmallerCharacterJigglesTheSameWay() {
        func peakAngle(scale: Float) -> Float {
            var b = bones([.breast("PCP_Breast_L")])
            var peak: Float = 0
            for f in 1...360 {
                let t = Float(f) / 90
                var world = translation(SIMD3(min(t, 2), 0, 0) * scale)
                world.columns.0 *= scale
                world.columns.1 *= scale
                world.columns.2 *= scale
                var pose = Self.rest
                b.apply(to: &pose, modelToWorld: world, deltaTime: 1 / 90, sizeScale: scale)
                if t > 2 { peak = max(peak, deflection(b, "PCP_Breast_L")) }
            }
            return peak
        }
        let full = peakAngle(scale: 1), half = peakAngle(scale: 0.5)
        #expect(abs(full - half) / full < 0.02, "full \(full)° vs half size \(half)°")
    }

    @Test func aTeleportIsNotAFling() {
        var b = bones([.breast("PCP_Breast_L")])
        _ = run(&b, seconds: 2) { _ in .zero }
        let shifts = run(&b, seconds: 1, start: 2) { _ in SIMD3(5, 0, 0) }
        #expect(shifts.map { simd_length($0) }.max()! < 0.012)
    }

    // MARK: Spaces

    @Test func gravityPullsDownInTheWorldWhateverWayTheSkeletonIsBuilt() {
        // The skeleton lying on its side, its model up along world -X, the
        // way an asset authored in another up axis carries its turn in the
        // model-to-world transform. The breast bone still points along
        // world +Z, level, so gravity can swing it. Applied in model space by
        // mistake, gravity would pull the tip toward world +X instead.
        var b = bones([JiggleSpec.breast("PCP_Breast_L").withGravity(1)])
        let zUp = float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        var pose = Self.rest
        for _ in 0..<360 {
            pose = Self.rest
            b.apply(to: &pose, modelToWorld: zUp, deltaTime: 1 / 90)
        }
        let sagged = position(Self.breastTip, in: pose, world: zUp)
        let rigid = position(Self.breastTip, in: Self.rest, world: zUp)
        #expect(sagged.y < rigid.y - 0.01, "tip went from \(rigid) to \(sagged)")
        #expect(abs(sagged.x - rigid.x) < 1e-3)
    }

    @Test func handsPushTheTipAway() {
        var spec = JiggleSpec.breast("PCP_Breast_L")
        spec.gravity = 0
        var b = bones([spec])
        let tip = position(Self.breastTip, in: Self.rest)
        // A palm just in front of the tip, a little to the side.
        let hand = ChainDynamics.Sphere(center: tip + SIMD3(0.02, 0, 0.03), radius: 0.04)
        var pose = Self.rest
        for _ in 0..<90 {
            pose = Self.rest
            b.apply(to: &pose, modelToWorld: matrix_identity_float4x4, deltaTime: 1 / 90, obstacles: [hand])
        }
        let pushed = position(Self.breastTip, in: pose)
        // As far as its 20° cone lets it go: out of the hand's way, and to
        // the side away from the hand.
        #expect(simd_distance(pushed, hand.center) > simd_distance(tip, hand.center) + 0.025,
                "tip only got to \(simd_distance(pushed, hand.center)) m from the hand")
        #expect(pushed.x < tip.x - 0.02, "pushed toward the hand: \(pushed)")
        #expect(deflection(b, "PCP_Breast_L") > 19.9)
    }

    // MARK: Resolving a request

    @Test func namesResolveExactlyOrBySuffixAndFailuresSayWhy() {
        let b = bones([
            .breast("Breast_L"),                       // suffix of PCP_Breast_L
            .butt("Nope"),                             // absent
            JiggleSpec(.swing, joint: "Butt_L"),       // a leaf, no tip
            .ear("tip"),                               // ambiguous suffix
        ])
        #expect(b.parts.map(\.name) == ["PCP_Breast_L"])
        let reasons = Dictionary(uniqueKeysWithValues: b.unresolved.map { ($0.joint, $0.reason) })
        #expect(reasons["Nope"]?.contains("no joint") == true)
        #expect(reasons["Butt_L"]?.contains("leaf") == true)
        #expect(reasons["tip"]?.contains("end with") == true)
    }

    @Test func aChainIsOneSpringPerLinkAndItsEndCarriesOn() {
        var b = bones([.tail("Tail_1", chainLength: 4)])
        #expect(b.parts.map(\.name) == ["Tail_1", "Tail_2", "Tail_3", "Tail_4"])
        #expect(b.unresolved.isEmpty)
        // Under gravity it curls down, each link below the one before.
        var pose = Self.rest
        for _ in 0..<450 {
            pose = Self.rest
            b.apply(to: &pose, modelToWorld: matrix_identity_float4x4, deltaTime: 1 / 90)
        }
        let heights = (5...8).map { position($0, in: pose).y }
        for (upper, lower) in zip(heights, heights.dropFirst()) { #expect(lower < upper) }
        // Looser toward the tip.
        let frequencies = b.parts.map(\.frequency)
        #expect(frequencies.first! > frequencies.last!)
    }

    @Test func aChainWithShorteningLinksSettlesAfterAJolt() {
        // Mal0's tail in miniature: five links shortening toward the tip,
        // the softest default damping, a 12 cm hop. Pulled along their
        // parents' simulated directions, the last links were still swinging
        // against their 30° limit two seconds after the base had settled.
        let lengths: [Float] = [0.27, 0.28, 0.2, 0.16]
        var names = ["Root", "Root/T0"]
        var translations: [SIMD3<Float>] = [.zero, [0, 1.2, -0.07]]
        for (i, length) in lengths.enumerated() {
            names.append(names.last! + "/T\(i + 1)")
            translations.append([0, -0.03, -length])
        }
        let parents = PoseSolver.parents(fromPaths: names)
        let rest = translations.map { JointPose(translation: $0) }
        var b = JiggleBones(specs: [.tail("T0", chainLength: 5)], jointNames: names, parents: parents, rest: rest)
        var atRest: [Float] = []
        var late = [Float](repeating: 0, count: 5)
        var moved: Float = 0
        for f in 0..<(90 * 5) {
            let t = Float(f) / 90
            let up: Float = t < 0.4 ? 0 : (t < 0.6 ? sin((t - 0.4) / 0.2 * .pi / 2)
                                         : (t < 0.75 ? cos((t - 0.6) / 0.15 * .pi / 2) : 0))
            var world = matrix_identity_float4x4
            world.columns.3 = SIMD4(0, 0.12 * up, 0, 1)
            var pose = rest
            b.apply(to: &pose, modelToWorld: world, deltaTime: 1 / 90)
            if f == 0 { atRest = b.parts.map(\.deflection) }
            moved = max(moved, b.parts[0].deflection)
            // Two seconds after landing: how far each link still is from rest.
            if t > 2.75 {
                for (i, part) in b.parts.enumerated() { late[i] = max(late[i], abs(part.deflection - atRest[i])) }
            }
        }
        #expect(b.parts.count == 5)
        #expect(moved > 8, "the hop barely moved the base: \(moved)°")
        #expect(late.allSatisfy { $0 < 1 }, "still swinging two seconds after landing: \(late)")
    }

    @Test func aTooLongChainSaysWhereItEnded() {
        let b = bones([.tail("Tail_1", chainLength: 7)])
        #expect(b.parts.count == 4)
        #expect(b.unresolved.first?.reason.contains("4 of 7") == true)
    }

    @Test func linkedJointsTurnWithTheSimulatedOne() {
        var spec = JiggleSpec.breast("PCP_Breast_L", linked: ["Breast_L_front"])
        spec.gravity = 0
        var b = bones([spec])
        #expect(b.parts.count == 1)
        #expect(b.parts[0].joints == [Self.breast, Self.front])
        _ = run(&b, seconds: 3) { t in SIMD3(min(t, 2), 0, 0) }
        var pose = Self.rest
        b.apply(to: &pose, modelToWorld: translation(SIMD3(2, 0, 0)), deltaTime: 1 / 90)
        let m = model(pose)
        let a = PoseSolver.rotation(of: m[Self.breast]), c = PoseSolver.rotation(of: m[Self.front])
        #expect(abs(simd_dot(a.vector, c.vector)) > 0.99999)
        #expect(a.angle > 0.01)
    }

    @Test func eachJointIsJiggledOnce() {
        let b = bones([.breast("PCP_Breast_L"), .ear("PCP_Breast_L")])
        #expect(b.parts.count == 1)
        #expect(b.unresolved.first?.reason.contains("already") == true)
    }

    // MARK: For an IK host

    @Test func constraintTargetsAreWhereTheTipsWent() {
        var b = bones([.breast("PCP_Breast_L"), .butt("Butt_L")])
        #expect(b.constrainedJoints == [Self.breastTip])
        _ = run(&b, seconds: 2.2) { t in SIMD3(min(t, 2), 0, 0) }
        var pose = Self.rest
        b.apply(to: &pose, modelToWorld: translation(SIMD3(2, 0, 0)), deltaTime: 1 / 90)
        let targets = b.constraintTargets(in: pose)
        #expect(targets.count == 1)
        #expect(simd_distance(targets[0], position(Self.breastTip, in: pose)) < 1e-6)
        #expect(simd_distance(targets[0], position(Self.breastTip, in: Self.rest)) > 1e-3)
    }

    @Test func anAnalysedRigNamesTheSameConstraintsAsThePose() {
        // A rig knows rest positions only; the pose knows rotations too.
        // Both must agree on which children the swings aim at.
        let model = model(Self.rest)
        let rig = RigSkeleton(joints: Self.names.indices.map { i in
            RigSkeleton.Joint(name: Self.names[i].split(separator: "/").last.map(String.init)!,
                              parent: Self.parents[i],
                              restHead: PoseSolver.translation(of: model[i]))
        })
        let specs: [JiggleSpec] = [.breast("PCP_Breast_L", linked: ["Breast_L_front"]),
                                   .tail("Tail_1", chainLength: 4), .butt("Butt_L")]
        let fromRig = JiggleBones(specs: specs, rig: rig)
        let fromPose = bones(specs)
        #expect(fromRig.constrainedJoints.map { rig.joints[$0].name }
                == fromPose.constrainedJoints.map { String(Self.names[$0].split(separator: "/").last!) })
        #expect(fromRig.constrainedJoints.contains(Self.frontTip))
    }

    // MARK: As data

    @Test func aSpecReadsFromJSONWithDefaults() throws {
        let json = #"[{"joint":"Butt_L","motion":"spring","maxOffset":0.01},{"joint":"Ear_L","chainLength":3}]"#
        let specs = try JSONDecoder().decode([JiggleSpec].self, from: Data(json.utf8))
        #expect(specs[0].motion == .spring)
        #expect(specs[0].maxOffset == 0.01)
        #expect(specs[0].frequency == JiggleSpec(.spring, joint: "x").frequency)
        #expect(specs[1].motion == .swing)
        #expect(specs[1].chainLength == 3)
        let again = try JSONDecoder().decode([JiggleSpec].self, from: JSONEncoder().encode(specs))
        #expect(again == specs)
    }
}

private extension JiggleSpec {
    var zeroGravity: JiggleSpec { withGravity(0) }
    func withGravity(_ g: Float) -> JiggleSpec {
        var copy = self
        copy.gravity = g
        return copy
    }
}
