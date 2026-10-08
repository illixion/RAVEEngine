import Testing
import simd
@testable import RAVERig

/// A leg that can reach a metre from its hip, with the hip a metre-ish up:
/// the horizontal room under it is about 0.6 m, so a stride the stepper
/// would place at half a metre ahead is out of reach for a foot that is
/// already off to one side.
private func reachingStepper() -> LegStepper {
    var stepper = LegStepper(stepLength: 0.8, footSpacing: 0.3,
                             reach: 1.0, hipDrop: 0.95)
    stepper.reset()
    return stepper
}

private func distanceFromHip(_ p: SIMD3<Float>, hips: SIMD3<Float>, across: SIMD3<Float>, foot: Int,
                             hipDrop: Float) -> Float {
    let side = across * 0.15 * (foot == 0 ? 1 : -1)
    let hip = hips + side + SIMD3<Float>(0, hipDrop, 0)
    return simd_length(p - hip)
}

@Test func everyPlacementIsWithinTheLegsReach() {
    var stepper = reachingStepper()
    let dt: Float = 1.0 / 90
    var hips = SIMD3<Float>.zero
    var worst: Float = 0
    for frame in 0..<900 {
        // Straight for two seconds, then a turn, then straight again.
        let turning = (frame / 180) % 2 == 1
        let heading = turning ? Float(frame % 180) * 0.02 : 0
        let forward = SIMD3<Float>(sin(heading), 0, cos(heading))
        let travelled: Float = 0.7 * dt
        hips += forward * travelled
        let placed = stepper.step(hips: hips, forward: forward, travelled: travelled,
                                  floor: { _ in 0 })
        let across = simd_normalize(SIMD3<Float>(forward.z, 0, -forward.x))
        for (foot, placement) in [placed.left, placed.right].enumerated() {
            let d = distanceFromHip(placement.position, hips: hips, across: across, foot: foot, hipDrop: 0.95)
            worst = max(worst, d)
        }
    }
    #expect(worst <= 1.0 + 1e-3, "a foot was asked for \(worst) m from the hip; the leg reaches 1 m")
}

@Test func aPlantedFootSlidesOnlyAsFarAsTheBodyMoves() {
    var stepper = reachingStepper()
    let dt: Float = 1.0 / 90
    var hips = SIMD3<Float>.zero
    var previous: [SIMD3<Float>?] = [nil, nil]
    var worstSlide: Float = 0
    for _ in 0..<600 {
        let forward = SIMD3<Float>(0, 0, 1)
        let travelled: Float = 0.7 * dt
        hips += forward * travelled
        let placed = stepper.step(hips: hips, forward: forward, travelled: travelled,
                                  floor: { _ in 0 })
        for (foot, placement) in [placed.left, placed.right].enumerated() {
            if placement.planted, let last = previous[foot] {
                worstSlide = max(worstSlide, simd_distance(placement.position, last))
            }
            previous[foot] = placement.planted ? placement.position : nil
        }
    }
    // The body covers 0.7 m/s, so a foot held in place while it is reached
    // out of may move no more than the body does in a frame.
    #expect(worstSlide < 0.02, "a planted foot moved \(worstSlide) m in one frame")
}

/// A walk that stops with a foot in the air brings that foot straight down.
/// The old settle restarted its lift from the ground and jumped the foot up
/// by the lift height before it landed.
@Test func aFootLeftInTheAirComesDownWithoutRising() {
    var stepper = reachingStepper()
    let dt: Float = 1.0 / 90
    var hips = SIMD3<Float>.zero
    let forward = SIMD3<Float>(0, 0, 1)
    // Walk until a foot is well into its swing, then stop.
    var airborne: LegStepper.Placement?
    var airFoot = 0
    for _ in 0..<600 {
        hips += forward * 0.7 * dt
        let placed = stepper.step(hips: hips, forward: forward, travelled: 0.7 * dt, floor: { _ in 0 })
        for (foot, p) in [placed.left, placed.right].enumerated() where !p.planted {
            if let progress = p.swingProgress, progress > 0.5 { airborne = p; airFoot = foot }
        }
        if airborne != nil { break }
    }
    #expect(airborne != nil, "the walk should have a foot in the air to stop with")
    var previousY = airborne?.position.y ?? 0
    var rose: Float = 0
    for _ in 0..<60 {
        let settled = stepper.settle(hips: hips, forward: forward, closing: 0.7 * dt, floor: { _ in 0 })
        let p = airFoot == 0 ? settled.left : settled.right
        rose = max(rose, p.position.y - previousY)
        previousY = p.position.y
    }
    #expect(rose < 0.002, "the airborne foot rose \(rose) m after the walk stopped")
}
