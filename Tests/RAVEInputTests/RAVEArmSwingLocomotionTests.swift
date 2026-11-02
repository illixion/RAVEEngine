import Foundation
import Testing
import simd
@testable import RAVEInput

private let basis = RAVEPlanarBasis(forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
private let head = SIMD3<Float>(0, 1.6, 0)
private let frame: TimeInterval = 1.0 / 90

/// A hand whose fingers point forward from `wrist`, curled into a fist
/// (tips 3 cm from their metacarpals) or open (9 cm).
private func hand(at wrist: SIMD3<Float>, fist: Bool) -> RAVEHandSample {
    let p = SIMD3<Float>(0, 0, -1)
    let meta = wrist + p * 0.03
    let knuckle = wrist + p * 0.09
    let reach: Float = fist ? 0.03 : 0.09
    func finger(_ side: Float) -> RAVEFingerJoints {
        let offset = SIMD3<Float>(side, 0, 0)
        return RAVEFingerJoints(tip: meta + offset + p * reach, metacarpal: meta + offset,
                                knuckle: knuckle + offset)
    }
    return RAVEHandSample(wrist: wrist, thumbTip: wrist + SIMD3(0.05, 0.03, -0.04),
                          thumbKnuckle: wrist + SIMD3(0.03, 0.01, -0.02),
                          index: finger(-0.02), middle: finger(0),
                          ring: finger(0.02), little: finger(0.04))
}

/// A jogging stroke: forward-and-up, back-and-down, the hands in anti-phase.
private func jogWrists(t: TimeInterval) -> (SIMD3<Float>, SIMD3<Float>) {
    let s = sinf(2 * .pi * 1.5 * Float(t))
    let stroke = SIMD3<Float>(0, 0.5, -1) * 0.15
    let base = head + SIMD3(0, -0.6, -0.15)
    return (base + SIMD3(-0.2, 0, 0) + stroke * s, base + SIMD3(0.2, 0, 0) - stroke * s)
}

private func jog(_ locomotion: inout RAVEArmSwingLocomotion, from start: TimeInterval = 0,
                 seconds: TimeInterval, active: Bool = true, gunHand: RAVEHandChirality = .right) -> TimeInterval {
    var t = start
    while t < start + seconds {
        let (l, r) = jogWrists(t: t)
        locomotion.update(active: active, left: hand(at: l, fist: true), right: hand(at: r, fist: true),
                          headPosition: head, basis: basis, gunHand: gunHand, now: t)
        t += frame
    }
    return t
}

@Suite("Arm-swing locomotion option")
struct RAVEArmSwingLocomotionTests {

    @Test("It is off until a game turns it on")
    func offByDefault() {
        var locomotion = RAVEArmSwingLocomotion()
        #expect(!locomotion.isEnabled)
        _ = jog(&locomotion, seconds: 2)
        #expect(!locomotion.output.engaged)
        #expect(locomotion.output.speed01 == 0)
        #expect(!locomotion.wantsHand(.left) && !locomotion.wantsHand(.right))
    }

    @Test("Enabled, a jog engages and both swinging hands are wanted")
    func enabledEngages() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true)
        _ = jog(&locomotion, seconds: 2)
        #expect(locomotion.output.engaged)
        #expect(locomotion.output.speed01 > 0.2)
        #expect(locomotion.wantsHand(.left) && locomotion.wantsHand(.right))
    }

    @Test("Switching it off mid-run stands the swing down at once")
    func disableStopsIt() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true)
        let t = jog(&locomotion, seconds: 2)
        #expect(locomotion.output.engaged)
        locomotion.isEnabled = false
        _ = jog(&locomotion, from: t, seconds: 0.05)
        #expect(!locomotion.output.engaged)
        #expect(!locomotion.wantsHand(.left) && !locomotion.wantsHand(.right))
    }

    @Test("Another owner of locomotion (active false) resets it, and it re-engages from scratch")
    func inactiveResets() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true)
        var t = jog(&locomotion, seconds: 2)
        #expect(locomotion.output.engaged)
        t = jog(&locomotion, from: t, seconds: 0.1, active: false)
        #expect(!locomotion.output.engaged)
        // The swing has to build up again, so it is not engaged on the very next frame.
        _ = jog(&locomotion, from: t, seconds: frame)
        #expect(!locomotion.output.engaged)
        _ = jog(&locomotion, from: t + frame, seconds: 2)
        #expect(locomotion.output.engaged)
    }

    @Test("Before a run starts, the gun hand is wanted once its partner is a fist")
    func gunHandWantedWhileEntering() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true)
        let still = head + SIMD3<Float>(0.2, -0.6, -0.3)
        // Right is the gun hand, open; the left partner is a still fist: no swing yet.
        locomotion.update(active: true,
                          left: hand(at: still - SIMD3(0.4, 0, 0), fist: true),
                          right: hand(at: still, fist: false),
                          headPosition: head, basis: basis, gunHand: .right, now: 0)
        #expect(!locomotion.output.engaged)
        #expect(locomotion.wantsHand(.right))
        #expect(!locomotion.wantsHand(.left))
    }

    @Test("An open partner hand does not hold the gun hand")
    func openPartnerDoesNotHold() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true)
        let still = head + SIMD3<Float>(0.2, -0.6, -0.3)
        locomotion.update(active: true,
                          left: hand(at: still - SIMD3(0.4, 0, 0), fist: false),
                          right: hand(at: still, fist: false),
                          headPosition: head, basis: basis, gunHand: .right, now: 0)
        #expect(!locomotion.wantsHand(.right))
    }

    @Test("Sensitivity changes the effort needed, not the top speed")
    func sensitivityAffectsEffortOnly() {
        func settledSpeed(sensitivity: Float) -> Float {
            var locomotion = RAVEArmSwingLocomotion(isEnabled: true, sensitivity: sensitivity)
            _ = jog(&locomotion, seconds: 3)
            return locomotion.output.speed01
        }
        let easy = settledSpeed(sensitivity: 2)
        let hard = settledSpeed(sensitivity: 0.5)
        #expect(easy >= hard)
        #expect(easy <= 1)
    }

    @Test("Following the hands walks where the fists point rather than where the head faces")
    func followsHandsOption() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true, followsHands: true)
        _ = jog(&locomotion, seconds: 2)
        #expect(locomotion.output.engaged)
        // Fists point straight ahead, as the head does: still forward.
        #expect(locomotion.output.vector.y > 0)
    }

    @Test("Reset drops the output and the fist reading")
    func resetClears() {
        var locomotion = RAVEArmSwingLocomotion(isEnabled: true)
        _ = jog(&locomotion, seconds: 2)
        locomotion.reset()
        #expect(!locomotion.output.engaged)
        #expect(!locomotion.wantsHand(.left) && !locomotion.wantsHand(.right))
    }
}
