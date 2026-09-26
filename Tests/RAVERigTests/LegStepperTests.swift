import Testing
import simd
@testable import RAVERig

/// The stepper exists for one property: a foot on the ground does not move
/// while the body walks over it. Everything else is detail.
@Suite struct LegStepperTests {

    /// Walks a body forward and returns every placement handed out.
    private func walk(_ stepper: inout LegStepper, metres: Float, perFrame: Float)
        -> [(left: LegStepper.Placement, right: LegStepper.Placement)] {
        var out: [(left: LegStepper.Placement, right: LegStepper.Placement)] = []
        var hips = SIMD3<Float>(0, 0, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        var covered: Float = 0
        while covered < metres {
            hips += forward * perFrame
            covered += perFrame
            out.append(stepper.step(hips: hips, forward: forward, travelled: perFrame,
                                    floor: { _ in 0 }))
        }
        return out
    }

    @Test func aPlantedFootDoesNotMove() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.3)
        let frames = walk(&stepper, metres: 3, perFrame: 0.01)
        // Walk through each run of consecutive planted frames and check the
        // position never changes within it.
        for side in 0..<2 {
            var previous: SIMD3<Float>?
            var slips: [Float] = []
            for frame in frames {
                let placement = side == 0 ? frame.left : frame.right
                if placement.planted {
                    if let previous { slips.append(simd_length(placement.position - previous)) }
                    previous = placement.position
                } else {
                    previous = nil
                }
            }
            #expect(!slips.isEmpty, "the foot never planted at all")
            #expect(slips.allSatisfy { $0 < 1e-5 },
                    "a planted foot moved by up to \(slips.max() ?? 0) m")
        }
    }

    /// Both feet planted at once for part of the cycle, never neither.
    @Test func theFeetAlternateAndOverlap() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.3)
        let frames = walk(&stepper, metres: 3, perFrame: 0.01)
        let airborne = frames.filter { !$0.left.planted && !$0.right.planted }
        let doubled = frames.filter { $0.left.planted && $0.right.planted }
        #expect(airborne.isEmpty, "a walk never has both feet off the ground")
        #expect(!doubled.isEmpty, "a walk has both feet down for part of its cycle")
        #expect(frames.contains { $0.left.planted && !$0.right.planted })
        #expect(frames.contains { !$0.left.planted && $0.right.planted })
    }

    /// Standing still must not shuffle: no distance, no stepping.
    @Test func standingStillDoesNotStep() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.3)
        var seen: Set<String> = []
        for _ in 0..<120 {
            let frame = stepper.step(hips: .zero, forward: SIMD3<Float>(0, 0, -1),
                                     travelled: 0, floor: { _ in 0 })
            seen.insert("\(frame.left.position) \(frame.right.position)")
        }
        #expect(seen.count == 1, "the feet moved while the body did not")
    }

    /// The swinging foot leaves the ground and comes back to it.
    @Test func theSwingingFootLifts() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.3, liftHeight: 0.07)
        let frames = walk(&stepper, metres: 2, perFrame: 0.01)
        let heights = frames.map(\.left.position.y)
        #expect((heights.max() ?? 0) > 0.03, "the foot never left the floor")
        #expect(frames.filter(\.left.planted).allSatisfy { abs($0.left.position.y) < 1e-5 })
    }

    /// The bug that produced the frozen-leg glide: a walk that ends by
    /// running out of path never resets the stepper, so the next walk's
    /// first stance adopted the previous walk's footprint — metres behind
    /// the character. An honest solver then straightens the leg at a target
    /// it cannot reach and holds it there, and the whole body slides along
    /// with one leg up and both frozen.
    @Test func doesNotPlantWhereTheLastWalkLeftOff() {
        var stepper = LegStepper(stepLength: 0.43, footSpacing: 0.31)
        // Walk a little, so both feet have real plants.
        var hips = SIMD3<Float>(0, 0, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        for _ in 0..<40 {
            hips += forward * 0.02
            _ = stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })
        }
        // Now the character finishes, idles, and starts a new walk two
        // metres away — without anyone resetting the stepper.
        let restart = SIMD3<Float>(2.5, 0, 1.8)
        let placements = stepper.step(hips: restart, forward: forward,
                                      travelled: 0.02, floor: { _ in 0 })
        for (name, placement) in [("left", placements.left), ("right", placements.right)] {
            let offset = SIMD2(placement.position.x - restart.x,
                               placement.position.z - restart.z)
            #expect(simd_length(offset) < 1.2,
                    "\(name) foot placed \(simd_length(offset)) m from the body")
        }
    }

    /// The guard must not fire during an ordinary walk, or it would break
    /// the one property the stepper exists for.
    @Test func keepsPlantingNormallyWhileWalking() {
        var stepper = LegStepper(stepLength: 0.43, footSpacing: 0.31)
        var hips = SIMD3<Float>(0, 0, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        var held: [SIMD3<Float>?] = [nil, nil]
        var slips: [Float] = []
        for _ in 0..<400 {
            hips += forward * 0.01
            let p = stepper.step(hips: hips, forward: forward, travelled: 0.01, floor: { _ in 0 })
            for (i, placement) in [p.left, p.right].enumerated() {
                if placement.planted {
                    if let previous = held[i] { slips.append(simd_distance(previous, placement.position)) }
                    held[i] = placement.position
                } else {
                    held[i] = nil
                }
            }
        }
        #expect(!slips.isEmpty)
        #expect(slips.allSatisfy { $0 < 1e-5 }, "a planted foot moved by \(slips.max() ?? 0) m")
    }
}

@Suite("Turning around")
struct LegStepperTurnTests {

    /// Lateral offset of a point from the hips, positive on this foot's own
    /// side of the body.
    static func sidedness(_ point: SIMD3<Float>, hips: SIMD3<Float>,
                          forward: SIMD3<Float>, foot: Int) -> Float {
        let across = simd_normalize(SIMD3<Float>(forward.z, 0, -forward.x))
        let offset = SIMD3<Float>(point.x - hips.x, 0, point.z - hips.z)
        return simd_dot(offset, across) * (foot == 0 ? 1 : -1)
    }

    /// Turning on the spot must not leave a foot planted across the body.
    ///
    /// A stance foot is pinned in the world on purpose, and the reach guard
    /// only measures distance — after a 180° turn the old plant is still
    /// well within a leg's length of the hips, just on the wrong side of it.
    /// The solver then dutifully reaches across the body for it and the legs
    /// cross, which is visible as the shins clipping through each other.
    @Test func doesNotHoldAFootAcrossTheBodyAfterTurningAround() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.06)
        var hips = SIMD3<Float>(0, 1, 0)
        let outbound = SIMD3<Float>(0, 0, 1)
        for _ in 0..<60 {
            hips += outbound * 0.02
            _ = stepper.step(hips: hips, forward: outbound, travelled: 0.02, floor: { _ in 0 })
        }
        // Turn on the spot and take the next frame facing the other way.
        let back = -outbound
        let after = stepper.step(hips: hips, forward: back, travelled: 0.01, floor: { _ in 0 })
        let left = Self.sidedness(after.left.position, hips: hips, forward: back, foot: 0)
        let right = Self.sidedness(after.right.position, hips: hips, forward: back, foot: 1)
        // A little crossing toward the midline is natural; crossing past it
        // by a quarter of the hip width is the legs swapping places.
        #expect(left > -0.06)
        #expect(right > -0.06)
    }

    /// The same guard must not fire during ordinary walking, or every plant
    /// is thrown away and the feet slide again.
    @Test func keepsItsPlantsWhileWalkingStraight() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.06)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        var held = 0
        var previous: SIMD3<Float>?
        for _ in 0..<200 {
            hips += forward * 0.02
            let step = stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })
            if step.left.planted, let previous, previous == step.left.position { held += 1 }
            previous = step.left.planted ? step.left.position : nil
        }
        // A stance foot holds still for most of the cycle; if the guard were
        // firing this would collapse toward zero.
        #expect(held > 80)
    }

    /// Turning on the spot must advance the cycle, or no foot ever reaches
    /// touchdown and the plants are never refreshed.
    ///
    /// This is the "stuck behind, then snaps back" the turn produced: with
    /// the cycle frozen through the turn, a plant could only be corrected by
    /// the sidedness guard condemning it, which moves it in a single frame.
    @Test func turningOnTheSpotAdvancesTheCycle() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.06)
        let hips = SIMD3<Float>(0, 1, 0)
        _ = stepper.step(hips: hips, forward: SIMD3(0, 0, 1), travelled: 0, floor: { _ in 0 })
        let before = stepper.coveredDistance
        // Half a turn, in ten frames, without moving an inch.
        for index in 1...10 {
            let angle = Float(index) / 10 * .pi
            let forward = SIMD3<Float>(sin(angle), 0, cos(angle))
            _ = stepper.step(hips: hips, forward: forward, travelled: 0, floor: { _ in 0 })
        }
        // Each foot rides an arc of radius half the hip width, so half a
        // turn is about pi * 0.12 metres of foot travel.
        let advanced = stepper.coveredDistance - before
        #expect(advanced > 0.3)
        #expect(advanced < 0.45)
    }

    /// A swinging foot must not pass through the other leg, which a straight
    /// world-space arc does when its ends are on opposite sides of a turn.
    @Test func aSwingingFootStaysOnItsOwnSide() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.06)
        var hips = SIMD3<Float>(0, 1, 0)
        var worst: Float = .greatestFiniteMagnitude
        for index in 0..<120 {
            // Walk while turning steadily through 180 degrees.
            let angle = Float(index) / 120 * .pi
            let forward = SIMD3<Float>(sin(angle), 0, cos(angle))
            hips += forward * 0.015
            let step = stepper.step(hips: hips, forward: forward,
                                    travelled: 0.015, floor: { _ in 0 })
            for (foot, placement) in [(0, step.left), (1, step.right)] {
                worst = min(worst, LegStepperTurnTests.sidedness(
                    placement.position, hips: hips, forward: forward, foot: foot))
            }
        }
        // Slightly past the midline is allowed; the other leg's side is not.
        #expect(worst > -0.04)
    }

    /// The swing arc must come down longer than it goes up, so the foot
    /// descends into a landing rather than dropping off a symmetric peak.
    @Test func theSwingArcPeaksEarly() throws {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.1)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        // One swing at a time: a run of frames with the foot off the
        // ground. Concatenating several and indexing across the lot measures
        // nothing, which is what the first version of this test did.
        var swings: [[Float]] = []
        var current: [Float] = []
        for _ in 0..<400 {
            hips += forward * 0.004
            let step = stepper.step(hips: hips, forward: forward,
                                    travelled: 0.004, floor: { _ in 0 })
            if step.left.planted {
                if !current.isEmpty { swings.append(current); current = [] }
            } else {
                current.append(step.left.position.y)
            }
        }
        // The second complete swing, so the first partial one is skipped.
        let swing = try #require(swings.dropFirst().first)
        #expect(swing.count > 10)
        let peak = swing.firstIndex(of: swing.max()!)!
        // The apex lands in the first half of the swing, leaving a longer
        // descent into the landing than the rise out of the takeoff.
        #expect(Float(peak) / Float(swing.count) < 0.45)
    }
}

@Suite("Settling to a stop")
struct LegStepperSettleTests {

    /// A walk that just stops leaves the feet mid-stride, and handing that
    /// to the idle clip is a visible shuffle. Settling closes the trailing
    /// foot up first, so the pose handed over is already a standing one.
    @Test func bringsTheFeetTogetherAfterAWalk() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        for _ in 0..<73 {
            hips += forward * 0.02
            _ = stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })
        }
        var result = stepper.settle(hips: hips, forward: forward,
                                    closing: 0, floor: { _ in 0 })
        let spreadBefore = abs(result.left.position.z - result.right.position.z)
        #expect(spreadBefore > 0.1)   // genuinely mid-stride

        var frames = 0
        while !result.settled, frames < 400 {
            result = stepper.settle(hips: hips, forward: forward,
                                    closing: 0.01, floor: { _ in 0 })
            frames += 1
        }
        #expect(result.settled)
        #expect(frames < 200)
        // Both feet level with the hips, one on each side. Asserted per
        // foot against the hips rather than as a spread, because the spread
        // is two tolerances wide and says less than it looks like it does.
        #expect(abs(result.left.position.z - hips.z) < 0.06)
        #expect(abs(result.right.position.z - hips.z) < 0.06)
        #expect(result.left.position.x > hips.x)
        #expect(result.right.position.x < hips.x)
        #expect(result.left.planted && result.right.planted)
        #expect(abs(result.left.position.y) < 0.001)
    }

    /// Only one foot may leave the ground at a time, or the character hops.
    @Test func neverLiftsBothFeetWhileSettling() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        for _ in 0..<50 {
            hips += forward * 0.02
            _ = stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })
        }
        var result = (left: LegStepper.Placement(position: .zero, planted: true),
                      right: LegStepper.Placement(position: .zero, planted: true),
                      settled: false)
        var frames = 0
        repeat {
            result = stepper.settle(hips: hips, forward: forward,
                                    closing: 0.008, floor: { _ in 0 })
            #expect(result.left.planted || result.right.planted)
            frames += 1
        } while !result.settled && frames < 400
        #expect(result.settled)
    }

    /// Settling when already standing must do nothing rather than inventing
    /// a step, or stopping twice shuffles.
    @Test func doesNothingWhenAlreadyStanding() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        let hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        let first = stepper.settle(hips: hips, forward: forward,
                                   closing: 0.01, floor: { _ in 0 })
        #expect(first.settled)
        let second = stepper.settle(hips: hips, forward: forward,
                                    closing: 0.01, floor: { _ in 0 })
        #expect(second.settled)
        #expect(second.left.position == first.left.position)
    }

    /// A swinging foot reports where it is in its swing, so the caller can
    /// roll it through the step rather than guessing from its height.
    @Test func aSwingingFootReportsItsProgress() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        var seen: [Float] = []
        for _ in 0..<200 {
            hips += forward * 0.01
            let step = stepper.step(hips: hips, forward: forward,
                                    travelled: 0.01, floor: { _ in 0 })
            if let progress = step.left.swingProgress {
                #expect(!step.left.planted)
                seen.append(progress)
            } else {
                #expect(step.left.planted)
            }
        }
        #expect(seen.contains { $0 < 0.2 })
        #expect(seen.contains { $0 > 0.8 })
        #expect(seen.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}

/// How a walk ends and how the next one begins. Each of these was a visible
/// jump on the headset first: the foot in the air when the path ran out
/// snapped back to its last footprint, the leading foot took a step
/// backward to square up, and a new walk threw both feet half a step ahead
/// in a single frame.
@Suite("Stopping and starting")
struct LegStepperStopStartTests {

    private func positions(_ p: (left: LegStepper.Placement, right: LegStepper.Placement)) -> [SIMD3<Float>] {
        [p.left.position, p.right.position]
    }

    /// Largest distance either foot moved between two consecutive frames.
    private func largestJump(_ frames: [[SIMD3<Float>]]) -> Float {
        var worst: Float = 0
        for (a, b) in zip(frames, frames.dropFirst()) {
            worst = max(worst, simd_distance(a[0], b[0]), simd_distance(a[1], b[1]))
        }
        return worst
    }

    @Test func aFootCaughtInTheAirFinishesItsStepInsteadOfSnappingBack() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        var last = stepper.step(hips: hips, forward: forward, travelled: 0, floor: { _ in 0 })
        // Walk until a foot is well off the ground.
        var guardCount = 0
        repeat {
            hips += forward * 0.02
            last = stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })
            guardCount += 1
        } while max(last.left.position.y, last.right.position.y) < 0.04 && guardCount < 400
        #expect(max(last.left.position.y, last.right.position.y) >= 0.04, "never caught a foot in the air")

        var frames = [positions(last)]
        var result = stepper.settle(hips: hips, forward: forward, closing: 0.02, floor: { _ in 0 })
        frames.append(positions((result.left, result.right)))
        var count = 0
        while !result.settled, count < 400 {
            result = stepper.settle(hips: hips, forward: forward, closing: 0.02, floor: { _ in 0 })
            frames.append(positions((result.left, result.right)))
            count += 1
        }
        #expect(result.settled)
        // A swing covers about 3.6x the hip travel per frame; a snap back to
        // the footprint would be a whole step.
        let jump = largestJump(frames)
        #expect(jump < 0.1, "a foot jumped \(jump) m in one frame while settling")
    }

    @Test func theLastStepLandsOnTheDestinationAndNoFootStepsBackward() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        let destination = SIMD3<Float>(0, 1, 1.73)
        stepper.beginWalk()
        var frames: [[SIMD3<Float>]] = []
        while hips.z < destination.z - 1e-4 {
            let step = min(0.02, destination.z - hips.z)
            hips += forward * step
            let p = stepper.step(hips: hips, forward: forward, travelled: step,
                                 remaining: destination.z - hips.z, floor: { _ in 0 })
            frames.append(positions(p))
        }
        // No landing past the destination.
        for frame in frames {
            #expect(frame[0].z <= destination.z + 1e-3, "left foot landed \(frame[0].z - destination.z) m past the end")
            #expect(frame[1].z <= destination.z + 1e-3, "right foot landed \(frame[1].z - destination.z) m past the end")
        }
        var result = stepper.settle(hips: hips, forward: forward, closing: 0.02, floor: { _ in 0 })
        frames.append(positions((result.left, result.right)))
        var count = 0
        while !result.settled, count < 400 {
            result = stepper.settle(hips: hips, forward: forward, closing: 0.02, floor: { _ in 0 })
            frames.append(positions((result.left, result.right)))
            count += 1
        }
        #expect(result.settled)
        // Settling only ever moves a foot forward, or nowhere: the backward
        // shuffle is what a landing past the destination produced.
        var backward: Float = 0
        for (a, b) in zip(frames, frames.dropFirst()) {
            backward = max(backward, a[0].z - b[0].z, a[1].z - b[1].z)
        }
        #expect(backward < 0.02, "a foot moved \(backward) m backward while stopping")
        #expect(abs(result.left.position.z - hips.z) < 0.15)
        #expect(abs(result.right.position.z - hips.z) < 0.15)
        #expect(largestJump(frames) < 0.1)
    }

    @Test func aNewWalkStartsFromWhereTheFeetStand() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        let hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        var standing = stepper.settle(hips: hips, forward: forward, closing: 0.02, floor: { _ in 0 })
        var count = 0
        while !standing.settled, count < 400 {
            standing = stepper.settle(hips: hips, forward: forward, closing: 0.02, floor: { _ in 0 })
            count += 1
        }
        let before = positions((standing.left, standing.right))
        stepper.beginWalk()
        var moving = hips + forward * 0.01
        let first = stepper.step(hips: moving, forward: forward, travelled: 0.01, floor: { _ in 0 })
        let after = positions(first)
        #expect(simd_distance(before[0], after[0]) < 1e-4, "left foot jumped \(simd_distance(before[0], after[0])) m at walk start")
        #expect(simd_distance(before[1], after[1]) < 1e-4, "right foot jumped \(simd_distance(before[1], after[1])) m at walk start")
        // And the walk then proceeds normally: a foot lifts within a step.
        var lifted = false
        var frames = [after]
        for _ in 0..<40 {
            moving += forward * 0.01
            let p = stepper.step(hips: moving, forward: forward, travelled: 0.01, floor: { _ in 0 })
            frames.append(positions(p))
            lifted = lifted || !p.left.planted || !p.right.planted
        }
        #expect(lifted)
        #expect(largestJump(frames) < 0.1)
    }

    @Test func aWalkRequestedMidCloseFinishesPuttingTheFootDown() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.24, liftHeight: 0.08)
        var hips = SIMD3<Float>(0, 1, 0)
        let forward = SIMD3<Float>(0, 0, 1)
        for _ in 0..<73 {
            hips += forward * 0.02
            _ = stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })
        }
        // A few slow frames of settling: one foot is now mid-close.
        var last = stepper.settle(hips: hips, forward: forward, closing: 0.004, floor: { _ in 0 })
        for _ in 0..<3 { last = stepper.settle(hips: hips, forward: forward, closing: 0.004, floor: { _ in 0 }) }
        #expect(!(last.left.planted && last.right.planted), "expected a foot mid-close")
        var frames = [positions((last.left, last.right))]
        stepper.beginWalk()
        for _ in 0..<80 {
            hips += forward * 0.02
            frames.append(positions(stepper.step(hips: hips, forward: forward, travelled: 0.02, floor: { _ in 0 })))
        }
        #expect(largestJump(frames) < 0.1, "a foot jumped \(largestJump(frames)) m when a walk began mid-close")
    }

    /// Feet a walk clip left mid-stride come to a stand from where they
    /// are: the airborne one continues from its own position rather than
    /// jumping, the planted one holds until it is its turn, and both end up
    /// standing.
    @Test func takingOverClipFeetSettlesFromWhereTheyAre() {
        var stepper = LegStepper(stepLength: 0.4, footSpacing: 0.3)
        let hips = SIMD3<Float>(0, 0, 0)
        let forward = SIMD3<Float>(0, 0, -1)
        // Foot 0 sits at -x for this heading; it is in the air, ahead.
        let airborne = SIMD3<Float>(-0.15, 0.05, -0.2)
        let planted = SIMD3<Float>(0.15, 0, 0.2)
        stepper.takeOver(left: airborne, right: planted, leftPlanted: false, rightPlanted: true)

        var result = stepper.settle(hips: hips, forward: forward, closing: 0.01, floor: { _ in 0 })
        // One frame of swing: 0.01 of hip travel moves a swinging foot about
        // 0.036, plus the lift arc. A jump back to a footprint would be 0.2+.
        #expect(simd_distance(result.left.position, airborne) < 0.06)
        #expect(result.right.planted)
        #expect(result.right.position == planted)
        var frames = 1
        while !result.settled && frames < 500 {
            result = stepper.settle(hips: hips, forward: forward, closing: 0.01, floor: { _ in 0 })
            frames += 1
        }
        #expect(result.settled)
        #expect(result.left.planted && result.right.planted)
        // Standing: both feet under the hips, about hip-width apart.
        #expect(abs(result.left.position.z) < 0.13 && abs(result.right.position.z) < 0.13)
        #expect(abs(simd_distance(result.left.position, result.right.position) - 0.3) < 0.06)
    }
}
