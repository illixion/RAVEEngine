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
    /// not track it. Pass the arm through a `RAVESleeveArmEstimator` before use: the
    /// tracked elbow flickers and wanders, and the estimator decides when to
    /// believe it.
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

#endif
