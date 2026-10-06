import Foundation
import Testing
@testable import RAVEInput

@Suite struct RAVEMouseStepAccumulatorTests {
    @Test func carriesFractionsUntilAWholeStep() {
        var acc = RAVEMouseStepAccumulator()
        do { let r = acc.add(0.4); #expect(r == 0) }
        do { let r = acc.add(0.4); #expect(r == 0) }
        do { let r = acc.add(0.4); #expect(r == 1) }
        #expect(abs(acc.remainder - 0.2) < 1e-5)
    }

    @Test func handsOutSeveralStepsAtOnceAndKeepsTheSign() {
        var acc = RAVEMouseStepAccumulator()
        do { let r = acc.add(3.5); #expect(r == 3) }
        do { let r = acc.add(-1.0); #expect(r == 0) }   // 0.5 - 1.0 = -0.5: truncates toward zero
        do { let r = acc.add(-0.6); #expect(r == -1) }
        #expect(abs(acc.remainder + 0.1) < 1e-5)
    }

    @Test func resetDropsTheRemainder() {
        var acc = RAVEMouseStepAccumulator()
        _ = acc.add(0.9)
        acc.reset()
        do { let r = acc.add(0.2); #expect(r == 0) }
        #expect(abs(acc.remainder - 0.2) < 1e-5)
    }
}

@Suite struct RAVEMouseButtonGateTests {
    @Test func aDisallowedPressIsHeldBackAndSoIsItsRelease() {
        var gate = RAVEMouseButtonGate()
        do { let r = gate.press(.left, allowed: false); #expect(!r) }
        do { let r = gate.release(.left); #expect(!r) }
    }

    @Test func aForwardedPressIsAlwaysReleasedWhereverThePointerWent() {
        var gate = RAVEMouseButtonGate()
        do { let r = gate.press(.right, allowed: true); #expect(r) }
        // Pointer moved onto the app's controls: presses are held back now,
        // but the release of the forwarded one still goes through.
        do { let r = gate.press(.left, allowed: false); #expect(!r) }
        do { let r = gate.release(.right); #expect(r) }
        do { let r = gate.release(.right); #expect(!r) }
        #expect(gate.held.isEmpty)
    }

    @Test func aSecondPressOfAHeldButtonIsDropped() {
        var gate = RAVEMouseButtonGate()
        do { let r = gate.press(.middle, allowed: true); #expect(r) }
        do { let r = gate.press(.middle, allowed: true); #expect(!r) }
        do { let r = gate.release(.middle); #expect(r) }
        do { let r = gate.release(.middle); #expect(!r) }
    }

    @Test func releaseAllReturnsWhatWasDownAndClears() {
        var gate = RAVEMouseButtonGate()
        _ = gate.press(.left, allowed: true)
        _ = gate.press(.auxiliary(1), allowed: true)
        do { let r = gate.releaseAll(); #expect(Set(r) == [.left, .auxiliary(1)]) }
        #expect(gate.held.isEmpty)
        do { let r = gate.releaseAll(); #expect(r.isEmpty) }
    }
}

@Suite struct RAVEMouseMotionAccumulatorTests {
    @Test func takeReturnsTheSumAndZeroes() {
        let acc = RAVEMouseMotionAccumulator()
        acc.add(dx: 1.5, dy: -2)
        acc.add(dx: 0.5, dy: 1)
        let m = acc.take()
        #expect(m.dx == 2 && m.dy == -1)
        let again = acc.take()
        #expect(again.dx == 0 && again.dy == 0)
    }

    @Test func concurrentAddsAreNotLost() async {
        let acc = RAVEMouseMotionAccumulator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<1000 { acc.add(dx: 1, dy: -1) } }
            }
        }
        let m = acc.take()
        #expect(m.dx == 8000 && m.dy == -8000)
    }
}

@MainActor
private final class FakeBackend: RAVEMouseBackend {
    var starts = 0
    var stops = 0
    /// Mice "already connected" when the source starts.
    var preconnected: [(ObjectIdentifier, String?)] = []

    nonisolated init() {}

    func start(_ source: RAVEMouseSource) {
        starts += 1
        for (id, name) in preconnected { source.deviceConnected(id, vendorName: name) }
    }

    func stop() { stops += 1 }
}

private final class Token {}

@MainActor
@Suite struct RAVEMouseSourceTests {
    @Test func startsOnFirstSubscriberAndStopsOnLast() {
        let backend = FakeBackend()
        let source = RAVEMouseSource(backend: backend)
        let a = source.subscribe { _ in }
        let b = source.subscribe { _ in }
        #expect(backend.starts == 1)
        a.cancel()
        #expect(backend.stops == 0)
        b.cancel()
        b.cancel()
        #expect(backend.stops == 1)
        _ = source.subscribe { _ in }
        #expect(backend.starts == 2)
    }

    @Test func newSubscribersHearAboutMiceAlreadyConnected() {
        let backend = FakeBackend()
        let m1 = Token(), m2 = Token()
        backend.preconnected = [(ObjectIdentifier(m1), "One"), (ObjectIdentifier(m2), nil)]
        let source = RAVEMouseSource(backend: backend)
        var first: [RAVEMouseEvent] = []
        var second: [RAVEMouseEvent] = []
        let a = source.subscribe { first.append($0) }
        let b = source.subscribe { second.append($0) }
        let expected: [RAVEMouseEvent] = [.connected(vendorName: "One", count: 1),
                                          .connected(vendorName: nil, count: 2)]
        #expect(first == expected)
        #expect(second == expected)
        #expect(source.connectedCount == 2)
        #expect(source.isConnected)
        a.cancel(); b.cancel()
    }

    @Test func fansEventsOutAndTracksTheCount() {
        let source = RAVEMouseSource(backend: FakeBackend())
        let m = Token()
        var a: [RAVEMouseEvent] = []
        var b: [RAVEMouseEvent] = []
        let sa = source.subscribe { a.append($0) }
        let sb = source.subscribe { b.append($0) }
        source.deviceConnected(ObjectIdentifier(m), vendorName: "Mouse")
        source.deviceConnected(ObjectIdentifier(m), vendorName: "Mouse")   // duplicate: ignored
        source.emit(.button(.left, pressed: true))
        sb.cancel()
        source.emit(.moved(dx: 1, dy: 2))
        source.deviceDisconnected(ObjectIdentifier(Token()))               // unknown: ignored
        source.deviceDisconnected(ObjectIdentifier(m))
        #expect(a == [.connected(vendorName: "Mouse", count: 1),
                      .button(.left, pressed: true),
                      .moved(dx: 1, dy: 2),
                      .disconnected(vendorName: "Mouse", count: 0)])
        #expect(b == [.connected(vendorName: "Mouse", count: 1),
                      .button(.left, pressed: true)])
        #expect(!source.isConnected)
        sa.cancel()
    }

    @Test func stoppingForgetsTheDevices() {
        let source = RAVEMouseSource(backend: FakeBackend())
        let s = source.subscribe { _ in }
        source.deviceConnected(ObjectIdentifier(Token()), vendorName: nil)
        #expect(source.connectedCount == 1)
        s.cancel()
        #expect(source.connectedCount == 0)
    }

    @Test func aHandlerMayCancelItselfMidDelivery() {
        let source = RAVEMouseSource(backend: FakeBackend())
        var sub: RAVEMouseSubscription?
        var seen = 0
        var other = 0
        sub = source.subscribe { _ in seen += 1; sub?.cancel() }
        let o = source.subscribe { _ in other += 1 }
        source.emit(.scroll(x: 0, y: 1))
        source.emit(.scroll(x: 0, y: 1))
        #expect(seen == 1)
        #expect(other == 2)
        o.cancel()
    }
}
