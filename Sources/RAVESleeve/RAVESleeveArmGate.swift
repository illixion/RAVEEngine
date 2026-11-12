/*
 RAVE Engine — dropping the readings of an arm that cannot be true.

 ARKit's forearm is steady most of the time, the elbow end included (worn on a
 Vision Pro, 2026-11-12: with the other hand at the forearm the tracked bone
 held still on a wireframe while a body-model guess of the elbow wandered).
 What does go wrong is a moment of tracking loss: a joint reported somewhere
 it could not have got to in one frame. The owner's call: use the bone, and
 filter out the extreme updates.

 `RAVESleeveArmGate` does that and nothing else. Each part of the arm (the
 wrist, the elbow relative to the wrist, the way the palm faces) is compared
 with the last reading that was accepted; one that has moved faster than an
 arm can is dropped and the accepted one stands. If the readings keep
 disagreeing for `holdFor`, the arm really is somewhere else and the new
 reading is taken; the follower then eases to it.

 It does not smooth: that is `RAVESleeveFollower`'s job, after this.
 */

import Foundation
import RAVEInput
import simd

public struct RAVESleeveArmGate: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Fastest the wrist is believed to move, m/s. A hard swing of the
        /// arm reaches about 5.
        public var maxWristSpeed: Float = 6
        /// Fastest the elbow moves against the wrist, m/s.
        public var maxElbowSpeed: Float = 4
        /// Fastest the palm turns, radians/s.
        public var maxTurnSpeed: Float = 25
        /// How long readings may be dropped before the new place is believed.
        public var holdFor: TimeInterval = 0.3

        public init() {}
    }

    public var tuning: Tuning

    /// How many readings (of any part) have been dropped. For diagnostics.
    public private(set) var dropped = 0

    private struct Part {
        var value: SIMD3<Float>
        var acceptedAt: TimeInterval
    }

    private var side: RAVESleeveSide?
    private var wrist: Part?
    private var elbow: Part?
    private var normal: Part?
    private var fingers: Part?
    private var lastUpdate: TimeInterval?

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    public mutating func reset() {
        self = RAVESleeveArmGate(tuning: tuning)
    }

    /// Takes `sample` unless it moved faster than `limit` (per second) since
    /// the accepted value, measured by `distance`. Returns what stands and
    /// whether the sample was dropped.
    private static func gate(_ part: inout Part?, _ sample: SIMD3<Float>, limit: Float, dt: Float,
                             now: TimeInterval, holdFor: TimeInterval,
                             distance: (SIMD3<Float>, SIMD3<Float>) -> Float) -> (SIMD3<Float>, Bool) {
        guard let held = part, dt > 0 else {
            part = Part(value: sample, acceptedAt: now)
            return (sample, false)
        }
        // The allowance grows with the time since the accepted reading, so a
        // real move is caught up with as soon as it is within reach.
        let elapsed = Float(now - held.acceptedAt)
        if distance(sample, held.value) <= limit * max(elapsed, dt) || now - held.acceptedAt >= holdFor {
            part = Part(value: sample, acceptedAt: now)
            return (sample, false)
        }
        return (held.value, true)
    }

    /// One frame: the arm with any reading that could not be true replaced
    /// by the last one that could.
    public mutating func filter(_ arm: RAVESleeveArm, now: TimeInterval) -> RAVESleeveArm {
        let dt = Float(lastUpdate.map { max(0, now - $0) } ?? 0)
        lastUpdate = now
        if side != arm.side || dt > Float(tuning.holdFor) {
            side = arm.side
            wrist = nil; elbow = nil; normal = nil; fingers = nil
        }
        func turn(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
        }
        var result = arm
        var drops = 0
        func take(_ part: inout Part?, _ sample: SIMD3<Float>, _ limit: Float,
                  _ distance: (SIMD3<Float>, SIMD3<Float>) -> Float) -> SIMD3<Float> {
            let (value, wasDropped) = Self.gate(&part, sample, limit: limit, dt: dt, now: now,
                                                holdFor: tuning.holdFor, distance: distance)
            if wasDropped { drops += 1 }
            return value
        }
        var wristPart = wrist, elbowPart = elbow, normalPart = normal, fingersPart = fingers
        result.wrist = take(&wristPart, arm.wrist, tuning.maxWristSpeed, simd_distance)
        if let tracked = arm.elbow {
            result.elbow = result.wrist + take(&elbowPart, tracked - arm.wrist, tuning.maxElbowSpeed, simd_distance)
        } else {
            elbowPart = nil
        }
        let palmNormal = take(&normalPart, arm.palm.palmNormalOut, tuning.maxTurnSpeed, turn)
        let palmFingers = take(&fingersPart, arm.palm.fingersDirection, tuning.maxTurnSpeed, turn)
        wrist = wristPart; elbow = elbowPart; normal = normalPart; fingers = fingersPart
        dropped += drops
        result.palm = RAVEPalmPose(position: arm.palm.position + (result.wrist - arm.wrist),
                                   palmNormalOut: palmNormal, fingersDirection: palmFingers)
        return result
    }
}
