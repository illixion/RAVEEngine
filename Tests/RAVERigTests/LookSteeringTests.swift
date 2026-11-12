import Testing
import simd
@testable import RAVERig

@Suite struct LookSteeringTests {
    private let forward = SIMD3<Float>(0, 0, 1)
    private func degrees(_ r: Float) -> Float { r * 180 / .pi }

    /// `angles` and `direction` must agree on which way is positive, or the
    /// head turns away from what it was asked to look at.
    @Test func anglesAndDirectionRoundTrip() {
        let steering = LookSteering()
        for yaw in stride(from: Float(-60), through: 60, by: 20) {
            for pitch in stride(from: Float(-30), through: 30, by: 15) {
                let dir = LookSteering.direction(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180, forward: forward)
                let back = steering.angles(of: dir, forward: forward)
                #expect(abs(degrees(back.yaw) - yaw) < 0.01)
                #expect(abs(degrees(back.pitch) - pitch) < 0.01)
            }
        }
        #expect(degrees(steering.angles(of: [1, 0, 0], forward: forward).yaw) > 89)
    }

    /// Clamped to the neck's range, and reached at the bounded rate rather
    /// than in one frame.
    @Test func clampsAndEases() {
        var steering = LookSteering()
        let target = SIMD3<Float>(-1, 0, -0.2)   // ~101° to the -x side
        _ = steering.step(toward: target, forward: forward, deltaTime: 1.0 / 90)
        #expect(abs(degrees(steering.yaw)) < 3)
        for _ in 0..<200 { _ = steering.step(toward: target, forward: forward, deltaTime: 1.0 / 90) }
        #expect(abs(degrees(steering.yaw) + 70) < 0.01)
        #expect(degrees(steering.wantedYaw) < -95)
    }

    /// A target walking round behind the character keeps the head on the
    /// side it is already turned to instead of snapping across.
    @Test func doesNotFlipBehind() {
        var steering = LookSteering()
        for _ in 0..<300 { _ = steering.step(toward: [1, 0, -0.9], forward: forward, deltaTime: 1.0 / 90) }
        #expect(degrees(steering.yaw) > 69)
        // Now just past straight behind on the other side.
        for _ in 0..<30 { _ = steering.step(toward: [-0.05, 0, -1], forward: forward, deltaTime: 1.0 / 90) }
        #expect(degrees(steering.yaw) > 69)
    }
}
