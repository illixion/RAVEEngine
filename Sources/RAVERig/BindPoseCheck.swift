import Foundation

/// Rest-pose sanity checks.
///
/// This exists because of a finding from the Synth spike: the retargeter can
/// be working perfectly and the character still looks wrong, because the bind
/// pose exported from the source file is itself wrong. That failure is upstream
/// of everything and no `jointOffsets` value hides it, so the importer names it
/// rather than letting the user discover it as "the retargeting looks bad".
public struct BindPoseCheck: Sendable {

    public enum Severity: String, Sendable, Codable {
        case info, warning, problem
        public var marker: String {
            switch self {
            case .info: "·"
            case .warning: "!"
            case .problem: "✗"
            }
        }
    }

    public struct Finding: Sendable, Codable, Equatable {
        public var severity: Severity
        public var message: String
    }

    public struct Report: Sendable, Codable, Equatable {
        public var findings: [Finding]
        /// Angle of the arms away from horizontal: ~0° is a T-pose, ~45° an
        /// A-pose. Recorded because it is the single number that predicts how
        /// much `jointOffsets` correction a source will need.
        public var armAngleFromHorizontal: Float
        public var legAngleFromVertical: Float
        public var headTiltFromVertical: Float

        public var worst: Severity {
            findings.contains { $0.severity == .problem } ? .problem
                : findings.contains { $0.severity == .warning } ? .warning : .info
        }

        public var verdict: String {
            switch worst {
            case .info: "looks sane"
            case .warning: "usable, with caveats"
            case .problem: "authored wrong — fix in the source file, not in the retargeter"
            }
        }
    }

    public static func run(_ rig: RigSkeleton, landmarks lm: HumanoidLandmarks) -> Report {
        var findings: [Finding] = []
        func head(_ i: Int) -> SIMD3<Float> { rig.joints[i].restHead }

        // --- Arms ------------------------------------------------------------
        // Measured shoulder-to-hand so a single bent elbow does not dominate.
        let armAngles: [Float] = [lm.leftArm, lm.rightArm].compactMap { chain in
            guard let first = chain.first, let last = chain.last, first != last else { return nil }
            let axis = head(last) - head(first)
            return abs(90 - angleDegrees(axis, SIMD3<Float>(0, 1, 0)))
        }
        let armAngle = armAngles.isEmpty ? 0 : armAngles.reduce(0, +) / Float(armAngles.count)
        findings.append(.init(severity: .info,
            message: "arms sit \(fmt(armAngle))° from horizontal (\(poseName(armAngle)))"))
        if armAngle > 75 {
            findings.append(.init(severity: .warning,
                message: "arms hang almost straight down; Mixamo clips are authored from a "
                       + "T/A-pose, so expect to need jointOffsets on the shoulders"))
        }

        // --- Legs ------------------------------------------------------------
        // Hip-to-foot, not thigh-to-foot: a digitigrade leg is angled at every
        // joint and still stands vertically overall, which is what matters.
        let legAngles: [Float] = [lm.leftLeg, lm.rightLeg].compactMap { chain in
            guard let first = chain.first, let last = chain.last, first != last else { return nil }
            return angleDegrees(head(first) - head(last), SIMD3<Float>(0, 1, 0))
        }
        let legAngle = legAngles.isEmpty ? 0 : legAngles.reduce(0, +) / Float(legAngles.count)
        findings.append(.init(severity: .info, message: "legs sit \(fmt(legAngle))° from vertical"))
        if legAngle > 20 {
            findings.append(.init(severity: .problem,
                message: "legs are splayed \(fmt(legAngle))° from vertical — the model is not "
                       + "standing straight in its rest pose"))
        }

        // --- Head ------------------------------------------------------------
        // The head bone's OWN axis, not the neck-to-head offset: a skull sits
        // forward of the neck base on every correct anatomy, so measuring the
        // offset reports ~20 degrees of "tilt" on a perfectly upright head.
        var headTilt: Float = 0
        if let tail = rig.joints[lm.head].restTail {
            headTilt = angleDegrees(tail - head(lm.head), SIMD3<Float>(0, 1, 0))
            findings.append(.init(severity: .info, message: "head sits \(fmt(headTilt))° off vertical"))
            if headTilt > 25 {
                findings.append(.init(severity: .problem,
                    message: "head is tipped \(fmt(headTilt))° in the rest pose"))
            }
        }

        // --- Symmetry ---------------------------------------------------------
        for (label, l, r) in [("arm", lm.leftArm, lm.rightArm), ("leg", lm.leftLeg, lm.rightLeg)] {
            if l.count != r.count {
                findings.append(.init(severity: .warning,
                    message: "\(label) chains differ in length (\(l.count) vs \(r.count) joints); "
                           + "retargeting will map the shorter one"))
                continue
            }
            let drift = zip(l, r).map { abs(head($0).y - head($1).y) }.max() ?? 0
            if drift > rig.meshHeight * 0.02 {
                findings.append(.init(severity: .warning,
                    message: "\(label) chains are \(fmt(drift * 100)) cm out of vertical alignment "
                           + "left-to-right"))
            }
        }

        // --- Ground -----------------------------------------------------------
        let lowestJoint = [lm.leftFoot, lm.rightFoot].compactMap { $0 }.map { head($0).y }.min()
        if let lowestJoint {
            let clearance = lowestJoint - rig.meshBoundsMin.y
            if clearance < 0 {
                findings.append(.init(severity: .warning,
                    message: "foot joints sit below the mesh — the rig extends past the geometry"))
            } else {
                findings.append(.init(severity: .info,
                    message: "foot joints sit \(fmt(clearance * 100)) cm above the lowest geometry"))
            }
        }
        if abs(rig.meshBoundsMin.y) > rig.meshHeight * 0.02 {
            findings.append(.init(severity: .warning,
                message: "model origin is \(fmt(rig.meshBoundsMin.y * 100)) cm off the sole; "
                       + "the package stores a ground offset to compensate"))
        }

        // --- Units -----------------------------------------------------------
        // Mixamo authors in centimetres, so its rigs measure ~200 "metres".
        // Harmless for retargeting, which normalises, but a package that
        // records the height verbatim then scales the character 100x.
        if rig.meshHeight > 10 {
            findings.append(.init(severity: .warning,
                message: "model measures \(fmt(rig.meshHeight)) units tall — almost certainly "
                       + "centimetres, not metres; scale it by 0.01 on import"))
        } else if rig.meshHeight > 0, rig.meshHeight < 0.3 {
            findings.append(.init(severity: .warning,
                message: "model measures only \(fmt(rig.meshHeight)) units tall — check the scene units"))
        }

        return Report(findings: findings,
                      armAngleFromHorizontal: armAngle,
                      legAngleFromVertical: legAngle,
                      headTiltFromVertical: headTilt)
    }

    private static func poseName(_ angle: Float) -> String {
        switch angle {
        case ..<20: "T-pose"
        case ..<60: "A-pose"
        default: "arms down"
        }
    }
}

private func fmt(_ v: Float) -> String { String(format: "%.1f", v) }
