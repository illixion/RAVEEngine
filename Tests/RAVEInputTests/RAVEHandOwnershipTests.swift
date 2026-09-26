import Foundation
import Testing
@testable import RAVEInput

private enum Gesture: Hashable, Sendable {
    case fire, reload, menu, swing
}

@Suite("Hand ownership")
struct RAVEHandOwnershipTests {

    @Test("A free hand is granted; the owner re-claiming is a no-op")
    func grantAndReclaim() {
        var hands = RAVEHandOwnership<Gesture>()
        #expect(hands.claim(.right, for: .fire, priority: 1, now: 0) == .granted)
        #expect(hands.claim(.right, for: .fire, priority: 1, now: 0.1) == .alreadyOwned)
        #expect(hands.owner(of: .right) == .fire)
        #expect(hands.owner(of: .left) == nil)
    }

    @Test("Equal or lower priority is denied while the hand is owned")
    func denied() {
        var hands = RAVEHandOwnership<Gesture>()
        hands.claim(.right, for: .menu, priority: 5, now: 0)
        #expect(hands.claim(.right, for: .fire, priority: 1, now: 0.1) == .denied(owner: .menu))
        #expect(hands.claim(.right, for: .reload, priority: 5, now: 0.1) == .denied(owner: .menu))
        #expect(!hands.canClaim(.right, for: .fire, priority: 1, now: 0.1))
        // The other hand is independent.
        #expect(hands.claim(.left, for: .fire, priority: 1, now: 0.1).isGranted)
    }

    @Test("Higher priority pre-empts, and the loser cannot release the winner's claim")
    func preempt() {
        var hands = RAVEHandOwnership<Gesture>()
        hands.claim(.right, for: .fire, priority: 1, now: 0)
        #expect(hands.claim(.right, for: .swing, priority: 10, now: 0.1) == .preempted(.fire))
        hands.release(.right, for: .fire, now: 0.2)
        #expect(hands.owner(of: .right) == .swing)
    }

    @Test("After a release, lower-priority gestures wait out the holdoff; higher ones do not")
    func holdoff() {
        var hands = RAVEHandOwnership<Gesture>(releaseHoldoff: 0.2)
        hands.claim(.right, for: .swing, priority: 5, now: 0)
        hands.release(.right, for: .swing, now: 1.0)
        if case .holdoff(let remaining) = hands.claim(.right, for: .fire, priority: 1, now: 1.05) {
            #expect(abs(remaining - 0.15) < 1e-9)
        } else {
            Issue.record("expected a holdoff")
        }
        #expect(hands.claim(.right, for: .menu, priority: 9, now: 1.05) == .granted)
        hands.release(.right, for: .menu, now: 1.06)
        // The releaser itself may come straight back.
        #expect(hands.claim(.right, for: .menu, priority: 9, now: 1.07) == .granted)
        hands.release(.right, for: .menu, now: 1.07)
        #expect(hands.claim(.right, for: .fire, priority: 1, now: 1.28) == .granted)
    }

    @Test("releaseAll and reset")
    func releaseAllAndReset() {
        var hands = RAVEHandOwnership<Gesture>(releaseHoldoff: 1)
        hands.claim(.left, for: .swing, priority: 5, now: 0)
        hands.claim(.right, for: .swing, priority: 5, now: 0)
        hands.releaseAll(for: .swing, now: 0.5)
        #expect(hands.owner(of: .left) == nil && hands.owner(of: .right) == nil)
        #expect(!hands.canClaim(.left, for: .fire, priority: 1, now: 0.6))
        hands.reset()
        #expect(hands.canClaim(.left, for: .fire, priority: 1, now: 0.6))
    }
}

private enum Surface: String, Hashable, Sendable {
    case world, hudWindow
}

/// Ported from Oneiros's `SystemPinchGateTests` along with the type.
@Suite("System pinch gate")
struct RAVESystemPinchGateTests {
    private typealias Gate = RAVESystemPinchGate<Surface>
    private let world = Gate.Token(source: .world, key: 1)
    private let hud = Gate.Token(source: .hudWindow, key: 7)

    @Test("Idle gate allows hand world actions")
    func idleAllows() {
        let g = Gate()
        #expect(g.allowsHandWorldAction(now: 10))
        #expect(!g.isActive(now: 10))
        #expect(g.graceRemaining(now: 10) == 0)
    }

    @Test("An active system pinch blocks, ending opens a grace window")
    func activeBlocksThenGrace() {
        var g = Gate()
        g.begin(hud, now: 1.0)
        #expect(g.isActive(now: 1.05))
        #expect(!g.allowsHandWorldAction(now: 1.05))
        g.end(hud, now: 1.20)
        #expect(!g.isActive(now: 1.21))
        #expect(!g.allowsHandWorldAction(now: 1.21))
        #expect(!g.allowsHandWorldAction(now: 1.20 + 0.29))
        #expect(g.allowsHandWorldAction(now: 1.20 + 0.30))
        #expect(abs(g.graceRemaining(now: 1.30) - 0.20) < 1e-9)
    }

    @Test("Overlapping pinches end when the last one ends")
    func overlappingTokens() {
        var g = Gate()
        g.begin(world, now: 0)
        g.begin(hud, now: 0.1)
        #expect(g.activeSources == [.world, .hudWindow])
        #expect(g.activeSourcesSorted == [.hudWindow, .world])
        g.end(world, now: 0.2)
        #expect(g.isActive(now: 0.25))
        #expect(g.activeCount == 1)
        #expect(g.activeSources == [.hudWindow])
        g.end(hud, now: 0.5)
        #expect(!g.isActive(now: 0.51))
        #expect(!g.allowsHandWorldAction(now: 0.79))
        #expect(g.allowsHandWorldAction(now: 0.80))
    }

    @Test("Ending an unknown token is a no-op and opens no grace")
    func unknownEndIsNoOp() {
        var g = Gate()
        g.end(hud, now: 5)
        #expect(g.allowsHandWorldAction(now: 5.01))
    }

    @Test("A begin that never ends expires and stamps the grace clock")
    func staleExpiry() {
        var g = Gate()
        g.begin(world, now: 0)
        #expect(g.isActive(now: 1.9))
        #expect(!g.isActive(now: 2.5))
        g.expireStale(now: 2.5)
        #expect(g.activeCount == 0)
        #expect(!g.allowsHandWorldAction(now: 2.6))
        #expect(g.allowsHandWorldAction(now: 2.81))
    }

    @Test("noteTap alone opens a grace window")
    func noteTapGrace() {
        var g = Gate()
        g.noteTap(now: 3.0)
        #expect(!g.isActive(now: 3.0))
        #expect(!g.allowsHandWorldAction(now: 3.1))
        #expect(g.allowsHandWorldAction(now: 3.31))
    }

    @Test("Hand-tracker timeline: a debounced rising edge during and shortly after a HUD press is refused")
    func arkitTimeline() {
        var g = Gate()
        g.begin(hud, now: 0)
        #expect(!g.allowsHandWorldAction(now: 0.10))
        g.end(hud, now: 0.18)
        #expect(!g.allowsHandWorldAction(now: 0.35))
        #expect(g.allowsHandWorldAction(now: 0.49))
    }

    @Test("isTracking reflects registered tokens; suppression stats record")
    func trackingAndStats() {
        var g = Gate()
        #expect(!g.isTracking(world))
        g.begin(world, now: 0)
        #expect(g.isTracking(world))
        g.recordSuppressed(finger: "middle", action: "breakBlock")
        #expect(g.suppressedCount == 1)
        #expect(g.lastSuppressedFinger == "middle")
        #expect(g.lastSuppressedAction == "breakBlock")
    }
}
