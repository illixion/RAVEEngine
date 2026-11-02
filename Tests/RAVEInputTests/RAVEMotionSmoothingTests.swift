import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Motion smoothing")
struct RAVEMotionSmoothingTests {
    private let frame: Float = 1.0 / 90

    @Test("Every count fed in comes out, in the end")
    func conservesTotal() {
        var smoother = RAVEMotionSmoother(timeConstant: 0.08)
        var total = SIMD2<Float>.zero
        total += smoother.step(SIMD2(10, -4), dt: frame)
        for _ in 0..<600 { total += smoother.step(.zero, dt: frame) }
        #expect(abs(total.x - 10) < 1e-3)
        #expect(abs(total.y + 4) < 1e-3)
        #expect(simd_length(smoother.pending) < 1e-6)
    }

    @Test("A delta is spread over later frames, not applied at once")
    func spreadsMotion() {
        var smoother = RAVEMotionSmoother(timeConstant: 0.08)
        let first = smoother.step(SIMD2(10, 0), dt: frame)
        #expect(first.x < 10)
        #expect(smoother.pending.x > 0)
        // Frame after frame it keeps arriving.
        let second = smoother.step(.zero, dt: frame)
        #expect(second.x > 0)
    }

    @Test("A zero time constant passes motion straight through")
    func zeroPassesThrough() {
        var smoother = RAVEMotionSmoother(timeConstant: 0)
        #expect(smoother.step(SIMD2(3, 2), dt: frame) == SIMD2(3, 2))
    }

    @Test("Turning smoothing off releases what was held")
    func zeroFlushesHeldMotion() {
        var smoother = RAVEMotionSmoother(timeConstant: 0.1)
        _ = smoother.step(SIMD2(8, 0), dt: frame)
        let held = smoother.pending.x
        smoother.timeConstant = 0
        let out = smoother.step(SIMD2(1, 0), dt: frame)
        #expect(abs(out.x - (1 + held)) < 1e-4)
        #expect(simd_length(smoother.pending) == 0)
    }

    @Test("A bad frame time applies nothing and loses nothing")
    func badDeltaTime() {
        var smoother = RAVEMotionSmoother(timeConstant: 0.08)
        #expect(smoother.step(SIMD2(5, 0), dt: 0) == .zero)
        #expect(smoother.step(.zero, dt: .nan) == .zero)
        #expect(abs(smoother.pending.x - 5) < 1e-6)
    }

    @Test("Reset drops what is held")
    func resetDrops() {
        var smoother = RAVEMotionSmoother(timeConstant: 0.08)
        _ = smoother.step(SIMD2(5, 5), dt: frame)
        smoother.reset()
        #expect(smoother.pending == .zero)
        #expect(smoother.step(.zero, dt: frame) == .zero)
    }

    @Test("A steady event stream reads as its rate with no jitter")
    func steadyStream() throws {
        var stats = RAVEEventIntervalStats()
        for i in 0..<60 { stats.record(Double(i) / 60) }
        let summary = try #require(stats.summary(now: 1))
        #expect(abs(summary.meanIntervalMs - 1000.0 / 60) < 0.01)
        #expect(summary.jitterMs < 0.01)
        #expect(abs(summary.maxIntervalMs - 1000.0 / 60) < 0.01)
    }

    @Test("Uneven arrivals show up as jitter and a long worst gap")
    func unevenStream() throws {
        var stats = RAVEEventIntervalStats()
        for t in [0.0, 0.01, 0.02, 0.12, 0.13, 0.14] { stats.record(t) }
        let summary = try #require(stats.summary(now: 0.2))
        #expect(summary.jitterMs > 10)
        #expect(abs(summary.maxIntervalMs - 100) < 0.01)
    }

    @Test("Fewer than two events in the window has no summary")
    func tooFewEvents() {
        var stats = RAVEEventIntervalStats()
        #expect(stats.summary(now: 1) == nil)
        stats.record(0.5)
        #expect(stats.summary(now: 1) == nil)
        stats.record(5)
        // Only the one at 5 is within a second of now = 5.2.
        #expect(stats.summary(now: 5.2) == nil)
    }

    @Test("History is capped")
    func capacityCaps() throws {
        var stats = RAVEEventIntervalStats(capacity: 10)
        for i in 0..<100 { stats.record(Double(i) * 0.001) }
        let summary = try #require(stats.summary(now: 1, window: 10))
        #expect(abs(summary.rateHz - 1) < 1e-9)   // 10 events over a 10 s window
    }
}
