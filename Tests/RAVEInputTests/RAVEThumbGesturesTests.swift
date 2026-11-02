import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Thumb gestures")
struct RAVEThumbGesturesTests {
    private let tuning = RAVEThumbGestures.Tuning()
    private let frame: Double = 1.0 / 90

    /// A relaxed finger gun: index out, thumb out, nothing in contact.
    private var open: RAVEThumbGestures.Input {
        .init(indexExt: 0.9, thumbExt: 0.8, contact: 0.1, along: 0, thumbToIndexTip: 0.1)
    }
    /// Thumb curled down toward the index knuckle, index out: a reload curl.
    private var reloadCurl: RAVEThumbGestures.Input {
        .init(indexExt: 0.9, thumbExt: 0.3, contact: 0.1, along: 0, thumbToIndexTip: 0.1)
    }
    /// Thumb tip on the middle finger's side past the knuckle, index out.
    private var contactPose: RAVEThumbGestures.Input {
        .init(indexExt: 0.9, thumbExt: 0.5, contact: 0.01, along: 1.0, thumbToIndexTip: 0.1)
    }

    /// Run `input` for `seconds`, returning the end time.
    @discardableResult
    private func run(_ g: inout RAVEThumbGestures, _ input: RAVEThumbGestures.Input?,
                     from start: Double, seconds: Double) -> Double {
        var t = start
        while t < start + seconds {
            g.update(input, now: t, tuning: tuning)
            t += frame
        }
        return t
    }

    // MARK: Geometry

    @Test("A point beside the finger measures its distance and position along it")
    func measuresContact() {
        // A straight finger along +Z from the knuckle; the index knuckle is toward +X.
        let result = RAVEThumbContact.measure(
            thumbTip: SIMD3(0.01, 0, 0.02),
            knuckle: .zero, intermediateBase: SIMD3(0, 0, 0.04), intermediateTip: SIMD3(0, 0, 0.07),
            towardIndex: SIMD3(0.02, 0, 0), radialOffset: 0)
        #expect(abs(result.distance - 0.01) < 1e-5)
        #expect(abs(result.along - 0.5) < 1e-4)   // halfway along the proximal phalanx
    }

    @Test("Beyond the intermediate base the position runs from 1 to 2")
    func positionOnSecondSegment() {
        let result = RAVEThumbContact.measure(
            thumbTip: SIMD3(0, 0, 0.055),
            knuckle: .zero, intermediateBase: SIMD3(0, 0, 0.04), intermediateTip: SIMD3(0, 0, 0.07),
            towardIndex: SIMD3(0.02, 0, 0), radialOffset: 0)
        #expect(abs(result.along - 1.5) < 1e-4)
        #expect(result.distance < 1e-5)
    }

    @Test("The radial offset shifts the line toward the index knuckle")
    func radialOffsetShifts() {
        let thumb = SIMD3<Float>(0.01, 0, 0.02)
        let plain = RAVEThumbContact.measure(
            thumbTip: thumb, knuckle: .zero, intermediateBase: SIMD3(0, 0, 0.04),
            intermediateTip: SIMD3(0, 0, 0.07), towardIndex: SIMD3(1, 0, 0), radialOffset: 0)
        let shifted = RAVEThumbContact.measure(
            thumbTip: thumb, knuckle: .zero, intermediateBase: SIMD3(0, 0, 0.04),
            intermediateTip: SIMD3(0, 0, 0.07), towardIndex: SIMD3(1, 0, 0), radialOffset: 0.01)
        #expect(plain.distance > shifted.distance)
        #expect(shifted.distance < 1e-5)
    }

    @Test("A degenerate segment measures to its endpoint without dividing by zero")
    func degenerateSegment() {
        let (distance, t) = RAVEThumbContact.segment(SIMD3(1, 0, 0), .zero, .zero)
        #expect(distance == 1)
        #expect(t == 0)
    }

    // MARK: Reload

    @Test("Holding the thumb curl fills the ring, then fires the reload")
    func reloadFires() {
        var g = RAVEThumbGestures()
        var t = run(&g, reloadCurl, from: 0, seconds: 0.4)
        #expect(g.reloadRing > 0.3 && g.reloadRing < 0.8)
        #expect(!g.reload)
        t = run(&g, reloadCurl, from: t, seconds: 0.5)
        #expect(g.reload)
        #expect(g.reloadRing == 0)      // the full ring vanishing is the cue
    }

    @Test("Letting the thumb out before the hold ends cancels it")
    func reloadCancels() {
        var g = RAVEThumbGestures()
        let t = run(&g, reloadCurl, from: 0, seconds: 0.4)
        run(&g, open, from: t, seconds: 0.2)
        #expect(!g.reload)
        #expect(g.reloadRing == 0)
    }

    @Test("A pulled trigger never reloads")
    func triggerNeverReloads() {
        var g = RAVEThumbGestures()
        var input = reloadCurl
        input.indexExt = 0.3
        run(&g, input, from: 0, seconds: 2)
        #expect(!g.reload)
        #expect(g.reloadRing == 0)
    }

    // MARK: Alt-fire

    @Test("Touching the middle finger settles, then presses alt-fire; reload stays down")
    func altFirePresses() {
        var g = RAVEThumbGestures()
        let t = run(&g, contactPose, from: 0, seconds: 0.2)
        #expect(g.altFire)
        #expect(g.altState == .held)
        #expect(!g.reload)
        #expect(g.reloadRing == 0)      // the reload hold is vetoed near the finger
        _ = t
    }

    @Test("Alt-fire is down for as long as contact holds")
    func altFireHolds() {
        var g = RAVEThumbGestures()
        let t = run(&g, contactPose, from: 0, seconds: 0.2)
        run(&g, contactPose, from: t, seconds: 1)
        #expect(g.altFire)
    }

    @Test("Moving off the finger releases it after the release delay")
    func altFireReleases() {
        var g = RAVEThumbGestures()
        var t = run(&g, contactPose, from: 0, seconds: 0.2)
        t = run(&g, open, from: t, seconds: 0.02)
        #expect(g.altFire)              // jitter must not drop it at once
        run(&g, open, from: t, seconds: 0.2)
        #expect(!g.altFire)
    }

    @Test("A curled index (a fist) never starts alt-fire")
    func fistDoesNotAltFire() {
        var g = RAVEThumbGestures()
        var input = contactPose
        input.indexExt = 0.3
        run(&g, input, from: 0, seconds: 0.5)
        #expect(!g.altFire)
        #expect(g.altState == .noIndex)
    }

    @Test("A pinch (thumb on the index tip) never starts alt-fire")
    func pinchDoesNotAltFire() {
        var g = RAVEThumbGestures()
        var input = contactPose
        input.thumbToIndexTip = 0.02
        run(&g, input, from: 0, seconds: 0.5)
        #expect(!g.altFire)
        #expect(g.altState == .pinch)
    }

    @Test("Contact too close to the knuckle is a reload curl, not alt-fire")
    func nearKnuckleIsNotAltFire() {
        var g = RAVEThumbGestures()
        var input = contactPose
        input.along = 0.1
        run(&g, input, from: 0, seconds: 0.5)
        #expect(!g.altFire)
    }

    @Test("Alt-fire switched off in tuning never presses")
    func altFireCanBeOff() {
        var g = RAVEThumbGestures()
        var t = tuning
        t.altFire = false
        var time = 0.0
        while time < 0.5 { g.update(contactPose, now: time, tuning: t); time += frame }
        #expect(!g.altFire)
        #expect(g.altState == .off)
    }

    // MARK: Locks and resets

    @Test("A reload that fired blocks alt-fire until the thumb re-extends")
    func reloadLocksAltFire() {
        var g = RAVEThumbGestures()
        var t = run(&g, reloadCurl, from: 0, seconds: 1)
        #expect(g.reload)
        t = run(&g, contactPose, from: t, seconds: 0.3)
        #expect(!g.altFire)
        // Extend the thumb, then touch the finger again: it presses.
        t = run(&g, open, from: t, seconds: 0.1)
        run(&g, contactPose, from: t, seconds: 0.3)
        #expect(g.altFire)
    }

    @Test("A nil input (gestures not allowed) releases everything at once")
    func nilReleases() {
        var g = RAVEThumbGestures()
        let t = run(&g, contactPose, from: 0, seconds: 0.3)
        #expect(g.altFire)
        g.update(nil, now: t, tuning: tuning)
        #expect(!g.altFire && !g.reload)
        #expect(g.reloadRing == 0)
    }
}
