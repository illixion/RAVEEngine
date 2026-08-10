/*
 RAVE Engine — a rolling window of numeric samples, and the reductions over it.

 Four apps grew four independent performance readouts with no shared code, and
 all four are the same thing underneath: *a named-key → numeric-sample store
 with a count/total/max or percentile reduction, refreshed on a windowed
 interval.* This is that store's arithmetic, alone and testable.

 The percentile formula is the one Longwave and Lambda independently arrived at
 (nearest-rank on a sorted copy, clamped to the last index). It is preserved
 exactly rather than "corrected" to a textbook interpolating percentile: the
 numbers these HUDs display have been read on-device for months, and quietly
 shifting them would invalidate that familiarity for no gain.
 */

import Foundation

/// A fixed-capacity rolling window of samples, oldest evicted first.
///
/// A `struct` with no isolation, so the same type serves a `@MainActor` HUD and
/// a render-thread collector. It stores `Double` regardless of what the caller
/// measures — milliseconds, bytes, degrees — because the reductions are the
/// same either way and the unit belongs to the label.
public struct RAVESampleSeries: Sendable, Equatable {
    /// Most recent last. Never longer than `capacity`.
    public private(set) var samples: [Double] = []
    public let capacity: Int

    /// Running max over every sample ever appended, not just the window.
    ///
    /// Kept separately because it is the one statistic a rolling window is
    /// actively bad at: the spike that matters is usually the one that has just
    /// scrolled off the end. `resetPeak()` clears it.
    public private(set) var peak: Double = 0

    /// How many samples have been appended in total, including evicted ones.
    public private(set) var totalCount: Int = 0

    public init(capacity: Int = 180) {
        self.capacity = Swift.max(1, capacity)
        samples.reserveCapacity(self.capacity)
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var count: Int { samples.count }
    public var latest: Double? { samples.last }

    public mutating func append(_ value: Double) {
        samples.append(value)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        peak = Swift.max(peak, value)
        totalCount += 1
    }

    public mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        totalCount = 0
    }

    /// Clear the all-time peak without disturbing the window.
    public mutating func resetPeak() {
        peak = samples.max() ?? 0
    }

    // MARK: Reductions

    public var mean: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// Mean over the most recent `n` samples — a headline number that settles
    /// enough to read without lagging behind what the user is feeling.
    public func mean(overLast n: Int) -> Double? {
        let recent = samples.suffix(Swift.max(1, n))
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }

    public var max: Double? { samples.max() }
    public var min: Double? { samples.min() }

    /// Nearest-rank percentile, `fraction` in 0…1.
    ///
    /// Sorts a copy on every call. That is deliberate: these windows are a few
    /// hundred samples and are reduced at most a few times a second, so an
    /// incrementally-maintained order statistic would be complexity bought with
    /// nothing.
    public func percentile(_ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = Swift.min(Swift.max(fraction, 0), 1)
        let index = Swift.min(Int(Double(sorted.count) * clamped), sorted.count - 1)
        return sorted[index]
    }

    public var median: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }
    /// The stutter, which an average never shows.
    public var p99: Double? { percentile(0.99) }

    /// Every reduction at once, from a single sort. Prefer this when building a
    /// snapshot — the individual accessors each sort again.
    public func reduced() -> RAVEMetricStat? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ fraction: Double) -> Double {
            sorted[Swift.min(Int(Double(sorted.count) * fraction), sorted.count - 1)]
        }
        return RAVEMetricStat(
            count: samples.count,
            mean: samples.reduce(0, +) / Double(samples.count),
            min: sorted[0],
            max: sorted[sorted.count - 1],
            p50: rank(0.5),
            p95: rank(0.95),
            p99: rank(0.99),
            peak: peak
        )
    }
}

/// One metric's reduced statistics.
///
/// **Structured numbers, never a pre-formatted string.** One app published
/// its performance meter as an already-formatted `String`, which meant nothing
/// downstream could re-style it, threshold-tint it, or graph it — the HUD could
/// only print what it was handed. Formatting is a presentation decision and
/// belongs in the view.
public struct RAVEMetricStat: Sendable, Equatable {
    public let count: Int
    public let mean: Double
    public let min: Double
    public let max: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double
    /// All-time maximum, including samples that have scrolled out of the window.
    public let peak: Double

    public init(
        count: Int,
        mean: Double,
        min: Double,
        max: Double,
        p50: Double,
        p95: Double,
        p99: Double,
        peak: Double
    ) {
        self.count = count
        self.mean = mean
        self.min = min
        self.max = max
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.peak = peak
    }

    /// Frames per second implied by a mean *period* in milliseconds.
    public var impliedRate: Double? {
        mean > 0 ? 1000 / mean : nil
    }
}
