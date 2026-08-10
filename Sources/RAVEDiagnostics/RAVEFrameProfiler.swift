/*
 RAVE Engine — per-frame section profiling: signposts for Instruments, and an
 in-app readout for when Instruments isn't attached.

 Both games grew this independently. One wraps named sections in
 `measure { }` and prints an avg/peak line every 5 s; Lambda accumulates
 per-column samples from its render thread and prints p50/p95/max every 512
 frames. Same idea, two windowing rules — so both windowing rules are here, as
 a choice rather than a fork.

 Overhead when idle is a few nanoseconds per section, which is why both apps
 leave it compiled into release builds.
 */

import Foundation
import QuartzCore
import os

/// When a profiler should reduce and report.
public enum RAVEProfilerWindow: Sendable, Equatable {
    /// Report every `seconds` of wall clock.
    case elapsed(seconds: Double)
    /// Report every `count` frames. Lambda's rule — steadier under a variable
    /// frame rate, because each report covers the same amount of *work*.
    case frames(count: Int)
    /// Never report on its own; the owner pulls snapshots when it wants them.
    /// What a live HUD wants, since the view's own refresh is the clock.
    case manual
}

/// Signpost + in-app statistics for a per-frame loop.
///
/// Not isolated: one consumer drives it from the main actor, Lambda from a
/// render thread, and the underlying collector is lock-guarded precisely so
/// neither has to change.
public final class RAVEFrameProfiler: @unchecked Sendable {

    public let collector: RAVEMetricCollector
    public let signposter: OSSignposter
    public var window: RAVEProfilerWindow

    /// Called when a window closes, with the reduction for that window. Set
    /// this to print, log, or publish. Nil means "collect but say nothing",
    /// which is what a live HUD wants.
    public var onWindowClosed: (@Sendable (RAVEMetricSnapshot) -> Void)?

    private let lock = NSLock()
    private var windowStart: Double
    private var framesThisWindow = 0

    public init(
        subsystem: String,
        category: String = "Frame",
        window: RAVEProfilerWindow = .elapsed(seconds: 5),
        capacity: Int = 512,
        now: Double = CACurrentMediaTime()
    ) {
        self.collector = RAVEMetricCollector(capacity: capacity)
        self.signposter = OSSignposter(subsystem: subsystem, category: category)
        self.window = window
        self.windowStart = now
    }

    // MARK: Measuring

    /// Wrap a section of the frame in a named signpost interval plus a sample.
    ///
    /// `StaticString` for the name because that is what `OSSignposter` requires
    /// for an interval name — it must outlive the call.
    @inline(__always)
    public func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = CACurrentMediaTime()
        defer {
            signposter.endInterval(name, state)
            collector.record("\(name)", (CACurrentMediaTime() - start) * 1000)
        }
        return try body()
    }

    /// Record a section measured elsewhere, in milliseconds.
    public func record(_ key: String, ms: Double) {
        collector.record(key, ms)
    }

    /// Call once per frame. Closes and reports the window when it is due.
    public func frameEnded(now: Double = CACurrentMediaTime()) {
        lock.lock()
        framesThisWindow += 1
        let due: Bool
        switch window {
        case .elapsed(let seconds): due = now - windowStart >= seconds
        case .frames(let count):    due = framesThisWindow >= count
        case .manual:               due = false
        }
        if due {
            windowStart = now
            framesThisWindow = 0
        }
        lock.unlock()

        guard due, let report = onWindowClosed else { return }
        let snapshot = collector.snapshot()
        guard !snapshot.isEmpty else { return }
        report(snapshot)
        collector.resetWindow()
    }

    /// The current reduction, without waiting for the window to close.
    public func snapshot() -> RAVEMetricSnapshot { collector.snapshot() }
}

public extension RAVEMetricSnapshot {
    /// A one-line `key av1.23 pk4.56` summary, worst-spiking first.
    ///
    /// A convenience for console dumps only. A view should read the numbers and
    /// lay them out itself — that is the whole reason this type carries
    /// structured values instead of a string.
    func consoleLine(limit: Int = 8) -> String {
        worstFirst(limit: limit)
            .map { String(format: "%@ av%.2f pk%.2f", $0.key, $0.stat.mean, $0.stat.max) }
            .joined(separator: " | ")
    }

    /// A one-line `key p50/p95/max` summary — the shape a latency column wants,
    /// where the tail is the story and the mean hides it.
    func percentileLine(limit: Int = 8, keys: [String]? = nil) -> String {
        let selected: [(key: String, stat: RAVEMetricStat)] = keys.map { requested in
            requested.compactMap { key in stats[key].map { (key: key, stat: $0) } }
        } ?? worstFirst(limit: limit)
        return selected
            .map { String(format: "%@ %.1f/%.1f/%.1f", $0.key, $0.stat.p50, $0.stat.p95, $0.stat.max) }
            .joined(separator: " ")
    }
}
