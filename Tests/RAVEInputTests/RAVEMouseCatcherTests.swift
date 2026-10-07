import Foundation
import Testing
@testable import RAVEInput

@Suite struct RAVEMouseCatcherRuleTests {
    private let base = RAVEMouseCatcherInputs(enabled: true, sceneActive: true, policy: .automatic,
                                              mouseConnected: true, mouseModeActive: false)

    private func wanted(_ change: (inout RAVEMouseCatcherInputs) -> Void) -> Bool {
        var i = base
        change(&i)
        return RAVEMouseCatcherRule.evaluate(i).wanted
    }

    @Test func automaticKeepsItUpWhileAMouseIsConnected() {
        #expect(wanted { _ in })
        // Whatever mode the last pinch picked: mouse events are what switch back.
        #expect(wanted { $0.mouseModeActive = false })
    }

    @Test func automaticKeepsItUpForAKeyboardAlone() {
        #expect(wanted { $0.mouseConnected = false; $0.mouseModeActive = true })
        #expect(!wanted { $0.mouseConnected = false })
    }

    @Test func forcedPolicies() {
        #expect(wanted { $0.policy = .mouseForced; $0.mouseConnected = false })
        #expect(!wanted { $0.policy = .otherForced })
    }

    @Test func gatesComeFirst() {
        #expect(!wanted { $0.enabled = false })
        #expect(!wanted { $0.sceneActive = false })
        var i = base
        i.blockedBy = "menu open"
        let d = RAVEMouseCatcherRule.evaluate(i)
        #expect(!d.wanted)
        #expect(d.reason == "menu open")
    }
}

@Suite struct RAVEEventRateTests {
    @Test func countsTheLastSecondInBuckets() {
        var r = RAVEEventRate()
        #expect(r.lastSecond(at: 0) == 0)
        // 10 events in each of the buckets 1.0 … 1.4 (mid-bucket times).
        for b in 0..<5 { r.record(at: 1.05 + Double(b) * 0.1, count: 10) }
        #expect(r.lastSecond(at: 1.55) == 50)
        #expect(r.lastSecond(at: 2.25) == 20)   // window 1.3 … 2.2
        #expect(r.lastSecond(at: 2.6) == 0)
    }

    @Test func survivesALongGapAndKeepsTheTotal() {
        var r = RAVEEventRate()
        r.record(at: 1)
        r.record(at: 100)
        #expect(r.lastSecond(at: 100.05) == 1)
        #expect(r.total == 2)
        #expect(r.lastAt == 100)
    }
}

@Suite struct RAVEMouseCatcherWatchTests {
    @Test func pointerMovingOnTheCatcherWithGCMouseSilent() {
        var w = RAVEMouseCatcherWatch()
        for k in 0..<6 { w.hoverMoved(at: 10 + Double(k) * 0.1) }
        #expect(w.check(now: 10.6, catcherOpen: true) == .pointerOnCatcherMouseSilent)
        // Throttled.
        for k in 0..<6 { w.hoverMoved(at: 11 + Double(k) * 0.1) }
        #expect(w.check(now: 11.6, catcherOpen: true) == nil)
    }

    @Test func noFindingWhileGCMouseFlows() {
        var w = RAVEMouseCatcherWatch()
        for k in 0..<6 {
            let t = 10 + Double(k) * 0.1
            w.hoverMoved(at: t)
            w.mouseEvent(at: t)
        }
        #expect(w.check(now: 10.6, catcherOpen: true) == nil)
    }

    @Test func pointerReachingTheLayer() {
        var w = RAVEMouseCatcherWatch()
        w.pointerPassed(at: 5)
        #expect(w.check(now: 5.2, catcherOpen: false) == nil)
        w.pointerPassed(at: 6)
        #expect(w.check(now: 6.2, catcherOpen: true) == .pointerPassedCatcher)
        #expect(w.check(now: 6.4, catcherOpen: true) == nil)
    }
}
