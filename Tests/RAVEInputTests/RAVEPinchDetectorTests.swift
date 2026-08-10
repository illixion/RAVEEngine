import Testing
import simd
@testable import RAVEInput

/// A hand with every finger extended and the thumb parked away from all of
/// them, so a test can move exactly the one joint it cares about.
///
/// Fingertips are spaced 4 cm apart — wider than a real hand — so that placing
/// the thumb on one of them puts it unambiguously outside the 2.5 cm engage
/// radius of its neighbours. On a real hand two adjacent tips are close enough
/// that a middle-finger pinch genuinely does sit inside the index's radius, and
/// the detector is right to say so; that is not what these tests are measuring.
private func openHand(
    thumbTip: SIMD3<Float> = SIMD3(0.30, 0, 0),
    extensions: [RAVEHandFinger: Float] = [:]
) -> RAVEHandSample {
    func finger(_ f: RAVEHandFinger, at x: Float) -> RAVEFingerJoints {
        let reach = extensions[f] ?? 0.09   // comfortably past the 0.06 curl threshold
        return RAVEFingerJoints(
            tip: SIMD3(x, reach, 0),
            metacarpal: SIMD3(x, 0, 0),
            knuckle: SIMD3(x, reach * 0.35, 0)
        )
    }
    return RAVEHandSample(
        wrist: SIMD3(0, -0.05, 0),
        thumbTip: thumbTip,
        thumbKnuckle: SIMD3(0.05, 0, 0.03),
        index: finger(.index, at: 0),
        middle: finger(.middle, at: 0.04),
        ring: finger(.ring, at: 0.08),
        little: finger(.little, at: 0.12)
    )
}

/// Put the thumb tip exactly `distance` from the named fingertip.
private func hand(pinching finger: RAVEHandFinger, at distance: Float) -> RAVEHandSample {
    var sample = openHand()
    sample.thumbTip = sample[finger].tip + SIMD3(0, 0, distance)
    return sample
}

@Suite("Pinch engage and release")
struct PinchEngageTests {

    @Test("A pinch does not count until the debounce has elapsed")
    func debounceGatesHold() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let pinched = hand(pinching: .index, at: 0.01)

        // Frame 1 engages the state machine but nothing is held yet — the
        // original emitted on a *later* frame, and callers depend on that.
        var out = detector.update(sample: pinched, now: 0)
        #expect(out.held == nil)
        #expect(out.began == nil)

        // Still inside the 100 ms window.
        out = detector.update(sample: pinched, now: 0.05)
        #expect(out.held == nil)

        out = detector.update(sample: pinched, now: 0.10)
        #expect(out.held == .index)
        #expect(out.began == .index)
    }

    @Test("The rising edge fires exactly once")
    func risingEdgeIsNotRepeated() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let pinched = hand(pinching: .middle, at: 0.01)

        detector.update(sample: pinched, now: 0)
        #expect(detector.update(sample: pinched, now: 0.2).began == .middle)
        #expect(detector.update(sample: pinched, now: 0.3).began == nil)
        #expect(detector.update(sample: pinched, now: 0.4).held == .middle)
    }

    @Test("Held duration is measured from first contact, not from the edge")
    func heldDurationIncludesDebounce() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let pinched = hand(pinching: .index, at: 0.01)
        detector.update(sample: pinched, now: 1.0)
        let out = detector.update(sample: pinched, now: 1.5)
        #expect(abs(out.heldDuration - 0.5) < 1e-6)
    }

    @Test("engagesImmediately holds on the very first frame")
    func clutchEngagesWithoutDebounce() {
        var detector = RAVEPinchDetector(tuning: .clutch)
        let out = detector.update(sample: hand(pinching: .index, at: 0.01), now: 0)
        #expect(out.held == .index)
        #expect(out.began == .index)
        #expect(out.heldDuration == 0)
    }

    @Test("Hysteresis: a pinch survives past the engage threshold and releases only past exit")
    func hysteresisBand() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .index, at: 0.01), now: 0)
        detector.update(sample: hand(pinching: .index, at: 0.01), now: 0.2)

        // 3.5 cm is past engage (2.5) but short of release (4.5) — still held.
        #expect(detector.update(sample: hand(pinching: .index, at: 0.035), now: 0.3).held == .index)

        let released = detector.update(sample: hand(pinching: .index, at: 0.05), now: 0.4)
        #expect(released.held == nil)
        #expect(released.ended == .index)
    }
}

@Suite("Pinch suppression and hand-over")
struct PinchSuppressionTests {

    @Test("Three curled fingers suppress every pinch")
    func fistSuppressor() {
        var detector = RAVEPinchDetector(tuning: .standard)
        var fist = hand(pinching: .index, at: 0.005)
        for finger in [RAVEHandFinger.middle, .ring, .little] {
            fist[finger].tip = fist[finger].metacarpal + SIMD3(0, 0.03, 0)  // 3 cm < 6 cm curl
        }
        let out = detector.update(sample: fist, now: 0)
        #expect(out.isFist)
        #expect(out.curledFingerCount == 3)
        #expect(out.held == nil)
    }

    @Test("A fist releases a pinch that was already held, and reports the edge")
    func fistReleasesHeldPinch() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .index, at: 0.01), now: 0)
        #expect(detector.update(sample: hand(pinching: .index, at: 0.01), now: 0.2).held == .index)

        var fist = hand(pinching: .index, at: 0.005)
        for finger in [RAVEHandFinger.middle, .ring, .little] {
            fist[finger].tip = fist[finger].metacarpal + SIMD3(0, 0.03, 0)
        }
        let out = detector.update(sample: fist, now: 0.3)
        #expect(out.held == nil)
        #expect(out.ended == .index)
    }

    @Test("Shifting to a different finger mid-gesture drops the old pinch")
    func crossedFingersRelease() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0)
        #expect(detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0.2).held == .ring)

        // Ring is still inside the *exit* threshold, but middle is now inside
        // the *engage* threshold — the user meant to move.
        var shifted = openHand()
        shifted.thumbTip = shifted.middle.tip + SIMD3(0, 0, 0.01)
        let out = detector.update(sample: shifted, now: 0.3)
        #expect(out.held == nil)
        #expect(out.ended == .ring)
    }

    @Test("Losing tracking releases the hand")
    func lostTrackingReleases() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .little, at: 0.01), now: 0)
        #expect(detector.update(sample: hand(pinching: .little, at: 0.01), now: 0.2).held == .little)

        let out = detector.update(sample: nil, now: 0.3)
        #expect(out.held == nil)
        #expect(out.ended == .little)
    }

    @Test("A clutch tuning ignores fingers outside its candidate list")
    func candidateFingersRestrictPinching() {
        var detector = RAVEPinchDetector(tuning: .clutch)
        var sample = openHand()
        sample.thumbTip = sample.middle.tip + SIMD3(0, 0, 0.005)  // hard middle pinch
        let out = detector.update(sample: sample, now: 0)
        #expect(out.held == nil)
        #expect(out.nearestFinger == .index)
    }
}
