import Testing
import simd
@testable import RAVEInput

private let forward = SIMD3<Float>(0, 0, -1)
private let right = SIMD3<Float>(1, 0, 0)

@Suite("Wrist-delta joystick")
struct RAVEHandJoystickTests {

    @Test("The first engaged frame anchors and reads zero")
    func firstFrameAnchors() {
        var stick = RAVEHandJoystick()
        let out = stick.update(
            wristWorld: SIMD3(1, 1, 1), engaged: true,
            worldForward: forward, worldRight: right
        )
        #expect(out.vector == .zero)
        #expect(out.isEngaged)
        #expect(stick.anchorWorld == SIMD3(1, 1, 1))
    }

    @Test("Full-scale displacement reads 1")
    func fullScale() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18)
        stick.update(wristWorld: .zero, engaged: true, worldForward: forward, worldRight: right)
        let out = stick.update(
            wristWorld: SIMD3(0.18, 0, 0), engaged: true,
            worldForward: forward, worldRight: right
        )
        #expect(abs(out.vector.x - 1) < 1e-5)
        #expect(abs(out.vector.y) < 1e-5)
    }

    @Test("Magnitude is clamped to 1 without distorting direction")
    func clampsMagnitude() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18)
        stick.update(wristWorld: .zero, engaged: true, worldForward: forward, worldRight: right)
        // 1 m diagonal — far past full scale on both axes.
        let out = stick.update(
            wristWorld: SIMD3(1, 0, -1), engaged: true,
            worldForward: forward, worldRight: right
        )
        #expect(abs(simd_length(out.vector) - 1) < 1e-5)
        #expect(abs(out.vector.x - out.vector.y) < 1e-5)
    }

    @Test("Disengaging drops the anchor so the next hold re-centres")
    func releaseRecentres() {
        var stick = RAVEHandJoystick()
        stick.update(wristWorld: .zero, engaged: true, worldForward: forward, worldRight: right)
        stick.update(wristWorld: SIMD3(0.1, 0, 0), engaged: false, worldForward: forward, worldRight: right)
        #expect(stick.anchorWorld == nil)

        let out = stick.update(
            wristWorld: SIMD3(0.1, 0, 0), engaged: true,
            worldForward: forward, worldRight: right
        )
        #expect(out.vector == .zero)
        #expect(stick.anchorWorld == SIMD3(0.1, 0, 0))
    }

    @Test("The deadzone suppresses drift but still reports the raw delta")
    func deadzone() {
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18, deadzoneMeters: 0.03)
        stick.update(wristWorld: .zero, engaged: true, worldForward: forward, worldRight: right)
        let out = stick.update(
            wristWorld: SIMD3(0.02, 0.05, 0), engaged: true,
            worldForward: forward, worldRight: right
        )
        #expect(out.vector == .zero)
        // Vertical gestures read `delta.y`, so the deadzone must not eat it.
        #expect(abs(out.delta.y - 0.05) < 1e-6)
    }

    @Test("A pitched head basis does not lose forward sensitivity")
    func pitchedHeadKeepsScale() {
        // The defect this converged away from: two of the three ported copies
        // projected onto the raw flattened axes, so looking down at your hand
        // shortened `forward` and quietly reduced forward travel.
        var stick = RAVEHandJoystick(fullScaleMeters: 0.18)
        let pitchedForward = simd_normalize(SIMD3<Float>(0, -0.7, -0.7))
        stick.update(wristWorld: .zero, engaged: true, worldForward: pitchedForward, worldRight: right)
        let out = stick.update(
            wristWorld: SIMD3(0, 0, -0.18), engaged: true,
            worldForward: pitchedForward, worldRight: right
        )
        #expect(abs(out.vector.y - 1) < 1e-5)
    }

    @Test("A straight-down head basis falls back rather than producing NaN")
    func degenerateBasis() {
        var stick = RAVEHandJoystick()
        stick.update(
            wristWorld: .zero, engaged: true,
            worldForward: SIMD3(0, -1, 0), worldRight: SIMD3(0, -1, 0)
        )
        let out = stick.update(
            wristWorld: SIMD3(0.18, 0, 0), engaged: true,
            worldForward: SIMD3(0, -1, 0), worldRight: SIMD3(0, -1, 0)
        )
        #expect(!out.vector.x.isNaN)
        #expect(!out.vector.y.isNaN)
    }
}
