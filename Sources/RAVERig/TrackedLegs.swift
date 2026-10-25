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

        public struct Foot: Sendable, Equatable {
            public var ankle: SIMD3<Float>
            public var rotation: simd_quatf

            public init(ankle: SIMD3<Float>, rotation: simd_quatf) {
                self.ankle = ankle
                self.rotation = rotation
            }
        }

        public init(pelvis: SIMD3<Float>, pelvisRotation: simd_quatf, left: Foot?, right: Foot?, floor: Float) {
            self.pelvis = pelvis
            self.pelvisRotation = pelvisRotation
            self.left = left
            self.right = right
            self.floor = floor
        }
    }

    public var tuning = Tuning()
    /// How much of the legs the tracking decides now, 0 to 1.
    public private(set) var weight: Float = 0
    public private(set) var lowerBody: PerformerLowerBody?

    private struct FootState: Sendable {
        var last: Input.Foot?
        var shown: Input.Foot?
        var velocity = SIMD3<Float>.zero
        var lowest: Float?
        var planted = false
        var plantedAt = SIMD3<Float>.zero
        var lost: Float = 0
    }

    private var feet = [FootState(), FootState()]
    private var last: Input?

    public init() {}

    /// Takes this frame's tracking (nil when there is none) and returns the
    /// lower body to pose, or nil once faded out entirely.
    @discardableResult
    public mutating func update(_ input: Input?, deltaTime: Float) -> PerformerLowerBody? {
        let dt = max(deltaTime, 1e-4)
        if let input {
            weight = min(1, weight + (tuning.fadeIn > 0 ? dt / tuning.fadeIn : 1))
            last = input
        } else {
            weight = max(0, weight - (tuning.fadeOut > 0 ? dt / tuning.fadeOut : 1))
        }
        guard let frame = input ?? last, weight > 0 else {
            if weight <= 0 { reset() }
            return nil
        }
        // With no tracking at all the last frame is held, so its feet count as
        // seen again: still, and planted if they were.
        let left = step(&feet[0], input.map { $0.left } ?? feet[0].last, floor: frame.floor, dt: dt)
        let right = step(&feet[1], input.map { $0.right } ?? feet[1].last, floor: frame.floor, dt: dt)
        guard let left, let right else { return nil }
        let body = PerformerLowerBody(pelvis: frame.pelvis, pelvisRotation: frame.pelvisRotation, left: left,
                                      right: right, floor: frame.floor, weight: weight)
        lowerBody = body
        return body
    }

    public mutating func reset() {
        feet = [FootState(), FootState()]
        last = nil
        weight = 0
        lowerBody = nil
    }

    /// One foot's frame: tracked, held through a gap, or nil when it has
    /// never been seen.
    private func step(_ state: inout FootState, _ seen: Input.Foot?, floor: Float, dt: Float) -> PerformerFoot? {
        var foot: Input.Foot
        if let seen {
            if let previous = state.last, state.lost == 0 {
                let velocity = (seen.ankle - previous.ankle) / dt
                state.velocity += (velocity - state.velocity) * min(1, dt / 0.05)
            } else {
                state.velocity = .zero
            }
            state.last = seen
            state.lost = 0
            foot = seen
        } else {
            // Held where it was last shown; past `hold` it no longer counts
            // as planted, since nothing says it still is.
            state.lost += dt
            guard let held = state.shown ?? state.last else { return nil }
            return PerformerFoot(ankle: held.ankle, rotation: held.rotation,
                                 planted: state.planted && state.lost <= tuning.hold)
        }

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
        return PerformerFoot(ankle: foot.ankle, rotation: foot.rotation, planted: state.planted)
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
            PerformerFoot(ankle: simd_mix(p.ankle, q.ankle, SIMD3(repeating: t)), rotation: slerp(p.rotation, q.rotation),
                          planted: t < 0.5 ? p.planted : q.planted, toeBend: p.toeBend + (q.toeBend - p.toeBend) * t)
        }
        return PerformerLowerBody(pelvis: simd_mix(a.pelvis, b.pelvis, SIMD3(repeating: t)),
                                  pelvisRotation: slerp(a.pelvisRotation, b.pelvisRotation),
                                  left: foot(a.left, b.left), right: foot(a.right, b.right),
                                  floor: a.floor + (b.floor - a.floor) * t,
                                  weight: a.weight + (b.weight - a.weight) * t,
                                  armSwing: a.armSwing + (b.armSwing - a.armSwing) * t)
    }
}
