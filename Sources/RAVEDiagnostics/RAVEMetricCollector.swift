/*
 RAVE Engine — the metric collector, and why it is lock-guarded rather than an actor.

 Four ingest styles have to reach this type, and they are not negotiable:

   - manual `record()` from a render loop        (Spatialcraft, Lambda)
   - a `CADisplayLink` callback                  (Longwave, Moonlight)
   - a `Task`-sleep poll                         (Spatial Stash)
   - inbound network packets at 10 Hz            (Longwave, PCVR)

 Two of those are synchronous calls on a render thread that cannot await
 anything — Lambda's already reaches for an `NSLock` for exactly this reason.
 So the collector is a plain class with a lock, `@unchecked Sendable`, and its
 ingest path is non-blocking-ish and cheap: append to an array under a lock.
 An actor would have made `record()` async and unusable from the callers that
 need it most.

 Reading is a separate act. `snapshot()` reduces everything under one lock
 acquisition and hands back a `Sendable` value type, so a `@MainActor` view can
 hold it without touching the collector again.
 */

import Foundation

/// Thread-safe named-metric store. One per subsystem being profiled.
public final class RAVEMetricCollector: @unchecked Sendable {

    /// How many samples each metric retains. 180 at 90 Hz is two seconds of
    /// frames, which is about as far back as a live readout is worth plotting.
    public let capacity: Int

    private let lock = NSLock()
    private var series: [String: RAVESampleSeries] = [:]
    /// Insertion order, so a HUD's rows do not reshuffle between refreshes.
    /// Dictionary iteration order is unspecified and *does* vary run to run.
    private var order: [String] = []

    public init(capacity: Int = 180) {
        self.capacity = capacity
    }

    // MARK: Ingest

    /// Record one sample. Safe from any thread, including a render thread that
    /// cannot suspend.
    public func record(_ key: String, _ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        if series[key] == nil {
            series[key] = RAVESampleSeries(capacity: capacity)
            order.append(key)
        }
        series[key]?.append(value)
    }

    /// Record a duration in milliseconds, given a start and end in seconds.
    public func record(_ key: String, secondsFrom start: Double, to end: Double) {
        record(key, (end - start) * 1000)
    }

    // MARK: Read

    /// Reduce every metric. One lock acquisition, one sort per metric.
    public func snapshot() -> RAVEMetricSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var stats: [String: RAVEMetricStat] = [:]
        var keys: [String] = []
        for key in order {
            guard let stat = series[key]?.reduced() else { continue }
            stats[key] = stat
            keys.append(key)
        }
        return RAVEMetricSnapshot(order: keys, stats: stats)
    }

    /// The raw window for one metric — what a graph plots, as opposed to what a
    /// stat row summarises.
    public func samples(for key: String) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return series[key]?.samples ?? []
    }

    public func stat(for key: String) -> RAVEMetricStat? {
        lock.lock()
        defer { lock.unlock() }
        return series[key]?.reduced()
    }

    // MARK: Window management

    /// Drop every sample, keeping the metric keys and their display order.
    ///
    /// This is what a periodic-dump profiler calls at the end of each window.
    /// All-time peaks survive, since a peak that only counts within the window
    /// it happened in is not a peak.
    public func resetWindow() {
        lock.lock()
        defer { lock.unlock() }
        for key in order {
            series[key]?.removeAll()
        }
    }

    /// Forget everything, keys included.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        series.removeAll()
        order.removeAll()
    }

    public func resetPeaks() {
        lock.lock()
        defer { lock.unlock() }
        for key in order {
            series[key]?.resetPeak()
        }
    }
}

/// An immutable reduction of every metric at one instant.
public struct RAVEMetricSnapshot: Sendable, Equatable {
    /// Metric keys in the order they were first recorded, so HUD rows are stable.
    public let order: [String]
    public let stats: [String: RAVEMetricStat]

    public init(order: [String] = [], stats: [String: RAVEMetricStat] = [:]) {
        self.order = order
        self.stats = stats
    }

    public var isEmpty: Bool { order.isEmpty }

    public subscript(key: String) -> RAVEMetricStat? { stats[key] }

    /// Metrics ordered by how badly they spiked — the column that actually
    /// matters. A healthy mean with a bad max is a subsystem stalling
    /// intermittently, which an average-sorted list buries.
    public func worstFirst(limit: Int = 8) -> [(key: String, stat: RAVEMetricStat)] {
        order
            .compactMap { key in stats[key].map { (key: key, stat: $0) } }
            .sorted { $0.stat.max > $1.stat.max }
            .prefix(limit)
            .map { $0 }
    }
}
