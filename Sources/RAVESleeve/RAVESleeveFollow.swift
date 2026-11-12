/*
 RAVE Engine — keeping a sleeve on the arm.

 The palm panels this replaces eased toward the hand with a fixed time
 constant, so a moving arm left its panel behind and the panel read as
 floating. A sleeve has to stay on the arm in motion and hold still at rest,
 which is what a one-euro filter does: a low cut-off while the joint is still
 (tracking jitter goes), a cut-off that rises with speed (no lag when the arm
 moves).

 `RAVESleeveFollower` filters the three things a frame is made of (wrist,
 elbow, outer-face direction), rebuilds the frame from them, and keeps the last
 good frame through a dropout or a pose that cannot be resolved, for a fade.
 Feed it poses predicted for the frame's presentation time where the host can
 get them; the filter takes out jitter, not latency.
 */

import Foundation
import simd

/// A one-euro filter over a vector: one cut-off for all three components,
/// from the speed of the whole vector.
public struct RAVEOneEuroFilter: Sendable, Equatable {
    public struct Tuning: Sendable, Equatable {
        /// Cut-off at rest, Hz. Lower is steadier and slower to settle.
        public var minCutoff: Float
        /// Hz of cut-off added per unit of speed (units of the value per second).
        public var beta: Float
        /// Cut-off of the speed estimate, Hz.
        public var derivativeCutoff: Float

        public init(minCutoff: Float, beta: Float, derivativeCutoff: Float = 1) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.derivativeCutoff = derivativeCutoff
        }

        /// A joint position in metres: 1.5 Hz at rest, about 30 Hz at half a
        /// metre a second.
        public static let position = Tuning(minCutoff: 1.5, beta: 60)
        /// A unit direction: speed is in radians a second for small turns.
        public static let direction = Tuning(minCutoff: 1.5, beta: 12)
    }

    public var tuning: Tuning
    public private(set) var value: SIMD3<Float>?
    private var derivative = SIMD3<Float>(repeating: 0)

    public init(tuning: Tuning) { self.tuning = tuning }

    public mutating func reset() {
        value = nil
        derivative = .zero
    }

    static func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * .pi * max(cutoff, 1e-3))
        return 1 / (1 + tau / dt)
    }

    /// Feed one sample `dt` seconds after the last; returns the filtered value.
    @discardableResult
    public mutating func step(_ sample: SIMD3<Float>, dt: Float) -> SIMD3<Float> {
        guard let previous = value, dt > 0, dt.isFinite else {
            value = sample
            return sample
        }
        let raw = (sample - previous) / dt
        derivative += (raw - derivative) * Self.alpha(cutoff: tuning.derivativeCutoff, dt: dt)
        let cutoff = tuning.minCutoff + tuning.beta * simd_length(derivative)
        let next = previous + (sample - previous) * Self.alpha(cutoff: cutoff, dt: dt)
        value = next
        return next
    }
}

/// Follows an arm: the filtered frame, and whether it is live.
public struct RAVESleeveFollower: Sendable {
    public var position: RAVEOneEuroFilter.Tuning {
        didSet { wrist.tuning = position; elbow.tuning = position }
    }
    public var direction: RAVEOneEuroFilter.Tuning {
        didSet { back.tuning = direction }
    }
    /// A gap longer than this starts the filters afresh, so a sleeve appears
    /// on the arm rather than sweeping in from where the arm last was.
    public var resetAfter: TimeInterval = 0.5

    /// The last frame that resolved. Kept through a dropout.
    public private(set) var frame: RAVESleeveFrame?
    /// Whether `frame` came from this update's joints.
    public private(set) var isTracked = false

    private var wrist: RAVEOneEuroFilter
    private var elbow: RAVEOneEuroFilter
    private var back: RAVEOneEuroFilter
    private var lastUpdate: TimeInterval?
    private var lastTracked: TimeInterval?

    public init(position: RAVEOneEuroFilter.Tuning = .position,
                direction: RAVEOneEuroFilter.Tuning = .direction) {
        self.position = position
        self.direction = direction
        wrist = RAVEOneEuroFilter(tuning: position)
        elbow = RAVEOneEuroFilter(tuning: position)
        back = RAVEOneEuroFilter(tuning: direction)
    }

    public mutating func reset() {
        wrist.reset(); elbow.reset(); back.reset()
        frame = nil
        isTracked = false
        lastUpdate = nil
        lastTracked = nil
    }

    /// One frame. `arm` nil when the hand is not tracked.
    @discardableResult
    public mutating func update(arm: RAVESleeveArm?, now: TimeInterval) -> RAVESleeveFrame? {
        let dt = Float(lastUpdate.map { max(0, now - $0) } ?? 0)
        lastUpdate = now
        guard let arm, let raw = RAVESleeveFrame(arm: arm) else {
            isTracked = false
            return frame
        }
        if let lastTracked, now - lastTracked > resetAfter || frame?.side != arm.side {
            wrist.reset(); elbow.reset(); back.reset()
        }
        lastTracked = now

        let origin = wrist.step(raw.origin, dt: dt)
        // The elbow point is filtered even when estimated, so the axis does
        // not jump as the elbow joint comes and goes.
        let far = elbow.step(raw.origin + raw.along * raw.length, dt: dt)
        let smoothedBack = back.step(raw.back, dt: dt)
        let span = far - origin
        guard simd_length(span) > 1e-3,
              let outer = RAVESleeveFrame.perpendicular(smoothedBack, to: simd_normalize(span)) else {
            frame = raw
            isTracked = true
            return raw
        }
        let result = RAVESleeveFrame(side: raw.side, origin: origin, along: simd_normalize(span), back: outer,
                                     twist: raw.twist, length: simd_length(span), isEstimated: raw.isEstimated)
        frame = result
        isTracked = true
        return result
    }
}
