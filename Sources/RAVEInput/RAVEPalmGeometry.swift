/*
 RAVE Engine — palm plane and palm-facing metrics.

 Two questions, both pure geometry over `RAVEHandSample`:

   1. Where is the palm and which way does it face?  (`palmPose`)
   2. How squarely is it facing a point — usually the head?  (`facing`, `pitchInvariantFacing`)

 ## Which side of the palm plane is "out"

 The plane itself is easy: the fingers axis crossed with the across-the-knuckles
 axis. Picking a *side* is where two apps got it wrong in three different ways,
 each time by reasoning about a convention instead of measuring something.

 One earlier attempt took the wrist joint's local −Y. That works, but only
 because it is only ever applied to the right hand — it is a chirality-specific
 rule wearing the clothes of a general one. Longwave first inherited that rule,
 then replaced it with a per-hand sign derived from a hand-drawn diagram, and a
 sign convention that has to be talked through is one that can be talked through
 wrongly.

 What ships here is Longwave's third and correct answer: **the thumb decides.**
 The thumb column is rotated roughly 90° out of the plane of the fingers and
 sits on the palmar side of it. That is true of both hands, in any pose, and
 does not depend on how the tracking framework numbers its axes. Project the
 thumb knuckle onto the plane normal and take whichever direction it agrees with.

 ## Two facing metrics, both deliberate

 The apps disagree here on purpose, and the disagreement is a real product
 decision rather than drift, so both survive:

 - `facing` is a plain dot product. A palm counts as facing you only when it
   actually points at you. Longwave's wrist panel wants this — "turn your palm
   toward your face" should mean exactly that.
 - `pitchInvariantFacing` strips the finger-axis component first, so tilting the
   hand up or down does not change the reading and only the sideways/palm-flip
   alignment counts. This is what a forgiving trigger wants: one that can be
   tightened against a wide swing without punishing pitch. An engage/release
   threshold pair tuned against this metric is not transferable to the plain one.
 */

import simd

public enum RAVEPalmGeometry {

    /// Below this, the thumb is too close to the palm plane to say which side it
    /// is on — a flat splayed hand seen edge-on. Reporting nothing beats
    /// flipping a panel's mount.
    public static let thumbEvidenceThreshold: Float = 0.005

    /// World-space palm pose, or `nil` when the sample is too degenerate to
    /// resolve (joints coincident, or the thumb too close to the palm plane).
    ///
    /// `position` is the midpoint of the wrist and the middle-finger knuckle, so
    /// an attachment mounted here sits over the palm rather than on the wrist.
    public static func palmPose(from sample: RAVEHandSample) -> RAVEPalmPose? {
        let wrist = sample.wrist
        let knuckle = sample.middle.knuckle
        guard simd_distance(wrist, knuckle) > 1e-4 else { return nil }
        let fingers = simd_normalize(knuckle - wrist)

        let across = sample.little.knuckle - sample.index.knuckle
        guard simd_length(across) > 1e-4 else { return nil }
        var normal = simd_cross(fingers, simd_normalize(across))
        guard simd_length(normal) > 1e-4 else { return nil }
        normal = simd_normalize(normal)

        // Which way is out of the palm? The way the thumb leans.
        let palmCenter = (wrist + knuckle) * 0.5
        let thumbAlongNormal = simd_dot(sample.thumbKnuckle - palmCenter, normal)
        guard abs(thumbAlongNormal) > thumbEvidenceThreshold else { return nil }
        if thumbAlongNormal < 0 { normal = -normal }

        return RAVEPalmPose(
            position: palmCenter,
            palmNormalOut: normal,
            fingersDirection: fingers
        )
    }

    /// How directly the palm faces `target`: +1 squarely toward it, 0 edge-on,
    /// −1 away. `nil` when the target coincides with the palm.
    public static func facing(_ pose: RAVEPalmPose, towards target: SIMD3<Float>) -> Float? {
        let toTarget = target - pose.position
        let distance = simd_length(toTarget)
        guard distance > 1e-4 else { return nil }
        return simd_dot(pose.palmNormalOut, toTarget / distance)
    }

    /// `facing`, measured with the finger-axis (pitch) component removed from
    /// both vectors first — so tilting the hand up or down does not change the
    /// result and only the sideways / palm-flip alignment counts.
    public static func pitchInvariantFacing(
        _ pose: RAVEPalmPose,
        towards target: SIMD3<Float>
    ) -> Float? {
        let toTarget = target - pose.position
        let distance = simd_length(toTarget)
        guard distance > 1e-4 else { return nil }
        let direction = toTarget / distance
        let axis = pose.fingersDirection

        let projectedDirection = direction - axis * simd_dot(direction, axis)
        let projectedNormal = pose.palmNormalOut - axis * simd_dot(pose.palmNormalOut, axis)
        let dl = simd_length(projectedDirection)
        let nl = simd_length(projectedNormal)
        guard dl > 1e-4, nl > 1e-4 else { return nil }
        return simd_dot(projectedNormal / nl, projectedDirection / dl)
    }
}
