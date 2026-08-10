import Foundation
import Testing
@testable import RAVEDiagnostics

@Suite("Sample series")
struct RAVESampleSeriesTests {

    @Test("An empty series reduces to nothing rather than zero")
    func emptyIsNil() {
        let series = RAVESampleSeries()
        #expect(series.mean == nil)
        #expect(series.max == nil)
        #expect(series.percentile(0.95) == nil)
        #expect(series.reduced() == nil)
    }

    @Test("The window evicts oldest first and never exceeds capacity")
    func rollingWindow() {
        var series = RAVESampleSeries(capacity: 3)
        for value in [1.0, 2, 3, 4, 5] { series.append(value) }
        #expect(series.samples == [3, 4, 5])
        #expect(series.count == 3)
        #expect(series.totalCount == 5)
    }

    @Test("The peak survives samples scrolling out of the window")
    func peakOutlivesWindow() {
        // The spike that matters is usually the one that has just scrolled off.
        var series = RAVESampleSeries(capacity: 3)
        series.append(99)
        for value in [1.0, 2, 3] { series.append(value) }
        #expect(series.max == 3)
        #expect(series.peak == 99)
        series.resetPeak()
        #expect(series.peak == 3)
    }

    @Test("Percentiles use nearest rank, clamped to the last index")
    func percentileFormula() {
        // The formula both Longwave and Lambda independently arrived at.
        var series = RAVESampleSeries(capacity: 100)
        for value in 1...100 { series.append(Double(value)) }
        #expect(series.percentile(0.5) == 51)
        #expect(series.percentile(0.95) == 96)
        #expect(series.percentile(0.99) == 100)
        // Out-of-range fractions clamp rather than trap.
        #expect(series.percentile(1.5) == 100)
        #expect(series.percentile(-1) == 1)
    }

    @Test("A single sample is every percentile of itself")
    func singleSample() {
        var series = RAVESampleSeries()
        series.append(7)
        #expect(series.p95 == 7)
        #expect(series.median == 7)
        #expect(series.mean == 7)
    }

    @Test("mean(overLast:) reads the recent tail, not the whole window")
    func recentMean() {
        var series = RAVESampleSeries(capacity: 100)
        for _ in 0..<50 { series.append(100) }
        for _ in 0..<10 { series.append(10) }
        #expect(series.mean(overLast: 10) == 10)
        #expect(series.mean! > 50)
    }

    @Test("reduced() agrees with the individual accessors")
    func reducedMatchesAccessors() throws {
        var series = RAVESampleSeries(capacity: 50)
        for value in [5.0, 1, 9, 3, 7, 2] { series.append(value) }
        let stat = try #require(series.reduced())
        #expect(stat.count == 6)
        #expect(stat.min == series.min)
        #expect(stat.max == series.max)
        #expect(stat.p50 == series.median)
        #expect(stat.p95 == series.p95)
        #expect(abs(stat.mean - series.mean!) < 1e-9)
    }

    @Test("A mean period converts to a rate")
    func impliedRate() throws {
        var series = RAVESampleSeries()
        for _ in 0..<10 { series.append(11.11) }
        let stat = try #require(series.reduced())
        #expect(abs(try #require(stat.impliedRate) - 90) < 0.1)
    }
}

@Suite("Metric collector")
struct RAVEMetricCollectorTests {

    @Test("Metrics keep their first-seen order so HUD rows do not reshuffle")
    func stableOrder() {
        let collector = RAVEMetricCollector()
        for key in ["wait0", "eyes", "angleGPU", "total"] { collector.record(key, 1) }
        #expect(collector.snapshot().order == ["wait0", "eyes", "angleGPU", "total"])
        // Recording again must not promote a key.
        collector.record("total", 2)
        #expect(collector.snapshot().order == ["wait0", "eyes", "angleGPU", "total"])
    }

    @Test("worstFirst ranks by spike, which an average-sorted list buries")
    func worstFirstRanksBySpike() {
        let collector = RAVEMetricCollector()
        for _ in 0..<10 { collector.record("steady", 10) }        // mean 10, max 10
        for _ in 0..<9 { collector.record("spiky", 1) }
        collector.record("spiky", 40)                              // mean ~5, max 40
        let worst = collector.snapshot().worstFirst()
        #expect(worst.first?.key == "spiky")
    }

    @Test("resetWindow clears samples but keeps keys and peaks")
    func resetWindowKeepsPeaks() throws {
        let collector = RAVEMetricCollector()
        collector.record("frame", 42)
        collector.resetWindow()
        #expect(collector.snapshot().isEmpty)
        collector.record("frame", 1)
        let stat = try #require(collector.stat(for: "frame"))
        #expect(stat.peak == 42)
        #expect(stat.max == 1)
    }

    @Test("Concurrent ingest from many threads loses nothing")
    func concurrentIngest() {
        // The reason this is a lock and not an actor: two of the four ingest
        // styles are synchronous calls on a render thread that cannot await.
        let collector = RAVEMetricCollector(capacity: 10_000)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for _ in 0..<250 { collector.record("frame", Double(worker)) }
        }
        #expect(collector.samples(for: "frame").count == 2000)
    }

    @Test("A duration is recorded from a start and end in seconds")
    func durationHelper() throws {
        let collector = RAVEMetricCollector()
        collector.record("section", secondsFrom: 10.0, to: 10.025)
        let stat = try #require(collector.stat(for: "section"))
        #expect(abs(stat.mean - 25) < 1e-6)
    }
}

@Suite("Feed gate")
struct RAVEFeedGateTests {

    @Test("Nothing has arrived: readings are refused and the reason says so")
    func neverStarted() {
        let gate = RAVEFeedGate(timeout: 1.5)
        #expect(!gate.hasEverReceived)
        #expect(!gate.isLive(now: 100))
        #expect(gate.status(now: 100) == .neverStarted)
        #expect(gate.gated(42, now: 100) == nil)
        #expect(gate.age(now: 100) == nil)
    }

    @Test("A recent update is live; a stale one is not")
    func livenessWindow() {
        var gate = RAVEFeedGate(timeout: 1.5)
        gate.markUpdated(at: 100)
        #expect(gate.isLive(now: 101))
        #expect(gate.gated(42, now: 101) == 42)

        // This is the bug it exists for: a frozen 33 fps that was minutes old.
        #expect(!gate.isLive(now: 102))
        #expect(gate.gated(42, now: 102) == nil)
    }

    @Test("Stopped and never-started are different faults with different words")
    func stoppedIsDistinctFromNeverStarted() {
        var gate = RAVEFeedGate(timeout: 1.5)
        gate.markUpdated(at: 100)
        guard case .stopped(let secondsAgo) = gate.status(now: 105) else {
            Issue.record("expected a stopped status")
            return
        }
        #expect(abs(secondsAgo - 5) < 1e-9)
    }

    @Test("A single late update inside the timeout does not blank the panel")
    func toleratesOneMissedUpdate() {
        // Sized as several missed updates of a 10 Hz feed, not one.
        var gate = RAVEFeedGate(timeout: 1.5)
        gate.markUpdated(at: 100)
        #expect(gate.isLive(now: 100.2))
        gate.markUpdated(at: 100.3)
        #expect(gate.isLive(now: 101.5))
    }
}

/// `onWindowClosed` is `@Sendable`, so a captured local `var` cannot be
/// mutated from it. This is the smallest thing that can collect the reports.
private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [RAVEMetricSnapshot] = []

    func append(_ snapshot: RAVEMetricSnapshot) {
        lock.lock(); defer { lock.unlock() }
        snapshots.append(snapshot)
    }

    var all: [RAVEMetricSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }

    var count: Int { all.count }
}

@Suite("Frame profiler")
struct RAVEFrameProfilerTests {

    @Test("An elapsed window reports only once its time is up")
    func elapsedWindow() {
        let profiler = RAVEFrameProfiler(
            subsystem: "test", window: .elapsed(seconds: 5), now: 0
        )
        let reports = ReportBox()
        profiler.onWindowClosed = { reports.append($0) }

        profiler.record("update", ms: 4)
        profiler.frameEnded(now: 1)
        #expect(reports.count == 0)

        profiler.frameEnded(now: 6)
        #expect(reports.count == 1)
        #expect(reports.all[0]["update"]?.mean == 4)

        // The window reset, so the next report needs another five seconds.
        profiler.record("update", ms: 8)
        profiler.frameEnded(now: 7)
        #expect(reports.count == 1)
    }

    @Test("A frame-count window reports every N frames")
    func frameCountWindow() {
        let profiler = RAVEFrameProfiler(subsystem: "test", window: .frames(count: 3), now: 0)
        let reports = ReportBox()
        profiler.onWindowClosed = { reports.append($0) }
        for frame in 1...7 {
            profiler.record("total", ms: 1)
            profiler.frameEnded(now: Double(frame))
        }
        #expect(reports.count == 2)
    }

    @Test("A manual window never reports on its own")
    func manualWindow() {
        let profiler = RAVEFrameProfiler(subsystem: "test", window: .manual, now: 0)
        let reports = ReportBox()
        profiler.onWindowClosed = { reports.append($0) }
        profiler.record("frame", ms: 1)
        for frame in 1...1000 { profiler.frameEnded(now: Double(frame)) }
        #expect(reports.count == 0)
        #expect(profiler.snapshot()["frame"]?.count == 1)
    }

    @Test("An empty window is not reported")
    func emptyWindowIsSilent() {
        let profiler = RAVEFrameProfiler(subsystem: "test", window: .elapsed(seconds: 1), now: 0)
        let reports = ReportBox()
        profiler.onWindowClosed = { reports.append($0) }
        profiler.frameEnded(now: 5)
        #expect(reports.count == 0)
    }

    @Test("measure records the section it wraps")
    func measureRecords() throws {
        let profiler = RAVEFrameProfiler(subsystem: "test", window: .manual)
        profiler.measure("work") { _ = (0..<1000).reduce(0, +) }
        let stat = try #require(profiler.snapshot()["work"])
        #expect(stat.count == 1)
        #expect(stat.mean >= 0)
    }

    @Test("Console lines are a convenience, not the data path")
    func consoleFormatting() {
        let collector = RAVEMetricCollector()
        collector.record("eyes", 2)
        collector.record("eyes", 4)
        let snapshot = collector.snapshot()
        #expect(snapshot.consoleLine() == "eyes av3.00 pk4.00")
        #expect(snapshot.percentileLine() == "eyes 4.0/4.0/4.0")
    }
}

@Suite("Memory probe")
struct RAVEMemoryProbeTests {

    @Test("The process footprint is readable and plausible")
    func footprint() throws {
        let footprint = try #require(RAVEMemoryProbe.processFootprint())
        #expect(footprint > 0)
    }

    @Test("Byte formatting matches what the monitors already displayed")
    func formatting() {
        #expect(RAVEMemoryProbe.format(3 * 1024 * 1024 * 1024).contains("GB"))
        #expect(RAVEMemoryProbe.format(512 * 1024 * 1024).contains("MB"))
        // Memory count style, so a GB is 1024³ — a decimal formatter would call
        // this 1.07 GB and the monitors have always shown 1 GB.
        #expect(RAVEMemoryProbe.format(1024 * 1024 * 1024).hasPrefix("1 GB"))
    }

    @Test("A gauge fraction needs both a reading and a ceiling")
    func gaugeFraction() throws {
        let reading = RAVEMemoryReading(gpuAllocated: 512 * 1024 * 1024)
        let fraction = try #require(reading.gpuFraction(of: 1024 * 1024 * 1024))
        #expect(abs(fraction - 0.5) < 1e-9)
        #expect(reading.gpuFraction(of: 0) == nil)
        #expect(RAVEMemoryReading().gpuFraction(of: 1024) == nil)
    }
}
