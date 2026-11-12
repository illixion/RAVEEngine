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
    /// palm cannot be resolved.
    ///
    /// The anchor's own tracking is the only gate. A joint's `isTracked` goes
    /// false whenever that joint is hidden (the elbow end of the forearm on
    /// about two frames in three with the arm held up, Vision Pro 2026-11-12),
    /// but ARKit still gives it an estimated pose, and that pose is good:
    /// LambdaVision draws its arms and hangs its forearm readouts on it.
    /// Dropping the elbow on those frames is what made a sleeve flicker
    /// between two sources. Pass the arm through a `RAVESleeveArmEstimator`
    /// all the same: it catches the estimate going wrong (a hand covering the
    /// forearm) by its speed and length.
    ///
    /// Nonisolated, so a render thread can call it with an anchor predicted
    /// for the frame's presentation time.
    nonisolated init?(_ anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton, let sample = RAVEHandSample(anchor),
              let palm = RAVEPalmGeometry.palmPose(from: sample) else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        func position(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(name).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        self.init(side: anchor.chirality == .left ? .left : .right,
                  wrist: position(.forearmWrist), elbow: position(.forearmArm), palm: palm)
    }

    /// The `forearmWrist` joint's transform in the world: the space a host
    /// runs the sleeve in when its tiles hang off RealityKit's anchor for the
    /// same joint (`RAVESleevePanels.anchor(to:)`).
    nonisolated static func wristJointTransform(_ anchor: HandAnchor) -> simd_float4x4? {
        guard anchor.isTracked, let joint = anchor.handSkeleton?.joint(.forearmWrist) else { return nil }
        return anchor.originFromAnchorTransform * joint.anchorFromJointTransform
    }

    /// The fingertip that presses a sleeve: the index tip of a tracked hand
    /// anchor (its estimated pose while the tip itself is hidden).
    nonisolated static func fingertip(_ anchor: HandAnchor) -> SIMD3<Float>? {
        guard anchor.isTracked, let joint = anchor.handSkeleton?.joint(.indexFingerTip) else { return nil }
        let m = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}

#endif
