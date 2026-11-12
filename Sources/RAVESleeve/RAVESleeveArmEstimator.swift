/*
 RAVE Engine — where the elbow is, when the tracker cannot be trusted to say.

 ARKit's elbow end of the forearm (`forearmArm`) is tracked on about a third
 of the frames with the arm held up, flickers in and out, and wanders while
 the other hand covers the forearm, still reported as tracked (Vision Pro,
 2026-11-12). A sleeve built straight on it is choppy and slides about under a
 pressing finger. The owner's call: do not trust that bone much; use it only
 when it looks stable, otherwise work the arm out from the hand, the way VR
 body rigs do (Boneworks is the model).

 So the elbow comes from a body model first:

 - the **shoulder** hangs off the head: a drop below the eyes, half a shoulder
   width to the arm's side, a little behind, on a torso heading that follows
   the head's yaw slowly (a glance does not turn the shoulders);
 - the **elbow** is the two-bone solve between that shoulder and the tracked
   wrist, with the elbow swung down and out to the side, where a relaxed arm
   carries it.

 Only the wrist's position and the head go in, and both are solid. The tracked
 elbow then corrects the model, by an offset that eases in once the bone has
 been tracked without a break, at a plausible length, and moving no faster
 against the wrist than an arm can, and eases back out when it stops being
 any of those. The elbow therefore never jumps between two sources.

 Framework-free: the host passes the arm it read (elbow nil when untracked)
 and gets the arm to use.
 */

import Foundation
import simd

public struct RAVESleeveArmEstimator: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// The shoulder, from the eye point: metres down, to the side and back.
        public var shoulderDrop: Float = 0.2
        public var shoulderHalfWidth: Float = 0.18
        public var shoulderBack: Float = 0.06
        public var upperArm: Float = 0.29
        /// The forearm's length until a stable bone has measured it.
        public var forearm: Float = 0.25
        /// How far the elbow swings out to the side rather than straight
        /// down: 0 hangs it under the arm, 1 is as much out as down.
        public var elbowOut: Float = 0.5
        /// Time constant of the torso following the head's yaw (s).
        public var torsoFollow: TimeInterval = 0.8

        /// The bone must be tracked this long without a break to be used.
        public var stableAfter: TimeInterval = 0.3
        /// Faster than this against the wrist (m/s) is tracking noise.
        public var maxElbowSpeed: Float = 2.5
        /// A bone this far (as a fraction) off the forearm's length is wrong.
        public var lengthTolerance: Float = 0.25
        /// Time constants of the correction easing in and out (s).
        public var blendIn: TimeInterval = 0.25
        public var blendOut: TimeInterval = 0.3

        public init() {}
    }

    public var tuning: Tuning

    /// Whether the tracked bone is being used this frame.
    public private(set) var isTrustingBone = false
    /// The forearm's length as measured so far.
    public private(set) var forearmLength: Float

    private var torso: SIMD3<Float>?
    private var correction = SIMD3<Float>(repeating: 0)
    private var trackedSince: TimeInterval?
    private var lastOffset: SIMD3<Float>?
    private var lastUpdate: TimeInterval?
    private var side: RAVESleeveSide?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
        forearmLength = tuning.forearm
    }

    public mutating func reset() {
        self = RAVESleeveArmEstimator(tuning: tuning)
    }

    /// The shoulder for a head at `head` on a torso heading `torso` (unit,
    /// horizontal).
    public static func shoulder(side: RAVESleeveSide, head: SIMD3<Float>, torso: SIMD3<Float>,
                                tuning: Tuning) -> SIMD3<Float> {
        let right = simd_normalize(simd_cross(torso, SIMD3(0, 1, 0)))
        return head - SIMD3(0, tuning.shoulderDrop, 0) - torso * tuning.shoulderBack
            + right * (side == .right ? tuning.shoulderHalfWidth : -tuning.shoulderHalfWidth)
    }

    /// The two-bone solve: the elbow between `shoulder` and `wrist` for the
    /// given bone lengths, swung toward `hint`. A wrist out of reach gets a
    /// straight arm.
    public static func elbow(shoulder: SIMD3<Float>, wrist: SIMD3<Float>, upperArm: Float, forearm: Float,
                             hint: SIMD3<Float>) -> SIMD3<Float> {
        let span = wrist - shoulder
        let reach = simd_length(span)
        guard reach > 1e-4 else { return shoulder + simd_normalize(hint) * upperArm }
        let axis = span / reach
        let d = min(max(reach, abs(upperArm - forearm) + 1e-3), upperArm + forearm - 1e-3)
        // Along the shoulder–wrist line to the foot of the elbow, and how far off it.
        let x = (upperArm * upperArm - forearm * forearm + d * d) / (2 * d)
        let r = max(0, upperArm * upperArm - x * x).squareRoot()
        var swing = hint - axis * simd_dot(hint, axis)
        if simd_length(swing) < 1e-4 {
            swing = simd_cross(axis, SIMD3(0, 0, 1))
            if simd_length(swing) < 1e-4 { swing = SIMD3(1, 0, 0) }
        }
        // Measured from the wrist, so the forearm keeps its length when the
        // reach was clamped.
        return wrist - axis * (d - x) + simd_normalize(swing) * r
    }

    /// One frame: the arm to use. `arm.elbow` is the tracked bone or nil;
    /// `head` is the eye point and `forward` the way the head faces.
    public mutating func resolve(_ arm: RAVESleeveArm, head: SIMD3<Float>, forward: SIMD3<Float>,
                                 now: TimeInterval) -> RAVESleeveArm {
        let dt = Float(lastUpdate.map { max(0, min(0.1, now - $0)) } ?? 0)
        lastUpdate = now
        if side != arm.side {
            side = arm.side
            correction = .zero
            trackedSince = nil
            lastOffset = nil
        }

        // The torso follows the head's yaw slowly; looking straight down or
        // up says nothing about it.
        let flat = SIMD3<Float>(forward.x, 0, forward.z)
        if simd_length(flat) > 0.3 {
            let heading = simd_normalize(flat)
            if let current = torso, tuning.torsoFollow > 0 {
                let mixed = current + (heading - current) * (1 - exp(-dt / Float(tuning.torsoFollow)))
                torso = simd_length(mixed) > 1e-3 ? simd_normalize(mixed) : heading
            } else {
                torso = heading
            }
        }
        let heading = torso ?? SIMD3(0, 0, -1)
        let right = simd_normalize(simd_cross(heading, SIMD3(0, 1, 0)))
        let shoulder = Self.shoulder(side: arm.side, head: head, torso: heading, tuning: tuning)
        let hint = SIMD3<Float>(0, -1, 0) + right * (arm.side == .right ? tuning.elbowOut : -tuning.elbowOut)
        let model = Self.elbow(shoulder: shoulder, wrist: arm.wrist, upperArm: tuning.upperArm,
                               forearm: forearmLength, hint: hint)

        // Does the tracked bone look stable?
        var stable = false
        if let tracked = arm.elbow {
            let offset = tracked - arm.wrist
            let length = simd_length(offset)
            var plausible = abs(length - forearmLength) <= forearmLength * tuning.lengthTolerance
            if let lastOffset, dt > 0, simd_distance(offset, lastOffset) / dt > tuning.maxElbowSpeed {
                plausible = false
            }
            lastOffset = offset
            if plausible {
                if trackedSince == nil { trackedSince = now }
                stable = now - (trackedSince ?? now) >= tuning.stableAfter
            } else {
                trackedSince = nil
            }
            if stable {
                // A stable bone also measures the forearm, slowly.
                forearmLength += (length - forearmLength) * min(1, dt * 0.5)
            }
        } else {
            trackedSince = nil
            lastOffset = nil
        }
        isTrustingBone = stable

        let target = stable ? (arm.elbow ?? model) - model : .zero
        let tau = Float(stable ? tuning.blendIn : tuning.blendOut)
        correction += (target - correction) * (tau > 0 ? 1 - exp(-dt / tau) : 1)

        var result = arm
        result.elbow = model + correction
        return result
    }
}
