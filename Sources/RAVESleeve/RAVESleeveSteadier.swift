/*
 RAVE Engine — steadying a sleeve by degrees.

 ARKit's arm shakes at the source: more in poor light and dark sleeves, and
 more with the other hand over the forearm, which is exactly when the wearer
 is trying to press a tile (worn on a Vision Pro, 2026-11-12). The owner's
 call was against freezing the sleeve: steady it gradually instead, more as
 the other hand comes nearer, and while the arm is at rest.

 `RAVESleeveSteadier` turns those two into one number, `calm` (0…1), and the
 host uses it two ways:

 - the follower's filter is tuned between its ordinary setting and a slow,
   smooth one (`tuned(_:calmGain:)`), so a steadied sleeve drifts toward
   where the arm is reported rather than following every twitch;
 - once well steadied (`isOffAnchor`) the tiles are posed in the world, not
   through the system's wrist anchor, which carries the system's own reading
   of the shaking joint where no filter can reach it.

 Calm rises over a quarter of a second and falls in a tenth, so an arm that
 starts moving is followed again at once.
 */

import Foundation
import simd

public struct RAVESleeveSteadier: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// The other hand this near the forearm (m) is full calm, and it
        /// starts to count from `startsWithin`.
        public var fullWithin: Float = 0.08
        public var startsWithin: Float = 0.3
        /// How much calm an arm at rest gets, 0…1.
        public var atRest: Float = 0.7
        /// The wrist within `restNear` (m) of where it has lately been is at
        /// rest; beyond `restFar` it is moving.
        public var restNear: Float = 0.012
        public var restFar: Float = 0.04
        /// Time constant of "where it has lately been" (s).
        public var restFollow: TimeInterval = 0.5
        /// Time constants of calm coming on and going (s).
        public var rise: TimeInterval = 0.25
        public var fall: TimeInterval = 0.1
        /// The filter's rest cut-off at full calm, Hz.
        public var calmHz: Float = 0.4
        /// Above this the tiles leave the anchor; below `onAnchorBelow` they
        /// go back.
        public var offAnchorAbove: Float = 0.6
        public var onAnchorBelow: Float = 0.4

        public init() {}
    }

    public var tuning: Tuning

    /// How hard to steady the sleeve now, 0…1.
    public private(set) var calm: Float = 0
    /// Steadied enough that the tiles should be posed in the world.
    public private(set) var isOffAnchor = false

    private var restPoint: SIMD3<Float>?
    private var lastUpdate: TimeInterval?

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    public mutating func reset() {
        self = RAVESleeveSteadier(tuning: tuning)
    }

    /// 0 at or below `from`, 1 at or above `to`, eased between.
    static func ramp(_ value: Float, from: Float, to: Float) -> Float {
        let t = max(0, min(1, (value - from) / max(to - from, 1e-4)))
        return t * t * (3 - 2 * t)
    }

    /// One frame.
    /// - Parameters:
    ///   - frame: where the sleeve is shown (nil while it is not).
    ///   - otherHand: points of the other hand (its wrist and fingertips).
    ///   - wrist: the worn arm's wrist as tracked, before any filter.
    @discardableResult
    public mutating func update(frame: RAVESleeveFrame?, otherHand: [SIMD3<Float>], wrist: SIMD3<Float>?,
                                now: TimeInterval) -> Float {
        let dt = Float(lastUpdate.map { max(0, min(0.1, now - $0)) } ?? 0)
        lastUpdate = now

        var nearness: Float = 0
        if let frame {
            // The forearm, from the back of the hand to the far tiles.
            let a = frame.origin - frame.along * 0.06, b = frame.origin + frame.along * 0.22
            let closest = otherHand.map { point -> Float in
                let t = max(0, min(1, simd_dot(point - a, b - a) / simd_length_squared(b - a)))
                return simd_distance(point, a + (b - a) * t)
            }.min()
            if let closest {
                nearness = 1 - Self.ramp(closest, from: tuning.fullWithin, to: tuning.startsWithin)
            }
        }

        var resting: Float = 0
        if let wrist {
            // Against a slow follower of the wrist, so frame-to-frame jitter
            // does not read as movement.
            let follow = restPoint ?? wrist
            let point = follow + (wrist - follow) * (tuning.restFollow > 0 ? 1 - exp(-dt / Float(tuning.restFollow)) : 1)
            restPoint = point
            resting = (1 - Self.ramp(simd_distance(wrist, point), from: tuning.restNear, to: tuning.restFar))
                * tuning.atRest
        } else {
            restPoint = nil
        }

        let wanted = max(nearness, resting)
        let tau = Float(wanted > calm ? tuning.rise : tuning.fall)
        calm += (wanted - calm) * (tau > 0 ? 1 - exp(-dt / tau) : 1)
        if calm > tuning.offAnchorAbove { isOffAnchor = true } else if calm < tuning.onAnchorBelow { isOffAnchor = false }
        return calm
    }

    /// A filter tuning for the current calm: `ordinary` with none, and at
    /// full calm `calmHz` at rest with `calmGain` for speed.
    public func tuned(_ ordinary: RAVEOneEuroFilter.Tuning, calmGain: Float) -> RAVEOneEuroFilter.Tuning {
        RAVEOneEuroFilter.Tuning(minCutoff: ordinary.minCutoff + (tuning.calmHz - ordinary.minCutoff) * calm,
                                 beta: ordinary.beta + (calmGain - ordinary.beta) * calm,
                                 derivativeCutoff: ordinary.derivativeCutoff)
    }
}
