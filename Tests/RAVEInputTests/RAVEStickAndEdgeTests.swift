import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Stick shaping")
struct RAVEStickShapingTests {

    @Test("Radial deadzone zeroes the centre and rescales the rest to reach 1")
    func radial() {
        #expect(RAVEStickShaping.radialDeadzone(SIMD2(0.1, 0.1)) == .zero)
        let edge = RAVEStickShaping.radialDeadzone(SIMD2(0.16, 0))
        #expect(edge.x > 0 && edge.x < 0.02)
        let full = RAVEStickShaping.radialDeadzone(SIMD2(1, 0))
        #expect(abs(full.x - 1) < 1e-5)
        // Beyond the unit circle clamps, direction preserved.
        let over = RAVEStickShaping.radialDeadzone(SIMD2(1, 1))
        #expect(abs(simd_length(over) - 1) < 1e-5)
        #expect(abs(over.x - over.y) < 1e-6)
        // Without rescale the output jumps to the raw value.
        #expect(abs(RAVEStickShaping.radialDeadzone(SIMD2(0.5, 0), rescale: false).x - 0.5) < 1e-6)
    }

    @Test("Axial deadzone kills sideways drift on a forward push")
    func axial() {
        let v = RAVEStickShaping.shaped(SIMD2(0.1, 0.9), axialDeadzone: 0.15)
        #expect(v.x == 0)
        #expect(v.y > 0.8)
        #expect(RAVEStickShaping.axialDeadzone(SIMD2(Float.nan, 1)) == .zero)
    }

    @Test("Snap turn: one push, one step, with hysteresis")
    func snapOnce() {
        var snap = RAVESnapTurnDetector()
        #expect(snap.update(0.4, now: 0) == 0)
        #expect(snap.update(0.6, now: 0.1) == 1)
        #expect(snap.update(0.9, now: 0.2) == 0)
        // Dipping into the band (0.3…0.5) and back out does not re-fire.
        #expect(snap.update(0.4, now: 0.3) == 0)
        #expect(snap.update(0.6, now: 0.4) == 0)
        // Only below release re-arms.
        #expect(snap.update(0.2, now: 0.5) == 0)
        #expect(snap.update(0.6, now: 0.6) == 1)
        #expect(snap.update(-0.7, now: 0.7) == -1)
    }

    @Test("Snap turn repeats while held when configured")
    func snapRepeat() {
        var snap = RAVESnapTurnDetector(repeatDelay: 0.5, repeatInterval: 0.25)
        #expect(snap.update(1, now: 0) == 1)
        #expect(snap.update(1, now: 0.4) == 0)
        #expect(snap.update(1, now: 0.5) == 1)
        #expect(snap.update(1, now: 0.6) == 0)
        #expect(snap.update(1, now: 0.75) == 1)
    }
}

@Suite("Edge debounce")
struct RAVEEdgeDebounceTests {

    @Test("Bounce shorter than the debounce is ignored")
    func bounceIgnored() {
        var edges = RAVEEdgeTracker<String>(debounce: 0.03)
        #expect(edges.update("a", pressed: true, now: 0) == .steady)
        #expect(edges.update("a", pressed: false, now: 0.01) == .steady)
        #expect(edges.update("a", pressed: true, now: 0.02) == .steady)
        #expect(edges.update("a", pressed: true, now: 0.05) == .began)
        #expect(edges.isHeld("a"))
        #expect(edges.update("a", pressed: false, now: 0.06) == .steady)
        #expect(edges.update("a", pressed: false, now: 0.09) == .ended)
    }

    @Test("Zero debounce with a clock behaves like the original")
    func zeroDebounce() {
        var edges = RAVEEdgeTracker<Int>()
        let pressed = edges.pressed(1, true, now: 0)
        #expect(pressed)
        #expect(edges.update(1, pressed: false, now: 0) == .ended)
    }
}

@Suite("Joystick smoothing and axial deadzone")
struct RAVEJoystickSmoothingTests {
    private let basis = RAVEPlanarBasis(forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))

    @Test("Smoothing lags a step and converges; off by default")
    func smoothing() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0,
                                     axialDeadzone: 0, smoothingTime: 0.1)
        stick.update(controlPoint: .zero, engaged: true, basis: basis, now: 0)
        let first = stick.update(controlPoint: SIMD3(0.18, 0, 0), engaged: true, basis: basis, now: 0.011)
        #expect(first.vector.x > 0 && first.vector.x < 0.2)
        var out = first
        var t = 0.011
        for _ in 0..<90 {
            t += 0.011
            out = stick.update(controlPoint: SIMD3(0.18, 0, 0), engaged: true, basis: basis, now: t)
        }
        #expect(out.vector.x > 0.99)

        var plain = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0)
        plain.update(controlPoint: .zero, engaged: true, basis: basis, now: 0)
        let step = plain.update(controlPoint: SIMD3(0.18, 0, 0), engaged: true, basis: basis, now: 0.011)
        #expect(abs(step.vector.x - 1) < 1e-5)
    }

    @Test("Releasing clears the filter so the next hold starts from rest")
    func releaseClears() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0,
                                     axialDeadzone: 0, smoothingTime: 0.1)
        stick.update(controlPoint: .zero, engaged: true, basis: basis, now: 0)
        stick.update(controlPoint: SIMD3(0.18, 0, 0), engaged: true, basis: basis, now: 0.5)
        stick.update(controlPoint: nil, engaged: false, basis: basis, now: 0.6)
        let fresh = stick.update(controlPoint: SIMD3(1, 0, 0), engaged: true, basis: basis, now: 0.7)
        #expect(fresh.vector == .zero)
    }

    @Test("Axial deadzone strips a small sideways component")
    func axialDeadzone() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0.03,
                                     axialDeadzone: 0.15, smoothingTime: 0)
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        let out = stick.update(controlPoint: SIMD3(0.01, 0, -0.15), engaged: true, basis: basis)
        #expect(out.vector.x == 0)
        #expect(out.vector.y > 0.5)
    }
}

@Suite("Joystick pinch is not a bindable event")
struct RAVEHandTickOutputTests {

    @Test("pinchEvents leaves out the joystick slot but held still reports it")
    func joystickSlotFiltered() {
        let out = RAVEHandTickOutput(
            left: RAVEPinchOutput(held: .index, began: .index),
            right: RAVEPinchOutput(held: .middle, began: .middle),
            joystickSlot: RAVEHandPinchEvent(chirality: .left, finger: .index)
        )
        #expect(out.pinchEvents == [RAVEHandPinchEvent(chirality: .right, finger: .middle)])
        #expect(out.left.held == .index)

        let noStick = RAVEHandTickOutput(left: RAVEPinchOutput(held: .index, began: .index))
        #expect(noStick.pinchEvents == [RAVEHandPinchEvent(chirality: .left, finger: .index)])

        let otherLeft = RAVEHandTickOutput(
            left: RAVEPinchOutput(held: .middle, began: .middle),
            joystickSlot: RAVEHandPinchEvent(chirality: .left, finger: .index)
        )
        #expect(otherLeft.pinchEvents.count == 1)
    }
}
