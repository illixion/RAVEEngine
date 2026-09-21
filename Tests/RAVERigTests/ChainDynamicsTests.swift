import Testing
import simd
@testable import RAVERig

/// The chain has three jobs: keep its length, droop under gravity without
/// collapsing, and follow the body late rather than never. Everything is
/// measured on a tail the size of the Synth's — ten joints, 1.15 m, held
/// straight back at hip height — so the defaults are judged on the thing
/// they were chosen for.
@Suite struct ChainDynamicsTests {

    /// A horizontal tail from (0, 0.97, 0) back along +Z.
    private func tail(base: SIMD3<Float> = [0, 0.97, 0], count: Int = 10, spacing: Float = 0.128) -> [SIMD3<Float>] {
        (0..<count).map { base + SIMD3<Float>(0, 0, spacing * Float($0)) }
    }

    private func settle(_ chain: inout ChainDynamics, toward shape: [SIMD3<Float>], seconds: Float, fps: Float = 90) {
        let frames = Int(seconds * fps)
        for _ in 0..<frames { chain.step(toward: shape, deltaTime: 1 / fps) }
    }

    private func totalLength(_ positions: [SIMD3<Float>]) -> Float {
        zip(positions, positions.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
    }

    @Test func theChainKeepsItsLengthWhateverHappens() {
        let shape = tail()
        var chain = ChainDynamics(shape: shape)
        let rest = totalLength(shape)
        // Fling the base around and check every frame.
        var worst: Float = 0
        for frame in 0..<600 {
            let t = Float(frame) / 90
            let base = SIMD3<Float>(sin(t * 3) * 0.4, 0.97 + sin(t * 5) * 0.1, cos(t * 2) * 0.4)
            let moved = shape.map { $0 - shape[0] + base }
            chain.step(toward: moved, deltaTime: 1 / 90)
            worst = max(worst, abs(totalLength(chain.positions) - rest))
        }
        #expect(worst < 1e-3, "chain length drifted by \(worst) m")
    }

    @Test func gravityDroopsTheTipButDoesNotHangIt() {
        let shape = tail()
        var chain = ChainDynamics(shape: shape)
        settle(&chain, toward: shape, seconds: 4)
        let tip = chain.positions[chain.count - 1]
        let droop = shape[shape.count - 1].y - tip.y
        // Visible — a hand's width or more at the tip of a metre of tail —
        // but nowhere near hanging, which would put the tip a metre down.
        #expect(droop > 0.08, "tip drooped only \(droop) m")
        #expect(droop < 0.45, "tip drooped \(droop) m, which is a rope not a tail")
        // Every joint hangs at or below the one before it: a smooth curve.
        for i in 1..<chain.count {
            #expect(chain.positions[i].y <= chain.positions[i - 1].y + 1e-4)
        }
    }

    @Test func theBendLimitHolds() {
        var settings = ChainDynamics.Settings()
        settings.maxBendDegrees = 20
        settings.gravityScale = 1  // as hard as it gets
        let shape = tail()
        var chain = ChainDynamics(shape: shape, settings: settings)
        settle(&chain, toward: shape, seconds: 3)
        for i in 2..<chain.count {
            let a = simd_normalize(chain.positions[i - 1] - chain.positions[i - 2])
            let b = simd_normalize(chain.positions[i] - chain.positions[i - 1])
            let degrees = acos(simd_clamp(simd_dot(a, b), -1, 1)) * 180 / .pi
            #expect(degrees <= 20.5, "segment \(i) bent \(degrees) degrees")
        }
    }

    @Test func theTipLagsATurnAndThenCatchesUp() {
        let shape = tail()
        var chain = ChainDynamics(shape: shape)
        settle(&chain, toward: shape, seconds: 3)
        // Swing the whole tail 90 degrees about the base in one frame.
        let turned = TailSway.apply(to: shape, yaw: .pi / 2, pitch: 0)
        chain.step(toward: turned, deltaTime: 1 / 90)
        let tipTarget = turned[turned.count - 1]
        let immediately = simd_distance(chain.positions[chain.count - 1], tipTarget)
        #expect(immediately > 0.5, "the tip followed a 90 degree turn in one frame — no lag at all")
        settle(&chain, toward: turned, seconds: 3)
        let later = SIMD2(chain.positions[chain.count - 1].x - tipTarget.x,
                          chain.positions[chain.count - 1].z - tipTarget.z)
        #expect(simd_length(later) < 0.05, "the tip never caught up: \(simd_length(later)) m off in plan")
    }

    @Test func aTeleportPutsTheChainDownRatherThanWhippingIt() {
        let shape = tail()
        var chain = ChainDynamics(shape: shape)
        settle(&chain, toward: shape, seconds: 1)
        let far = shape.map { $0 + SIMD3<Float>(3, 0, 0) }
        chain.step(toward: far, deltaTime: 1 / 90)
        #expect(simd_distance(chain.positions[0], far[0]) < 1e-5)
        #expect(simd_distance(chain.positions[chain.count - 1], far[far.count - 1]) < 1e-5)
    }

    @Test func nothingSinksBelowTheFloor() {
        var settings = ChainDynamics.Settings()
        settings.gravityScale = 1
        settings.stiffness = 5
        settings.maxBendDegrees = 90
        let shape = tail(base: [0, 0.3, 0])
        var chain = ChainDynamics(shape: shape, settings: settings)
        for _ in 0..<400 { chain.step(toward: shape, deltaTime: 1 / 90, floor: 0.02) }
        #expect(chain.positions.allSatisfy { $0.y >= 0.02 - 1e-4 })
    }

    @Test func aRescaledShapeRescalesTheChain() {
        let shape = tail()
        var chain = ChainDynamics(shape: shape)
        settle(&chain, toward: shape, seconds: 1)
        let small = shape.map { shape[0] + ($0 - shape[0]) * 0.5 }
        settle(&chain, toward: small, seconds: 1)
        #expect(abs(totalLength(chain.positions) - totalLength(small)) < 1e-3)
    }
}

@Suite struct TailSwayTests {

    @Test func aWagSwingsTheTipSideToSideAtTheAskedRate() {
        var sway = TailSway(style: .init(frequencyHz: 2, amplitudeDegrees: 30, liftDegrees: 0))
        let shape = (0..<10).map { SIMD3<Float>(0, 1, 0.12 * Float($0)) }
        var xs: [Float] = []
        for _ in 0..<90 {   // one second at 90 Hz: two full wags
            let (yaw, pitch) = sway.advance(by: 1 / 90)
            xs.append(TailSway.apply(to: shape, yaw: yaw, pitch: pitch)[9].x)
        }
        let reach = 1.08 * sin(30 * Float.pi / 180)
        #expect(abs(xs.max()! - reach) < 0.02)
        #expect(abs(xs.min()! + reach) < 0.02)
        // Two wags: the sign changes four times.
        let crossings = zip(xs, xs.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(crossings == 4, "\(crossings) zero crossings in a second at 2 Hz")
    }

    @Test func liftRaisesTheTipAndStillLeavesTheBase() {
        let shape = (0..<10).map { SIMD3<Float>(0, 1, 0.12 * Float($0)) }
        let raised = TailSway.apply(to: shape, yaw: 0, pitch: 20 * .pi / 180)
        #expect(raised[0] == shape[0])
        #expect(raised[9].y > shape[9].y + 0.3)
        let tucked = TailSway.apply(to: shape, yaw: 0, pitch: -20 * .pi / 180)
        #expect(tucked[9].y < shape[9].y - 0.3)
    }

    @Test func aStyleChangeEasesInsteadOfJumping() {
        var sway = TailSway(style: .still)
        sway.wanted = .init(frequencyHz: 2, amplitudeDegrees: 30, liftDegrees: 0)
        _ = sway.advance(by: 1 / 90)
        #expect(sway.current.amplitude < 0.05, "amplitude jumped to \(sway.current.amplitude) in one frame")
        for _ in 0..<270 { _ = sway.advance(by: 1 / 90) }
        #expect(abs(sway.current.amplitude - sway.wanted.amplitude) < 0.01)
    }
}

/// A turn on the spot is where the tail flicked: the shape welded to the
/// pelvis swung its tip through metres in a fraction of a second and the
/// spring hauled the tail after it along the chord. The carriage now follows
/// the body's heading at a bounded rate.
@Suite struct TailHeadingTests {

    private func tail() -> [SIMD3<Float>] {
        (0..<10).map { SIMD3<Float>(0, 0.97, 0.128 * Float($0)) }
    }

    private func heading(of shape: [SIMD3<Float>]) -> Float {
        let d = shape[shape.count - 1] - shape[0]
        return atan2(d.x, d.z)
    }

    @Test func theCarriageTurnsNoFasterThanTheLimit() {
        var sway = TailSway(style: .still)
        sway.maxTurnRate = .pi   // 180 degrees a second
        let shape = tail()
        _ = sway.follow(shape, deltaTime: 1 / 90)
        // The body turns 180 degrees at once.
        let turned = TailSway.apply(to: shape, yaw: .pi, pitch: 0)
        var last = heading(of: shape)
        var frames = 0
        var worstStep: Float = 0
        while frames < 400 {
            let followed = sway.follow(turned, deltaTime: 1 / 90)
            let now = heading(of: followed)
            var step = now - last
            while step > .pi { step -= 2 * .pi }
            while step < -.pi { step += 2 * .pi }
            worstStep = max(worstStep, abs(step))
            last = now
            frames += 1
            if abs(step) < 1e-4, frames > 10 { break }
        }
        #expect(worstStep < (.pi / 90) * 1.05, "carriage turned \(worstStep * 180 / .pi) degrees in one frame")
        // Half a turn at 180 degrees a second is a second: ninety frames,
        // not one — and it does get there.
        #expect(frames >= 85 && frames <= 100, "took \(frames) frames to come round")
        let final = heading(of: sway.follow(turned, deltaTime: 1 / 90))
        var error = final - heading(of: turned)
        while error > .pi { error -= 2 * .pi }
        while error < -.pi { error += 2 * .pi }
        #expect(abs(error) < 0.01)
    }

    @Test func aSmallTurnGoesTheShortWayRound() {
        var sway = TailSway(style: .still)
        let shape = TailSway.apply(to: tail(), yaw: 170 * .pi / 180, pitch: 0)
        _ = sway.follow(shape, deltaTime: 1 / 90)
        let turned = TailSway.apply(to: tail(), yaw: -170 * .pi / 180, pitch: 0)
        // 20 degrees the short way at 180 degrees a second is a ninth of a
        // second; the long way round would be nearly two seconds.
        var frames = 0
        var followed = shape
        repeat {
            followed = sway.follow(turned, deltaTime: 1 / 90)
            frames += 1
        } while simd_distance(followed[9], turned[9]) > 0.01 && frames < 400
        #expect(frames < 20, "took \(frames) frames for a 20 degree turn")
    }

    @Test func theTipNoLongerCutsThroughTheBodyOnATurn() {
        // Same 180 degree turn, through the whole pipeline: heading follow,
        // then physics. The tip must stay out beyond most of the tail's
        // length from the base the whole way round — the chord cut it to
        // nearly nothing.
        var sway = TailSway(style: .still)
        var chain = ChainDynamics(shape: tail())
        let shape = tail()
        for _ in 0..<180 { chain.step(toward: sway.follow(shape, deltaTime: 1 / 90), deltaTime: 1 / 90) }
        let turned = TailSway.apply(to: shape, yaw: .pi, pitch: 0)
        var closest: Float = .infinity
        var fastest: Float = 0
        var previousTip = chain.positions[9]
        for _ in 0..<270 {
            chain.step(toward: sway.follow(turned, deltaTime: 1 / 90), deltaTime: 1 / 90)
            let tip = chain.positions[9]
            let base = chain.positions[0]
            closest = min(closest, simd_length(SIMD2(tip.x - base.x, tip.z - base.z)))
            fastest = max(fastest, simd_distance(tip, previousTip) * 90)
            previousTip = tip
        }
        #expect(closest > 0.7, "tip came within \(closest) m of the base in plan during a turn")
        #expect(fastest < 6, "tip reached \(fastest) m/s")
        var error = heading(of: chain.positions) - heading(of: turned)
        while error > .pi { error -= 2 * .pi }
        while error < -.pi { error += 2 * .pi }
        #expect(abs(error) < 0.1)
    }
}

@Suite struct ChainObstacleTests {

    private func tail() -> [SIMD3<Float>] {
        (0..<10).map { SIMD3<Float>(0, 0.97, 0.128 * Float($0)) }
    }

    @Test func aHandPushesTheTailOutAndItSpringsBack() {
        let shape = tail()
        var chain = ChainDynamics(shape: shape)
        for _ in 0..<180 { chain.step(toward: shape, deltaTime: 1 / 90) }
        let resting = chain.positions[6]
        // A palm placed right on the seventh particle, from below.
        let hand = ChainDynamics.Sphere(center: resting - SIMD3<Float>(0, 0.06, 0), radius: 0.06)
        for _ in 0..<45 { chain.step(toward: shape, deltaTime: 1 / 90, obstacles: [hand]) }
        #expect(!chain.touches([hand]))
        #expect(chain.positions[6].y > resting.y + 0.015, "the tail did not lift off the hand")
        let total = zip(chain.positions, chain.positions.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
        #expect(abs(total - 0.128 * 9) < 1e-3)
        // Hand withdrawn: back to where it hung.
        for _ in 0..<270 { chain.step(toward: shape, deltaTime: 1 / 90) }
        #expect(simd_distance(chain.positions[6], resting) < 0.01)
    }
}

extension ChainObstacleTests {

    /// The joints are a hand's breadth apart; a fingertip between two of them
    /// slipped straight through, which on the headset read as a tail that
    /// could only be touched at certain points along it.
    @Test func aFingertipBetweenTwoJointsStillMeetsTheTail() {
        let shape = (0..<10).map { SIMD3<Float>(0, 0.97, 0.128 * Float($0)) }
        var chain = ChainDynamics(shape: shape)
        for _ in 0..<180 { chain.step(toward: shape, deltaTime: 1 / 90) }
        let midpoint = (chain.positions[5] + chain.positions[6]) / 2
        let before = midpoint
        // A fingertip rising into the middle of the segment from below.
        let finger = ChainDynamics.Sphere(center: midpoint - SIMD3<Float>(0, 0.02, 0), radius: 0.012)
        for _ in 0..<45 { chain.step(toward: shape, deltaTime: 1 / 90, obstacles: [finger]) }
        #expect(!chain.touches([finger]))
        let after = (chain.positions[5] + chain.positions[6]) / 2
        // Lifted clear: by the finger's reach plus the tail's own thickness.
        #expect(after.y - before.y > 0.02, "segment midpoint rose only \(after.y - before.y) m")
        // Both neighbouring joints moved, not just one.
        #expect(chain.positions[5].y > shape[5].y - 0.2 && chain.positions[6].y > before.y - 0.05)
        let total = zip(chain.positions, chain.positions.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
        #expect(abs(total - 0.128 * 9) < 1e-3)
    }
}
