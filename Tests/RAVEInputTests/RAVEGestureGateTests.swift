import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Gesture gate")
struct RAVEGestureGateTests {

    @Test("Hysteresis: engage at enter, hold through the band, release past exit")
    func hysteresis() {
        var gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(enter: 0.9, exit: 0.7))
        #expect(!gate.update(value: 0.85, now: 0).engaged)
        let on = gate.update(value: 0.92, now: 0.1)
        #expect(on.engaged && on.began)
        #expect(gate.update(value: 0.75, now: 0.2).engaged)
        let off = gate.update(value: 0.65, now: 0.3)
        #expect(!off.engaged && off.ended)
    }

    @Test("Falling sense: a low value is in")
    func fallingSense() {
        var gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(sense: .falling, enter: 0.45, exit: 0.60))
        #expect(!gate.update(value: 0.5, now: 0).engaged)
        #expect(gate.update(value: 0.4, now: 0.1).began)
        #expect(gate.update(value: 0.55, now: 0.2).engaged)
        #expect(gate.update(value: 0.65, now: 0.3).ended)
    }

    @Test("Longwave's 1.5 s menu hold: progress climbs, engages once, lapse cancels")
    func menuHold() {
        var gate = RAVEGestureGate(tuning: .hold(1.5))
        var out = gate.update(active: true, now: 0)
        #expect(out.phase == .charging && out.progress == 0)
        out = gate.update(active: true, now: 0.75)
        #expect(abs(out.progress - 0.5) < 1e-5)
        #expect(!out.engaged)
        out = gate.update(active: true, now: 1.5)
        #expect(out.began && out.engaged && out.progress == 1)
        #expect(!gate.update(active: true, now: 2).began)

        // Letting go mid-charge resets the charge.
        var other = RAVEGestureGate(tuning: .hold(1.5))
        other.update(active: true, now: 0)
        other.update(active: true, now: 1.0)
        #expect(other.update(active: false, now: 1.1).phase == .idle)
        #expect(other.update(active: true, now: 1.2).progress == 0)
        #expect(!other.update(active: true, now: 2.6).engaged)
        #expect(other.update(active: true, now: 2.7).engaged)
    }

    @Test("Lambda's reload: thumb curl with hysteresis, 750 ms hold, cancelled by a trigger pull")
    func reloadHold() {
        let tuning = RAVEGestureGateTuning(sense: .falling, enter: 0.45, exit: 0.60, holdToEngage: 0.75)
        var gate = RAVEGestureGate(tuning: tuning)
        // Thumb curls; index extended (engage allowed).
        gate.update(value: 0.40, now: 0, engageAllowed: true)
        // Wobbling inside the band keeps charging.
        let mid = gate.update(value: 0.55, now: 0.4, engageAllowed: true)
        #expect(mid.phase == .charging)
        #expect(mid.progress > 0.5)
        #expect(gate.update(value: 0.42, now: 0.75, engageAllowed: true).began)
        // Latched until the thumb re-extends past exit.
        #expect(gate.update(value: 0.5, now: 2.0).engaged)
        #expect(gate.update(value: 0.7, now: 2.1).ended)

        // Trigger pull (engage disallowed) during the charge cancels it.
        var pulled = RAVEGestureGate(tuning: tuning)
        pulled.update(value: 0.40, now: 0)
        #expect(pulled.update(value: 0.40, now: 0.5, engageAllowed: false).phase == .idle)
        #expect(!pulled.update(value: 0.40, now: 0.8).engaged)   // restarted at 0.8
    }

    @Test("Release grace absorbs a short lapse and a nil reading")
    func releaseGrace() {
        var gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(enter: 0.9, exit: 0.7, releaseGrace: 0.4))
        gate.update(value: 1, now: 0)
        let lapse = gate.update(value: 0.2, now: 0.1)
        #expect(lapse.engaged && lapse.phase == .releasing && !lapse.ended)
        #expect(gate.update(value: nil, now: 0.3).engaged)
        let back = gate.update(value: 0.8, now: 0.45)
        #expect(back.phase == .engaged && !back.began)
        gate.update(value: 0.2, now: 0.5)
        #expect(gate.update(value: 0.2, now: 0.89).engaged)
        #expect(gate.update(value: 0.2, now: 0.9).ended)
    }

    @Test("holdAllowed = false is a lapse; engageAllowed = false blocks engaging")
    func conditions() {
        var gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(enter: 0.9, exit: 0.7))
        #expect(!gate.update(value: 1, now: 0, engageAllowed: false).engaged)
        #expect(gate.update(value: 1, now: 0.1).began)
        // Engage conditions no longer matter once engaged.
        #expect(gate.update(value: 1, now: 0.2, engageAllowed: false).engaged)
        #expect(gate.update(value: 1, now: 0.3, holdAllowed: false).ended)
    }

    @Test("Re-arm delay stops a long gesture from chain-firing")
    func rearm() {
        var gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(enter: 0.9, exit: 0.7, rearmDelay: 0.5))
        gate.update(value: 1, now: 0)
        #expect(gate.update(value: 0, now: 0.1).ended)
        #expect(!gate.update(value: 1, now: 0.3).engaged)
        #expect(gate.update(value: 1, now: 0.6).began)
    }

    @Test("forceRelease reports the edge once")
    func forceRelease() {
        var gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(enter: 0.9, exit: 0.7))
        gate.update(value: 1, now: 0)
        #expect(gate.forceRelease(now: 0.1).ended)
        #expect(!gate.forceRelease(now: 0.2).ended)
        #expect(!gate.isEngaged)
    }
}

@Suite("Palm-facing gate")
struct RAVEPalmFacingGateTests {

    @Test("Show needs the dwell; a palm swinging past the face does not flash the panel")
    func dwell() {
        var gate = RAVEPalmFacingGate.panel
        #expect(!gate.update(facing: 0.97, now: 0).engaged)
        #expect(!gate.update(facing: 0.97, now: 0.05).engaged)
        #expect(!gate.update(facing: 0.5, now: 0.08).engaged)   // passed by
        gate.update(facing: 0.97, now: 0.2)
        #expect(gate.update(facing: 0.97, now: 0.32).began)
        #expect(gate.isShown)
    }

    @Test("Forgiving preset lingers 0.4 s, including through tracking loss")
    func linger() {
        var gate = RAVEPalmFacingGate.forgiving
        gate.update(facing: 0.95, now: 0)
        gate.update(facing: 0.95, now: 0.12)
        #expect(gate.isShown)
        #expect(gate.update(facing: nil, now: 0.2).engaged)
        #expect(gate.update(facing: 0.1, now: 0.5).engaged)
        #expect(gate.update(facing: 0.1, now: 0.61).ended)   // lapse began at 0.2
    }

    @Test("Panel preset hides at once below 0.70")
    func panelHides() {
        var gate = RAVEPalmFacingGate.panel
        gate.update(facing: 0.99, now: 0)
        gate.update(facing: 0.99, now: 0.2)
        #expect(gate.update(facing: 0.75, now: 0.3).engaged)
        #expect(gate.update(facing: 0.69, now: 0.4).ended)
    }

    @Test("Reads a real palm pose with the chosen metric")
    func fromPose() {
        // Palm at the origin facing +Z, fingers up +Y; head straight ahead on +Z.
        let pose = RAVEPalmPose(position: .zero, palmNormalOut: SIMD3(0, 0, 1),
                                fingersDirection: SIMD3(0, 1, 0))
        var gate = RAVEPalmFacingGate.panel
        gate.update(pose: pose, head: SIMD3(0, 0, 0.5), now: 0)
        #expect(gate.lastFacing.map { abs($0 - 1) < 1e-5 } == true)
        #expect(gate.update(pose: pose, head: SIMD3(0, 0, 0.5), now: 0.2).engaged)
        #expect(gate.update(pose: nil, head: SIMD3(0, 0, 0.5), now: 0.3).ended)
    }
}
