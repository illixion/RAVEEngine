/*
 RAVE Engine — spreading uneven pointer motion over the frames that follow it.

 visionOS hands `GCMouse` motion over at its own, lower and uneven, rate, so a
 mouse that moves steadily lands in a 90 Hz render as a delta on some frames
 and nothing on others, and a view or an aimed object moves in steps.
 `RAVEMotionSmoother` spreads each delta over the following frames through two
 first-order stages of τ/2 each — a critically damped response with a mean
 delay of τ — and conserves every count, so the total turn or aim is exactly
 what the mouse moved.

 `RAVEEventIntervalStats` measures an event stream's rate and jitter, for a
 diagnostics readout that says whether smoothing is what is needed.

 Value types with no isolation and no frameworks beyond `simd`, so they sit
 inside any input loop and run under `swift test`.
 */

import Foundation
import simd

/// Two cascaded first-order low-pass stages that conserve everything fed in.
public struct RAVEMotionSmoother: Sendable, Equatable {
    /// Mean delay in seconds; 0 passes motion straight through.
    public var timeConstant: Float

    private var stage1 = SIMD2<Float>(repeating: 0)
    private var stage2 = SIMD2<Float>(repeating: 0)

    public init(timeConstant: Float) {
        self.timeConstant = timeConstant
    }

    /// Motion still to come out, in the units fed in. For diagnostics.
    public var pending: SIMD2<Float> { stage1 + stage2 }

    /// Adds this frame's raw motion and returns what this frame should apply.
    public mutating func step(_ input: SIMD2<Float>, dt: Float) -> SIMD2<Float> {
        guard timeConstant > 0 else { return input + flush() }
        stage1 += input
        guard dt > 0, dt.isFinite else { return .zero }
        let k = 1 - expf(-dt / (timeConstant / 2))
        let first = stage1 * k
        stage1 -= first
        stage2 += first
        var out = stage2 * k
        stage2 -= out
        // Don't trickle the last hundredth of a count out for ever.
        if simd_length(stage1) + simd_length(stage2) < 1e-2 {
            out += stage1 + stage2
            stage1 = .zero
            stage2 = .zero
        }
        return out
    }

    /// Everything still held, at once (smoothing turned off).
    public mutating func flush() -> SIMD2<Float> {
        let rest = stage1 + stage2
        stage1 = .zero
        stage2 = .zero
        return rest
    }

    /// Drop what is held (a menu or console took the pointer).
    public mutating func reset() {
        stage1 = .zero
        stage2 = .zero
    }
}

/// Arrival times of an event stream over a recent window: rate, mean interval,
/// jitter (the intervals' standard deviation) and the worst gap.
public struct RAVEEventIntervalStats: Sendable, Equatable {
    public struct Summary: Sendable, Equatable {
        public var rateHz: Double
        public var meanIntervalMs: Double
        public var jitterMs: Double
        public var maxIntervalMs: Double
    }

    private var times: [Double] = []
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(2, capacity)
    }

    public mutating func record(_ time: Double) {
        times.append(time)
        if times.count > capacity { times.removeFirst(times.count - capacity) }
    }

    /// Over the events within `window` seconds of `now`; nil with fewer than two.
    public func summary(now: Double, window: Double = 1) -> Summary? {
        let recent = times.filter { now - $0 <= window && $0 <= now }
        guard recent.count >= 2 else { return nil }
        var intervals: [Double] = []
        intervals.reserveCapacity(recent.count - 1)
        for i in 1..<recent.count { intervals.append(recent[i] - recent[i - 1]) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)
        return Summary(
            rateHz: Double(recent.count) / window,
            meanIntervalMs: mean * 1000,
            jitterMs: variance.squareRoot() * 1000,
            maxIntervalMs: (intervals.max() ?? 0) * 1000)
    }
}
