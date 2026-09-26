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

    @Test("Shifting to a different finger re-targets only after the switch hold")
    func crossedFingersRetarget() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0)
        #expect(detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0.2).held == .ring)

        // Ring is still inside the *exit* threshold, but middle is now inside
        // the *engage* threshold and clearly nearer. The held pinch survives
        // until the switch has persisted for `fingerSwitchHold`.
        var shifted = openHand()
        shifted.thumbTip = shifted.middle.tip + SIMD3(0, 0, 0.01)
        var out = detector.update(sample: shifted, now: 0.3)
        #expect(out.held == .ring)
        #expect(out.ended == nil)

        out = detector.update(sample: shifted, now: 0.4)
        #expect(out.held == .middle)
        #expect(out.ended == .ring)
        #expect(out.began == .middle)
    }

    @Test("A one-frame brush of another finger does not drop the held pinch")
    func briefCrossKeepsHeld() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0)
        detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0.2)
        var shifted = openHand()
        shifted.thumbTip = shifted.middle.tip + SIMD3(0, 0, 0.01)
        #expect(detector.update(sample: shifted, now: 0.21).held == .ring)
        let back = detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0.22)
        #expect(back.held == .ring)
        #expect(back.ended == nil && back.began == nil)
        // The challenge restarts from scratch next time.
        #expect(detector.update(sample: shifted, now: 0.25).held == .ring)
        #expect(detector.update(sample: shifted, now: 0.34).held == .ring)
    }

    @Test("Legacy tuning keeps the old instant hand-over")
    func legacyCrossReleases() {
        var detector = RAVEPinchDetector(tuning: .legacy)
        detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0)
        detector.update(sample: hand(pinching: .ring, at: 0.01), now: 0.2)
        var shifted = openHand()
        shifted.thumbTip = shifted.middle.tip + SIMD3(0, 0, 0.01)
        let out = detector.update(sample: shifted, now: 0.3)
        #expect(out.held == nil)
        #expect(out.ended == .ring)
    }

    @Test("Losing tracking holds the pinch through the grace, then releases")
    func lostTrackingReleasesAfterGrace() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .little, at: 0.01), now: 0)
        #expect(detector.update(sample: hand(pinching: .little, at: 0.01), now: 0.2).held == .little)

        var out = detector.update(sample: nil, now: 0.25)
        #expect(out.held == .little)
        #expect(out.inTrackingGrace)
        #expect(out.ended == nil)
        out = detector.update(sample: nil, now: 0.36)
        #expect(out.held == .little)

        out = detector.update(sample: nil, now: 0.37)
        #expect(out.held == nil)
        #expect(out.ended == .little)
    }

    @Test("A tracking gap shorter than the grace is invisible")
    func shortGapInvisible() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let pinched = hand(pinching: .index, at: 0.01)
        detector.update(sample: pinched, now: 0)
        detector.update(sample: pinched, now: 0.2)
        detector.update(sample: nil, now: 0.21)
        detector.update(sample: nil, now: 0.25)
        let out = detector.update(sample: pinched, now: 0.3)
        #expect(out.held == .index)
        #expect(out.began == nil && out.ended == nil)
        // The grace clock restarts after a real sample.
        #expect(detector.update(sample: nil, now: 0.4).held == .index)
    }

    @Test("forceRelease is immediate")
    func forceReleaseImmediate() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: hand(pinching: .index, at: 0.01), now: 0)
        detector.update(sample: hand(pinching: .index, at: 0.01), now: 0.2)
        let out = detector.forceRelease()
        #expect(out.ended == .index)
        #expect(detector.heldFinger == nil)
    }

    @Test("Legacy tuning releases on the first nil sample")
    func legacyLostTracking() {
        var detector = RAVEPinchDetector(tuning: .legacy)
        detector.update(sample: hand(pinching: .little, at: 0.01), now: 0)
        detector.update(sample: hand(pinching: .little, at: 0.01), now: 0.2)
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

/// A realistic neighbour: two fingertips both within a couple of centimetres of
/// the thumb, as on a real hand.
private func closeFingers(indexDistance: Float, middleDistance: Float) -> RAVEHandSample {
    var sample = openHand()
    // The thumb `indexDistance` from the index tip, and the middle tip a
    // further `middleDistance` along the same line.
    sample.thumbTip = sample.index.tip + SIMD3(indexDistance, 0, 0)
    sample.middle.tip = sample.thumbTip + SIMD3(middleDistance, 0, 0)
    return sample
}

@Suite("Pinch selection margin")
struct PinchMarginTests {

    @Test("Two fingers equally near the thumb are ambiguous and pinch nothing")
    func ambiguousRefused() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let sample = closeFingers(indexDistance: 0.012, middleDistance: 0.015)
        for t in stride(from: 0.0, through: 0.5, by: 0.05) {
            let out = detector.update(sample: sample, now: t)
            #expect(out.held == nil)
            #expect(out.isAmbiguous)
        }
    }

    @Test("A clear winner pinches")
    func clearWinnerPinches() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let sample = closeFingers(indexDistance: 0.005, middleDistance: 0.02)
        detector.update(sample: sample, now: 0)
        let out = detector.update(sample: sample, now: 0.1)
        #expect(out.held == .index)
        #expect(!out.isAmbiguous)
    }

    @Test("Legacy nearest-wins picks the closer of two ambiguous fingers")
    func legacyNearestWins() {
        var detector = RAVEPinchDetector(tuning: .legacy)
        let sample = closeFingers(indexDistance: 0.012, middleDistance: 0.015)
        detector.update(sample: sample, now: 0)
        #expect(detector.update(sample: sample, now: 0.1).held == .index)
    }

    @Test("Becoming ambiguous during the debounce cancels it")
    func ambiguityCancelsDebounce() {
        var detector = RAVEPinchDetector(tuning: .standard)
        detector.update(sample: closeFingers(indexDistance: 0.005, middleDistance: 0.02), now: 0)
        detector.update(sample: closeFingers(indexDistance: 0.012, middleDistance: 0.015), now: 0.05)
        let out = detector.update(sample: closeFingers(indexDistance: 0.005, middleDistance: 0.02), now: 0.1)
        #expect(out.held == nil)   // restarted at 0.1
        #expect(detector.update(sample: closeFingers(indexDistance: 0.005, middleDistance: 0.02), now: 0.2).held == .index)
    }

    @Test("Once held, a neighbour creeping close does not steal or drop the pinch")
    func heldSurvivesAmbiguity() {
        var detector = RAVEPinchDetector(tuning: .standard)
        let clean = closeFingers(indexDistance: 0.005, middleDistance: 0.02)
        detector.update(sample: clean, now: 0)
        detector.update(sample: clean, now: 0.1)
        for t in stride(from: 0.15, through: 0.6, by: 0.05) {
            let out = detector.update(sample: closeFingers(indexDistance: 0.012, middleDistance: 0.013), now: t)
            #expect(out.held == .index)
        }
    }
}

@Suite("Pinch presets and closing speed")
struct PinchPresetTests {

    @Test("The joystick preset needs 150 ms and ignores other fingers")
    func joystickPreset() {
        var detector = RAVEPinchDetector(tuning: .joystick)
        let pinched = hand(pinching: .index, at: 0.01)
        detector.update(sample: pinched, now: 0)
        #expect(detector.update(sample: pinched, now: 0.12).held == nil)
        #expect(detector.update(sample: pinched, now: 0.15).held == .index)

        var other = RAVEPinchDetector(tuning: .joystick)
        other.update(sample: hand(pinching: .middle, at: 0.005), now: 0)
        #expect(other.update(sample: hand(pinching: .middle, at: 0.005), now: 0.3).held == nil)
    }

    @Test("The clutch keeps its instant engage and gains the tracking grace")
    func clutchGrace() {
        var detector = RAVEPinchDetector(tuning: .clutch)
        #expect(detector.update(sample: hand(pinching: .index, at: 0.01), now: 0).held == .index)
        #expect(detector.update(sample: nil, now: 0.05).held == .index)
        #expect(detector.update(sample: nil, now: 0.2).ended == .index)
    }

    @Test("With a closing-speed floor, a slow drift into range does not engage")
    func slowDriftRejected() {
        var tuning = RAVEPinchTuning.standard
        tuning.minClosingSpeed = 0.15
        var detector = RAVEPinchDetector(tuning: tuning)
        // Close from 5 cm to 1 cm over 2 s: 2 cm/s.
        var t = 0.0
        var d: Float = 0.05
        while d > 0.01 {
            detector.update(sample: hand(pinching: .index, at: d), now: t)
            t += 1.0 / 90
            d -= 0.02 / 90
        }
        for _ in 0..<30 {
            #expect(detector.update(sample: hand(pinching: .index, at: 0.01), now: t).held == nil)
            t += 1.0 / 90
        }
    }

    @Test("With a closing-speed floor, a deliberate pinch still engages")
    func fastPinchAccepted() {
        var tuning = RAVEPinchTuning.standard
        tuning.minClosingSpeed = 0.15
        var detector = RAVEPinchDetector(tuning: tuning)
        // Close from 5 cm to 1 cm in 0.1 s: 40 cm/s.
        var t = 0.0
        for i in 0...9 {
            detector.update(sample: hand(pinching: .index, at: 0.05 - Float(i) * 0.0044), now: t)
            t += 1.0 / 90
        }
        var held: RAVEHandFinger?
        for _ in 0..<15 {
            held = detector.update(sample: hand(pinching: .index, at: 0.01), now: t).held
            t += 1.0 / 90
        }
        #expect(held == .index)
    }
}
