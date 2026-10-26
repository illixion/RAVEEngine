import Foundation
import Testing
import simd
@testable import RAVERig

@Suite("Tracked legs")
struct TrackedLegsTests {
    let upright = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    let dt: Float = 1 / 60

    func input(left: SIMD3<Float>?, right: SIMD3<Float>?, floor: Float = 0) -> TrackedLegs.Input {
        TrackedLegs.Input(pelvis: SIMD3(0, 0.92, 0), pelvisRotation: upright,
                          left: left.map { .init(ankle: $0, rotation: upright) },
                          right: right.map { .init(ankle: $0, rotation: upright) }, floor: floor)
    }

    /// A step of the left foot: half a second standing, lifted 10 cm and
    /// carried 40 cm forward over 0.4 s, then standing again. A millimetre of
    /// tracker jitter throughout.
    func leftAnkle(at t: Float, jitter: Float) -> SIMD3<Float> {
        let noise = SIMD3<Float>(sin(t * 91) , cos(t * 77), sin(t * 63)) * jitter
        let s = min(max((t - 0.5) / 0.4, 0), 1)
        let lift = s > 0 && s < 1 ? 0.1 * sin(s * .pi) : 0
        return SIMD3(0.1, 0.08 + lift, 0.4 * (s * s * (3 - 2 * s))) + noise
    }

    @Test("A standing foot is pinned, steps, and is pinned again where it lands")
    func plantsAndSteps() {
        var legs = TrackedLegs()
        var plantedEarly: [SIMD3<Float>] = [], swinging = 0, plantedLate: [SIMD3<Float>] = []
        for i in 0..<120 {
            let t = Float(i) * dt
            let body = legs.update(input(left: leftAnkle(at: t, jitter: 0.001), right: SIMD3(-0.1, 0.08, 0)),
                                   deltaTime: dt)!
            if (0.15..<0.45).contains(t), body.left.planted { plantedEarly.append(body.left.ankle) }
            if (0.6..<0.8).contains(t), !body.left.planted { swinging += 1 }
            if (1.4..<2).contains(t), body.left.planted { plantedLate.append(body.left.ankle) }
        }
        // Down and still: planted, and held to one point despite the jitter.
        #expect(plantedEarly.count > 15)
        #expect(Set(plantedEarly.map { "\($0)" }).count == 1)
        #expect(swinging > 8)
        #expect(plantedLate.count > 30)
        #expect(Set(plantedLate.map { "\($0)" }).count == 1)
        #expect(abs(plantedLate[0].z - 0.4) < 0.01)
    }

    @Test("A foot that pivots far enough is re-planted where it went")
    func drift() {
        var legs = TrackedLegs()
        var last = SIMD3<Float>.zero
        for i in 0..<240 {
            // Creeping 2 cm/s: slow enough to stay down.
            let ankle = SIMD3<Float>(0.1, 0.08, Float(i) * dt * 0.02)
            last = legs.update(input(left: ankle, right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt)!.left.ankle
        }
        #expect(abs(last.z - 0.08) <= legs.tuning.releaseDrift + 0.005)
    }

    @Test("A foot behind the other leg is held, then stops counting as planted")
    func lostFoot() {
        var legs = TrackedLegs()
        for _ in 0..<60 { legs.update(input(left: SIMD3(0.1, 0.08, 0.2), right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt) }
        var body = legs.update(input(left: nil, right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt)!
        #expect(body.left.planted)
        #expect(simd_distance(body.left.ankle, SIMD3(0.1, 0.08, 0.2)) < 1e-4)
        for _ in 0..<30 { body = legs.update(input(left: nil, right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt)! }
        #expect(!body.left.planted)
        #expect(simd_distance(body.left.ankle, SIMD3(0.1, 0.08, 0.2)) < 1e-4)
    }

    @Test("Fades in when tracking starts and out when it stops")
    func fades() {
        var legs = TrackedLegs()
        let first = legs.update(input(left: SIMD3(0.1, 0.08, 0), right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt)!
        #expect(first.weight > 0 && first.weight < 0.2)
        for _ in 0..<30 { legs.update(input(left: SIMD3(0.1, 0.08, 0), right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt) }
        #expect(legs.weight == 1)
        var frames = 0
        while legs.update(nil, deltaTime: dt) != nil { frames += 1 }
        #expect(abs(Float(frames) * dt - legs.tuning.fadeOut) < 2 * dt)
        #expect(legs.lowerBody == nil)
    }

    @Test("Down is measured from the foot's own lowest, not a constant")
    func ownLowest() {
        var legs = TrackedLegs()
        // Someone whose ankle tracker reads 14 cm above the floor standing.
        var body: PerformerLowerBody?
        for _ in 0..<60 { body = legs.update(input(left: SIMD3(0.1, 0.14, 0), right: SIMD3(-0.1, 0.14, 0)), deltaTime: dt) }
        #expect(body?.left.planted == true)
    }

    @Test("One lost foot fades independently and reacquires without a snap")
    func independentFallback() throws {
        var legs = TrackedLegs()
        let fallback = PerformerLowerBody(pelvis: SIMD3(0, 0.9, 0), pelvisRotation: upright,
            left: PerformerFoot(ankle: SIMD3(0.1, 0.08, 1), rotation: upright, planted: false),
            right: PerformerFoot(ankle: SIMD3(-0.1, 0.08, 1), rotation: upright, planted: false), floor: 0)
        for _ in 0..<60 {
            legs.update(input(left: SIMD3(0.1, 0.08, 0), right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt, fallback: fallback)
        }
        var result: PerformerLowerBody?
        for _ in 0..<90 {
            result = legs.update(input(left: nil, right: SIMD3(-0.1, 0.08, 0)), deltaTime: dt, fallback: fallback)
        }
        #expect(legs.leftWeight == 0)
        #expect(legs.rightWeight == 1)
        #expect(try #require(result).left.ankle.z == 1)
        #expect(try #require(result).right.ankle.z == 0)
        let recovery = legs.update(input(left: SIMD3(0.1, 0.2, 0), right: SIMD3(-0.1, 0.08, 0)),
                                   deltaTime: dt, fallback: fallback)
        let recovered = try #require(recovery)
        #expect(recovered.left.ankle.z > 0.9)
    }

    @Test("Repeated polling does not refresh a camera measurement")
    func measurementRate() {
        var legs = TrackedLegs()
        var sample = input(left: SIMD3(0.1, 0.08, 0), right: SIMD3(-0.1, 0.08, 0))
        sample.capturedAt = 1
        for _ in 0..<90 { legs.update(sample, deltaTime: 1 / 90) }
        #expect(legs.leftWeight == 0)
        sample.capturedAt = 2
        legs.update(sample, deltaTime: 1 / 90)
        #expect(legs.leftWeight > 0)
        #expect(legs.leftWeight < 0.1)
    }

    @Test("Mixing hands the legs over without a snap")
    func mix() {
        let a = PerformerLowerBody(pelvis: SIMD3(0, 0.9, 0), pelvisRotation: upright,
                                   left: PerformerFoot(ankle: SIMD3(0.1, 0.08, 0), rotation: upright, planted: true),
                                   right: PerformerFoot(ankle: SIMD3(-0.1, 0.08, 0), rotation: upright, planted: true),
                                   floor: 0, weight: 1, armSwing: 0.4)
        let turned = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        var b = a
        b.pelvis.y = 0.8
        b.pelvisRotation = simd_quatf(vector: -turned.vector)  // the same turn, opposite sign
        b.left.planted = false
        b.armSwing = 0
        let half = PerformerLowerBody.mix(a, b, 0.5)
        #expect(abs(half.pelvis.y - 0.85) < 1e-6)
        #expect(abs(half.pelvisRotation.angle - .pi / 4) < 1e-4)
        #expect(!half.left.planted)
        #expect(PerformerLowerBody.mix(a, b, 0.4).left.planted)
        #expect(PerformerLowerBody.mix(a, b, 0) == a)
        #expect(PerformerLowerBody.mix(a, b, 1) == b)
    }
}
