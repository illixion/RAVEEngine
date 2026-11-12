/*
 RAVE Engine — a sleeve's arm from ARKit.

 The only file in this target that names an ARKit symbol. A host that gets its
 hands another way (Longwave's controller bridge, a recorded take) builds
 `RAVESleeveArm` itself.
 */

#if os(visionOS)

import ARKit
import RAVEInput
import simd

public extension RAVESleeveArm {
    /// The arm of a hand anchor, or nil when the hand is untracked or its
    /// palm cannot be resolved. The elbow end is left out while ARKit does
    /// not track it, and the frame is then estimated from the hand.
    ///
    /// Nonisolated, so a render thread can call it with an anchor predicted
    /// for the frame's presentation time.
    nonisolated init?(_ anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton, let sample = RAVEHandSample(anchor),
              let palm = RAVEPalmGeometry.palmPose(from: sample) else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        func position(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let m = originFromAnchor * joint.anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        self.init(side: anchor.chirality == .left ? .left : .right,
                  wrist: position(.forearmWrist) ?? sample.wrist,
                  elbow: position(.forearmArm), palm: palm)
    }

    /// The fingertip that presses a sleeve: the index tip of a hand anchor,
    /// nil while it is untracked.
    nonisolated static func fingertip(_ anchor: HandAnchor) -> SIMD3<Float>? {
        guard anchor.isTracked, let joint = anchor.handSkeleton?.joint(.indexFingerTip), joint.isTracked else {
            return nil
        }
        let m = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}

/// Reads a sleeve's arm from hand anchors and remembers where the elbow is.
///
/// ARKit tracks the elbow end of the forearm (`forearmArm`) only part of the
/// time: about a third of the frames with the arm held up to look at, measured
/// on a Vision Pro 2026-11-12. Estimating the arm from the fingers instead
/// makes the sleeve swing with every bend of the wrist. So while the elbow is
/// tracked, this learns where it sits in the `forearmWrist` joint's own frame
/// (a direction and a length, per arm), and uses that while it is not: the
/// joint turns with the forearm, not with the hand. Which local axis that is
/// is measured, not assumed, so it does not depend on ARKit's joint
/// conventions.
public struct RAVESleeveArmSampler: Sendable {
    private struct Elbow: Sendable {
        var direction: SIMD3<Float>
        var length: Float
    }

    private var left: Elbow?
    private var right: Elbow?

    public init() {}

    /// Whether the elbow of that arm has been seen yet.
    public func hasLearnedElbow(_ side: RAVESleeveSide) -> Bool {
        (side == .left ? left : right) != nil
    }

    /// The arm of a hand anchor, with a remembered elbow while ARKit does not
    /// track it. Nil as for `RAVESleeveArm.init(_:)`.
    public mutating func arm(_ anchor: HandAnchor) -> RAVESleeveArm? {
        guard var arm = RAVESleeveArm(anchor), let skeleton = anchor.handSkeleton else { return nil }
        let joint = skeleton.joint(.forearmWrist)
        guard joint.isTracked else { return arm }
        let world = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        var learned = arm.side == .left ? left : right
        if let elbow = arm.elbow {
            let local = world.inverse * SIMD4(elbow, 1)
            let offset = SIMD3(local.x, local.y, local.z)
            let length = simd_length(offset)
            if length > 0.12, length < 0.45 {
                let direction = offset / length
                if let known = learned {
                    // Settle over about a second of tracked frames.
                    learned = Elbow(direction: simd_normalize(known.direction + (direction - known.direction) * 0.03),
                                    length: known.length + (length - known.length) * 0.03)
                } else {
                    learned = Elbow(direction: direction, length: length)
                }
            }
        } else if let known = learned {
            let p = world * SIMD4(known.direction * known.length, 1)
            arm.elbow = SIMD3(p.x, p.y, p.z)
        }
        if arm.side == .left { left = learned } else { right = learned }
        return arm
    }
}

#endif
