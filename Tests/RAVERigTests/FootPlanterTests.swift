import Testing
import simd
@testable import RAVERig

/// A VR body's feet: planted until displaced, never crossing, whichever way
/// the body goes.
@Suite struct FootPlanterTests {

    private let frame: Float = 1.0 / 90
    private func planter() -> FootPlanter {
        FootPlanter.forLeg(length: 0.9, hipWidth: 0.2)
    }

    /// Runs `seconds` of a body moving at `velocity` (world, per second) and
    /// turning at `turnRate` (radians per second), facing `facing` at the
    /// start. Returns every frame's hips, facing and placements.
    private func run(_ p: inout FootPlanter, seconds: Float, velocity: SIMD3<Float>,
                     turnRate: Float = 0, facing: Float = 0, start: SIMD3<Float> = .zero)
        -> [(hips: SIMD3<Float>, forward: SIMD3<Float>, feet: (left: FootPlanter.Placement, right: FootPlanter.Placement))] {
        var out: [(hips: SIMD3<Float>, forward: SIMD3<Float>, feet: (left: FootPlanter.Placement, right: FootPlanter.Placement))] = []
        var hips = start
        var yaw = facing
        var t: Float = 0
        while t < seconds {
            hips += velocity * frame
            yaw += turnRate * frame
            let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
            out.append((hips, forward, p.update(hips: hips, forward: forward, velocity: velocity,
                                                deltaTime: frame, floor: { _ in 0 })))
            t += frame
        }
        return out
    }

    /// Lateral position of a foot on its own side of the body: positive is
    /// where it belongs.
    private func ownSide(_ foot: FootPlanter.Placement, hips: SIMD3<Float>, forward: SIMD3<Float>, left: Bool) -> Float {
        let l = SIMD3<Float>(forward.z, 0, -forward.x)
        return simd_dot(SIMD3<Float>(foot.position.x - hips.x, 0, foot.position.z - hips.z), l) * (left ? 1 : -1)
    }

    @Test func standingStillNeverSteps() {
        var p = planter()
        let frames = run(&p, seconds: 5, velocity: .zero)
        #expect(frames.allSatisfy { $0.feet.left.planted && $0.feet.right.planted })
        let first = frames[0].feet
        #expect(frames.allSatisfy { $0.feet.left.position == first.left.position && $0.feet.right.position == first.right.position })
    }

    /// Leaning and swaying inside the threshold is not a reason to step.
    @Test func swayingDoesNotShuffle() {
        var p = planter()
        var hips = SIMD3<Float>.zero
        var steps = 0
        for i in 0..<900 {
            let t = Float(i) * frame
            hips = SIMD3(sin(t * 2) * 0.08, 0, cos(t * 1.3) * 0.08 - 0.08)
            let feet = p.update(hips: hips, forward: SIMD3(0, 0, 1), velocity: .zero,
                                deltaTime: frame, floor: { _ in 0 })
            if !feet.left.planted || !feet.right.planted { steps += 1 }
        }
        #expect(steps == 0, "swaying 8 cm stepped for \(steps) frames")
    }

    /// Stepping sideways once: the feet follow, then settle into their stances.
    @Test func aDisplacementIsTakenInStepsAndSettles() {
        var p = planter()
        _ = run(&p, seconds: 0.1, velocity: .zero)
        _ = run(&p, seconds: 0.5, velocity: SIMD3(0.8, 0, 0))      // 40 cm to the left
        let settled = run(&p, seconds: 2, velocity: .zero, start: SIMD3(0.4, 0, 0))
        let last = settled.last!
        #expect(last.feet.left.planted && last.feet.right.planted)
        #expect(simd_distance(last.feet.left.position, SIMD3(0.5, 0, 0)) < 0.2)
        #expect(simd_distance(last.feet.right.position, SIMD3(0.3, 0, 0)) < 0.2)
    }

    /// The one property that matters most: a foot on the ground holds still.
    @Test func plantedFeetNeverSlide() {
        for velocity in [SIMD3<Float>(0, 0, 1.2), SIMD3(0, 0, -1.0), SIMD3(1.0, 0, 0), SIMD3(-0.7, 0, 0.7)] {
            var p = planter()
            let frames = run(&p, seconds: 4, velocity: velocity)
            for side in 0..<2 {
                var previous: SIMD3<Float>?
                var slip: Float = 0
                for f in frames {
                    let foot = side == 0 ? f.feet.left : f.feet.right
                    if foot.planted {
                        if let previous { slip = max(slip, simd_distance(foot.position, previous)) }
                        previous = foot.position
                    } else { previous = nil }
                }
                #expect(slip < 1e-5, "a planted foot slid \(slip) walking \(velocity)")
            }
        }
    }

    /// Forward, backward, sideways and turning on the spot: the left foot
    /// stays on the body's left. This is what a walk cycle laid along the
    /// travel direction gets wrong the moment a player backpedals.
    @Test func feetNeverCross() {
        let cases: [(String, SIMD3<Float>, Float)] = [
            ("forward", SIMD3(0, 0, 1.2), 0), ("backpedal", SIMD3(0, 0, -1.0), 0),
            ("strafe left", SIMD3(1.0, 0, 0), 0), ("strafe right slow", SIMD3(-0.25, 0, 0), 0),
            ("turn on the spot", .zero, 1.5), ("walk and turn", SIMD3(0, 0, 0.8), -1.0),
        ]
        for (name, velocity, turn) in cases {
            var p = planter()
            let frames = run(&p, seconds: 4, velocity: velocity, turnRate: turn)
            // Planted feet are judged strictly; a swinging foot is held on
            // its side by construction and allowed to approach the midline.
            let worst = frames.map { f in
                min(f.feet.left.planted ? ownSide(f.feet.left, hips: f.hips, forward: f.forward, left: true) : .infinity,
                    f.feet.right.planted ? ownSide(f.feet.right, hips: f.hips, forward: f.forward, left: false) : .infinity)
            }.min()!
            #expect(worst > -0.02, "\(name): a planted foot crossed \(worst) m to the other side")
        }
    }

    /// One foot in the air at a time, and a walk alternates them.
    @Test func aWalkAlternatesOneFootAtATime() {
        var p = planter()
        let frames = run(&p, seconds: 4, velocity: SIMD3(0, 0, 1.2))
        #expect(!frames.contains { !$0.feet.left.planted && !$0.feet.right.planted })
        var order: [Int] = []
        var wasPlanted = (true, true)
        for f in frames {
            if wasPlanted.0 && !f.feet.left.planted { order.append(0) }
            if wasPlanted.1 && !f.feet.right.planted { order.append(1) }
            wasPlanted = (f.feet.left.planted, f.feet.right.planted)
        }
        #expect(order.count >= 6, "only \(order.count) steps in four seconds of walking")
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 != $1 }, "steps did not alternate: \(order)")
    }

    /// Turning on the spot leaves the feet pointing where the body does.
    @Test func turningRealignsTheFeet() {
        var p = planter()
        _ = run(&p, seconds: 1.0, velocity: .zero, turnRate: .pi / 2)       // 90° in a second
        let after = run(&p, seconds: 2, velocity: .zero, facing: .pi / 2)
        let forward = SIMD3<Float>(1, 0, 0)
        let last = after.last!.feet
        #expect(simd_dot(last.left.forward, forward) > cos(0.6))
        #expect(simd_dot(last.right.forward, forward) > cos(0.6))
    }

    /// A teleport does not leave a foot behind.
    @Test func aTeleportReplantsInsteadOfWalkingBack() {
        var p = planter()
        _ = run(&p, seconds: 0.5, velocity: .zero)
        let far = SIMD3<Float>(20, 0, 5)
        let feet = p.update(hips: far, forward: SIMD3(0, 0, 1), velocity: .zero, deltaTime: frame, floor: { _ in 0 })
        #expect(simd_distance(feet.left.position, far) < 0.5 && simd_distance(feet.right.position, far) < 0.5)
    }

    /// A step onto a raised floor lands on it.
    @Test func stepsLandOnTheFloorUnderThem() {
        var p = planter()
        var hips = SIMD3<Float>.zero
        var last: (left: FootPlanter.Placement, right: FootPlanter.Placement)?
        for _ in 0..<360 {
            hips.z += 0.8 * frame
            last = p.update(hips: hips, forward: SIMD3(0, 0, 1), velocity: SIMD3(0, 0, 0.8),
                            deltaTime: frame, floor: { $0.z > 1 ? 0.2 : 0 })
        }
        for _ in 0..<180 {
            last = p.update(hips: hips, forward: SIMD3(0, 0, 1), velocity: .zero,
                            deltaTime: frame, floor: { $0.z > 1 ? 0.2 : 0 })
        }
        #expect(abs(last!.left.position.y - 0.2) < 1e-4 && abs(last!.right.position.y - 0.2) < 1e-4)
    }
}
