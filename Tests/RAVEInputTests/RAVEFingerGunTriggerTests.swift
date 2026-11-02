import Foundation
import Testing
@testable import RAVEInput

@Suite("Finger-gun trigger")
struct RAVEFingerGunTriggerTests {

    @Test("Curling the index pulls once, and extending it releases once")
    func pullsAndReleases() {
        var trigger = RAVEFingerGunTrigger()
        #expect(trigger.update(indexExtension: 0.9, allowed: true) == .steady)
        #expect(trigger.update(indexExtension: 0.4, allowed: true) == .began)
        #expect(trigger.isFiring)
        #expect(trigger.update(indexExtension: 0.3, allowed: true) == .steady)
        #expect(trigger.update(indexExtension: 0.9, allowed: true) == .ended)
        #expect(!trigger.isFiring)
    }

    @Test("Inside the band it holds whatever it was doing")
    func hysteresisBand() {
        var trigger = RAVEFingerGunTrigger()
        // Rising from open: stays released inside the band.
        #expect(trigger.update(indexExtension: 0.65, allowed: true) == .steady)
        #expect(!trigger.isFiring)
        _ = trigger.update(indexExtension: 0.4, allowed: true)
        // Falling from curled: stays pulled inside the band.
        #expect(trigger.update(indexExtension: 0.65, allowed: true) == .steady)
        #expect(trigger.isFiring)
    }

    @Test("Noise at a threshold does not chatter the button")
    func noRepeatedEdges() {
        var trigger = RAVEFingerGunTrigger()
        var edges = 0
        for value: Float in [0.56, 0.54, 0.56, 0.54, 0.58, 0.53, 0.6, 0.55] {
            if trigger.update(indexExtension: value, allowed: true) != .steady { edges += 1 }
        }
        #expect(edges == 1)
    }

    @Test("Anything else owning the hand releases at once")
    func disallowedReleases() {
        var trigger = RAVEFingerGunTrigger()
        _ = trigger.update(indexExtension: 0.3, allowed: true)
        #expect(trigger.update(indexExtension: 0.3, allowed: false) == .ended)
        #expect(!trigger.isFiring)
        // Still curled, still disallowed: nothing more to say.
        #expect(trigger.update(indexExtension: 0.3, allowed: false) == .steady)
    }

    @Test("A hand lost mid-pull releases rather than sticking")
    func lostHandReleases() {
        var trigger = RAVEFingerGunTrigger()
        _ = trigger.update(indexExtension: 0.3, allowed: true)
        #expect(trigger.update(indexExtension: nil, allowed: true) == .ended)
    }

    @Test("It pulls again after being let go while still curled, once allowed")
    func repullsWhenAllowedAgain() {
        var trigger = RAVEFingerGunTrigger()
        _ = trigger.update(indexExtension: 0.3, allowed: true)
        _ = trigger.update(indexExtension: 0.3, allowed: false)
        #expect(trigger.update(indexExtension: 0.3, allowed: true) == .began)
    }

    @Test("A custom tuning moves the thresholds")
    func customTuning() {
        var trigger = RAVEFingerGunTrigger()
        let tuning = RAVEFingerGunTrigger.Tuning(pullBelow: 0.3, releaseAbove: 0.5)
        #expect(trigger.update(indexExtension: 0.4, allowed: true, tuning: tuning) == .steady)
        #expect(trigger.update(indexExtension: 0.2, allowed: true, tuning: tuning) == .began)
        #expect(trigger.update(indexExtension: 0.45, allowed: true, tuning: tuning) == .steady)
        #expect(trigger.update(indexExtension: 0.6, allowed: true, tuning: tuning) == .ended)
    }

    @Test("Reset releases without an edge")
    func reset() {
        var trigger = RAVEFingerGunTrigger()
        _ = trigger.update(indexExtension: 0.3, allowed: true)
        trigger.reset()
        #expect(!trigger.isFiring)
    }
}
