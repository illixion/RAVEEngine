import Foundation
import simd

/// A `PerformerLowerBody` from trackers that see the legs: a camera body
/// tracker's hips and feet (RAVEInput's `RAVEBodyStreamSource`), or PC VR hip
/// and foot trackers.
///
/// `PerformerGait` makes the lower body up from the head; this one is
/// measured, so most of its job is what a measurement lacks:
///
/// - **Planted feet.** A tracker reports a standing foot with a millimetre or
///   two of jitter, and an avatar's foot shows every one of them as a shuffle
///   on the floor. A foot that is down and still is pinned where it landed
///   until it really moves (`releaseDrift`) or lifts, so it stands like a foot.
///   "Down" is measured against that foot's own lowest ankle height seen
///   lately, not a constant, since the ankle's height above the floor depends
///   on the person, their shoes and the tracker.
/// - **Gaps.** A foot the cameras lose for a moment (behind the other leg) is
///   held where it was; a lower body lost altogether is held and
///   faded out over `fadeOut`, so the legs ease back to whatever the host
///   blends under them (the gait, with `PerformerLowerBody.mix`) instead of
///   snapping.
///
/// Positions are in tracking space, Y up; rotations are RAVERig's frame
/// (+X left, +Y up, +Z forward), which is what the body stream sends.
public struct TrackedLegs: Sendable {

    public struct Tuning: Sendable, Equatable {
        /// A foot slower than this (m/s) and down plants; faster than
        /// `liftSpeed`, or lifted, it lets go.
        public var plantSpeed: Float = 0.25
        public var liftSpeed: Float = 0.5
        /// How far above its lowest an ankle may be and still be down.
        public var downHeight: Float = 0.03
        /// How quickly the remembered lowest ankle height creeps back up
        /// (m/s), so one deep reading does not keep the foot "up" for good.
        public var lowestRelax: Float = 0.01
        /// A planted foot whose tracker drifts this far from where it landed
        /// is re-planted there: it really moved (a pivot, a shuffle).
        public var releaseDrift: Float = 0.04
        /// Seconds a lost foot held where it was still counts as planted.
        public var hold: Float = 0.3
        /// Seconds to take over the legs when tracking starts, and to give them
        /// back when it stops.
        public var fadeIn: Float = 0.25
        public var fadeOut: Float = 0.4
        public var minConfidence: Float = 0.3

        public init() {}
    }

    /// One frame of tracking.
    public struct Input: Sendable, Equatable {
        public var pelvis: SIMD3<Float>
        public var pelvisRotation: simd_quatf
        /// Nil when this frame didn't see the foot.
        public var left: Foot?
        public var right: Foot?
        /// The floor's height in tracking space.
        public var floor: Float
        /// Capture time, not the time this sample was polled. Nil preserves
        /// the legacy one-measurement-per-update interface.
        public var capturedAt: Double?
        public var confidence: Float = 1

        public struct Foot: Sendable, Equatable {
            public var knee: SIMD3<Float>? = nil
            public var ankle: SIMD3<Float>
            public var rotation: simd_quatf
            public var confidence: Float

            public init(ankle: SIMD3<Float>, rotation: simd_quatf, confidence: Float = 1) {
                self.ankle = ankle
                self.rotation = rotation
                self.confidence = confidence
            }
        }

        public init(pelvis: SIMD3<Float>, pelvisRotation: simd_quatf, left: Foot?, right: Foot?, floor: Float,
                    capturedAt: Double? = nil, confidence: Float = 1) {
            self.pelvis = pelvis
            self.pelvisRotation = pelvisRotation
            self.left = left
            self.right = right
            self.floor = floor
            self.capturedAt = capturedAt
            self.confidence = confidence
        }
    }

    public var tuning = Tuning()
    /// How much of the legs the tracking decides now, 0 to 1.
    public private(set) var weight: Float = 0
    public private(set) var lowerBody: PerformerLowerBody?
    public var leftWeight: Float { feet[0].weight }
    public var rightWeight: Float { feet[1].weight }

    private struct FootState: Sendable {
        var last: Input.Foot?
        var shown: Input.Foot?
        var velocity = SIMD3<Float>.zero
        var lowest: Float?
        var planted = false
        var plantedAt = SIMD3<Float>.zero
        var lost: Float = 0
        var weight: Float = 0
        var sinceMeasurement: Float = 0
        var capturedAt: Double?
    }

    private var feet = [FootState(), FootState()]
    private var last: Input?
    private var lastCapture: Double?

    public init() {}

    /// Takes this frame's tracking (nil when there is none) and returns the
    /// lower body to pose, or nil once faded out entirely.
    @discardableResult
    public mutating func update(_ input: Input?, deltaTime: Float,
                                fallback: PerformerLowerBody? = nil) -> PerformerLowerBody? {
        let dt = max(deltaTime, 1e-4)
        let input = input.flatMap { $0.confidence >= tuning.minConfidence ? $0 : nil }
        let isNew = input != nil && (input?.capturedAt == nil || input?.capturedAt != lastCapture)
        if let input {
            weight = min(1, weight + (tuning.fadeIn > 0 ? dt / tuning.fadeIn : 1))
            last = input
            if isNew { lastCapture = input.capturedAt }
        } else {
            weight = max(0, weight - (tuning.fadeOut > 0 ? dt / tuning.fadeOut : 1))
        }
        guard let frame = input ?? last, weight > 0 else {
            if weight <= 0 { reset() }
            return nil
        }
        let left = step(&feet[0], input?.left, measured: isNew, capturedAt: input?.capturedAt, floor: frame.floor, dt: dt) ?? fallback?.left
        let right = step(&feet[1], input?.right, measured: isNew, capturedAt: input?.capturedAt, floor: frame.floor, dt: dt) ?? fallback?.right
        guard let left, let right else { lowerBody = nil; return nil }
        let body = PerformerLowerBody(pelvis: frame.pelvis, pelvisRotation: frame.pelvisRotation, left: left,
                                      right: right, floor: frame.floor, weight: weight)
        lowerBody = body
        guard let fallback else { return body }
        // A lost foot returns to the gait independently. The pelvis and the
        // other foot continue using measured motion.
        var mixed = PerformerLowerBody.mix(fallback, body, weight)
        mixed.left = PerformerLowerBody.mix(fallback, body, min(weight, leftWeight)).left
        mixed.right = PerformerLowerBody.mix(fallback, body, min(weight, rightWeight)).right
        mixed.weight = 1
        return mixed
    }

    public mutating func reset() {
        feet = [FootState(), FootState()]
        last = nil
        lastCapture = nil
        weight = 0
        lowerBody = nil
    }

    /// One foot's frame: tracked, held through a gap, or nil when it has
    /// never been seen.
    private func step(_ state: inout FootState, _ seen: Input.Foot?, measured: Bool, capturedAt: Double?, floor: Float, dt: Float) -> PerformerFoot? {
        state.sinceMeasurement += dt
        let seen = seen.flatMap { $0.confidence >= tuning.minConfidence ? $0 : nil }
        var foot: Input.Foot
        if let seen, measured {
            if let previous = state.last, state.lost <= tuning.hold {
                let measuredInterval = capturedAt.flatMap { current in state.capturedAt.map { Float(current - $0) } }
                let interval = max(measuredInterval ?? state.sinceMeasurement, 1e-4)
                let velocity = (seen.ankle - previous.ankle) / interval
                state.velocity += (velocity - state.velocity) * min(1, interval / 0.05)
            } else {
                state.velocity = .zero
                state.planted = false
                state.lowest = nil
            }
            state.sinceMeasurement = 0
            state.capturedAt = capturedAt
            state.last = seen
            state.lost = 0
            foot = seen
        } else {
            // Held where it was last shown; past `hold` it no longer counts
            // as planted, since nothing says it still is.
            state.lost += dt
            if state.lost > tuning.hold {
                state.weight = max(0, state.weight - (tuning.fadeOut > 0 ? dt / tuning.fadeOut : 1))
            } else if seen != nil {
                state.weight = min(1, state.weight + (tuning.fadeIn > 0 ? dt / tuning.fadeIn : 1))
            }
            guard let held = state.shown ?? state.last else { return nil }
            var foot = PerformerFoot(ankle: held.ankle, rotation: held.rotation,
                                     planted: state.planted && state.lost <= tuning.hold)
            foot.knee = held.knee
            return foot
        }

        state.weight = min(1, state.weight + (tuning.fadeIn > 0 ? dt / tuning.fadeIn : 1))

        let height = foot.ankle.y - floor
        let lowest = min(state.lowest.map { $0 + tuning.lowestRelax * dt } ?? height, height)
        state.lowest = lowest
        let down = height <= lowest + tuning.downHeight
        let speed = simd_length(state.velocity)
        if state.planted {
            if !down || speed > tuning.liftSpeed {
                state.planted = false
            } else if simd_distance(foot.ankle, state.plantedAt) > tuning.releaseDrift {
                state.plantedAt = foot.ankle
            }
        } else if down, speed < tuning.plantSpeed {
            state.planted = true
            state.plantedAt = foot.ankle
        }
        if state.planted { foot.ankle = state.plantedAt }
        state.shown = foot
        var result = PerformerFoot(ankle: foot.ankle, rotation: foot.rotation, planted: state.planted)
        result.knee = foot.knee
        return result
    }
}

extension PerformerLowerBody {
    /// `a` at 0, `b` at 1: for handing the legs between two sources (the gait
    /// and a tracker) without a snap. Positions and the floor blend linearly,
    /// rotations along the shorter arc; planting is `b`'s past halfway.
    public static func mix(_ a: PerformerLowerBody, _ b: PerformerLowerBody, _ t: Float) -> PerformerLowerBody {
        if t <= 0 { return a }
        if t >= 1 { return b }
        func slerp(_ p: simd_quatf, _ q: simd_quatf) -> simd_quatf {
            var to = q
            if simd_dot(p.vector, q.vector) < 0 { to = simd_quatf(vector: -q.vector) }
            return simd_slerp(p, to, t)
        }
        func foot(_ p: PerformerFoot, _ q: PerformerFoot) -> PerformerFoot {
            var result = PerformerFoot(ankle: simd_mix(p.ankle, q.ankle, SIMD3(repeating: t)), rotation: slerp(p.rotation, q.rotation),
                          planted: t < 0.5 ? p.planted : q.planted, toeBend: p.toeBend + (q.toeBend - p.toeBend) * t)
            if let a = p.knee, let b = q.knee {
                result.knee = a + (b - a) * t
                result.kneeWeight = p.kneeWeight + (q.kneeWeight - p.kneeWeight) * t
            } else if let knee = q.knee {
                result.knee = knee
                result.kneeWeight = q.kneeWeight * t
            } else if let knee = p.knee {
                result.knee = knee
                result.kneeWeight = p.kneeWeight * (1 - t)
            }
            return result
        }
        return PerformerLowerBody(pelvis: simd_mix(a.pelvis, b.pelvis, SIMD3(repeating: t)),
                                  pelvisRotation: slerp(a.pelvisRotation, b.pelvisRotation),
                                  left: foot(a.left, b.left), right: foot(a.right, b.right),
                                  floor: a.floor + (b.floor - a.floor) * t,
                                  weight: a.weight + (b.weight - a.weight) * t,
                                  armSwing: a.armSwing + (b.armSwing - a.armSwing) * t)
    }
}
