import Testing
import simd
@testable import RAVEInput

private let forward = SIMD3<Float>(0, 0, -1)
private let right = SIMD3<Float>(1, 0, 0)
private let basis = RAVEPlanarBasis(forward: forward, right: right)

@Suite("Wrist-delta joystick")
struct RAVEHandJoystickTests {

    @Test("The first engaged frame anchors and reads zero")
    func firstFrameAnchors() {
        var stick = RAVEHandJoystick()
        let out = stick.update(
            controlPoint: SIMD3(1, 1, 1), engaged: true, basis: basis
        )
        #expect(out.vector == .zero)
        #expect(out.isEngaged)
        #expect(stick.anchor == SIMD3(1, 1, 1))
        #expect(out.visualization?.center == SIMD3(1, 1, 1))
        #expect(out.visualization?.handle == SIMD3(1, 1, 1))
        #expect(out.visualization?.value == .zero)
    }

    @Test("Full-scale displacement reads 1")
    func fullScale() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18)
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        let out = stick.update(
            controlPoint: SIMD3(0.18, 0, 0), engaged: true, basis: basis
        )
        #expect(abs(out.vector.x - 1) < 1e-5)
        #expect(abs(out.vector.y) < 1e-5)
        #expect(out.visualization?.value == out.vector)
    }

    @Test("Magnitude is clamped to 1 without distorting direction")
    func clampsMagnitude() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18)
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        // 1 m diagonal — far past full scale on both axes.
        let out = stick.update(
            controlPoint: SIMD3(1, 0, -1), engaged: true, basis: basis
        )
        #expect(abs(simd_length(out.vector) - 1) < 1e-5)
        #expect(abs(out.vector.x - out.vector.y) < 1e-5)
        #expect(abs(simd_distance(out.visualization!.center, out.visualization!.handle) - 0.18) < 1e-5)
    }

    @Test("Disengaging drops the anchor so the next hold re-centres")
    func releaseRecentres() {
        var stick = RAVEHandJoystick()
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        stick.update(controlPoint: SIMD3(0.1, 0, 0), engaged: false, basis: basis)
        #expect(stick.anchor == nil)

        let out = stick.update(
            controlPoint: SIMD3(0.1, 0, 0), engaged: true, basis: basis
        )
        #expect(out.vector == .zero)
        #expect(stick.anchor == SIMD3(0.1, 0, 0))
    }

    @Test("The deadzone suppresses drift but still reports the raw delta")
    func deadzone() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0.03)
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        let out = stick.update(
            controlPoint: SIMD3(0.02, 0.05, 0), engaged: true, basis: basis
        )
        #expect(out.vector == .zero)
        // Vertical gestures read `delta.y`, so the deadzone must not eat it.
        #expect(abs(out.delta.y - 0.05) < 1e-6)
    }

    @Test("The shared default deadzone suppresses normal wrist jitter")
    func defaultDeadzone() {
        var stick = RAVEHandJoystick()
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        let out = stick.update(
            controlPoint: SIMD3(0.015, 0, -0.015), engaged: true, basis: basis
        )
        #expect(out.vector == .zero)
        #expect(out.visualization != nil)
    }

    @Test("The radial deadzone is removed from the active output range")
    func radialDeadzoneRemaps() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0.03)
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        let out = stick.update(
            controlPoint: SIMD3(0.105, 0, 0), engaged: true, basis: basis
        )
        #expect(abs(out.vector.x - 0.5) < 1e-5)
    }

    @Test("A pitched head basis does not lose forward sensitivity")
    func pitchedHeadKeepsScale() {
        // The defect this converged away from: two of the three ported copies
        // projected onto the raw flattened axes, so looking down at your hand
        // shortened `forward` and quietly reduced forward travel.
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18)
        let pitchedForward = simd_normalize(SIMD3<Float>(0, -0.7, -0.7))
        let pitchedBasis = RAVEPlanarBasis(forward: pitchedForward, right: right)
        stick.update(controlPoint: .zero, engaged: true, basis: pitchedBasis)
        let out = stick.update(
            controlPoint: SIMD3(0, 0, -0.18), engaged: true, basis: pitchedBasis
        )
        #expect(abs(out.vector.y - 1) < 1e-5)
    }

    @Test("The basis repairs skew and a reversed supplied right axis")
    func canonicalBasis() {
        let repaired = RAVEPlanarBasis(
            forward: SIMD3(0.2, -0.8, -0.8),
            right: SIMD3(-1, 0, 0.4)
        )
        #expect(abs(simd_length(repaired.forward) - 1) < 1e-5)
        #expect(abs(simd_length(repaired.right) - 1) < 1e-5)
        #expect(abs(simd_dot(repaired.forward, repaired.right)) < 1e-5)
        #expect(repaired.right.x > 0)
    }

    @Test("A straight-down basis falls back rather than producing NaN")
    func degenerateBasis() {
        let fallback = RAVEPlanarBasis(
            forward: SIMD3(0, -1, 0),
            right: SIMD3(0, -1, 0)
        )
        #expect(fallback == basis)
    }

    @Test("Invalid tracking samples disengage instead of leaking NaNs")
    func invalidControlPoint() {
        var stick = RAVEHandJoystick()
        stick.update(controlPoint: .zero, engaged: true, basis: basis)
        let out = stick.update(
            controlPoint: SIMD3(.nan, 0, 0), engaged: true, basis: basis
        )
        #expect(out == RAVEJoystickOutput())
        #expect(stick.anchor == nil)
    }
}
