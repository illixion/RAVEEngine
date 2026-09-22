import Foundation
import Testing
import simd
@testable import RAVEInput

private let basis = RAVEPlanarBasis(forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
private let head = SIMD3<Float>(0, 1.6, 0)
private let frame: TimeInterval = 1.0 / 90

/// A hand whose fingers point along `pointing` from `wrist`, curled into a fist
/// (tips 3 cm from their metacarpals) or open (9 cm).
private func hand(at wrist: SIMD3<Float>, fist: Bool,
                  pointing: SIMD3<Float> = SIMD3(0, 0, -1)) -> RAVEHandSample {
    let p = simd_normalize(pointing)
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

/// The finger gun: index out, the other three curled. `twoFinger` holds the
/// middle out alongside the index too.
private func fingerGun(at wrist: SIMD3<Float>, trigger: Bool = false,
                       twoFinger: Bool = false) -> RAVEHandSample {
    var h = hand(at: wrist, fist: true)
    if !trigger {
        let p = simd_normalize(h.index.metacarpal - wrist)
        h.index.tip = h.index.metacarpal + p * 0.09
        if twoFinger { h.middle.tip = h.middle.metacarpal + p * 0.09 }
    }
    return h
}

/// Where the gun hand is held to aim: up in front, still.
private let aimPoint = head + SIMD3<Float>(0.2, -0.25, -0.4)

/// Jog the left arm while the right does `right(t)`.
private func leftJog(_ right: @escaping (TimeInterval) -> RAVEHandSample?)
    -> (TimeInterval) -> (RAVEHandSample?, RAVEHandSample?) {
    { t in
        let (l, _) = jogWrists(t: t, amplitude: 0.15, hertz: 1.5)
        return (hand(at: l, fist: true), right(t))
    }
}

/// A jogging stroke: forward-and-up, back-and-down, the two hands in
/// anti-phase. `amplitude` is the forward reach of a stroke in meters.
private func jogWrists(t: TimeInterval, amplitude: Float, hertz: Float) -> (SIMD3<Float>, SIMD3<Float>) {
    let s = sinf(2 * .pi * hertz * Float(t))
    let stroke = SIMD3<Float>(0, 0.5, -1) * amplitude
    let base = head + SIMD3(0, -0.6, -0.15)
    return (base + SIMD3(-0.2, 0, 0) + stroke * s, base + SIMD3(0.2, 0, 0) - stroke * s)
}

/// Drive a swinger for `seconds`, collecting every frame's output.
private func run(_ swinger: inout RAVEArmSwinger, from start: TimeInterval = 0, seconds: TimeInterval,
                 sample: (TimeInterval) -> (RAVEHandSample?, RAVEHandSample?)) -> [RAVEArmSwingOutput] {
    var out: [RAVEArmSwingOutput] = []
    var t = start
    while t < start + seconds {
        let (l, r) = sample(t)
        out.append(swinger.update(left: l, right: r, headPosition: head, basis: basis, now: t))
        t += frame
    }
    return out
}

private func jog(amplitude: Float = 0.15, hertz: Float = 1.5, fist: Bool = true)
    -> (TimeInterval) -> (RAVEHandSample?, RAVEHandSample?) {
    { t in
        let (l, r) = jogWrists(t: t, amplitude: amplitude, hertz: hertz)
        return (hand(at: l, fist: fist), hand(at: r, fist: fist))
    }
}

@Suite("Arm-swing locomotion")
struct RAVEArmSwingerTests {

    @Test("Jogging with fists engages and walks forward")
    func jogEngages() {
        var swinger = RAVEArmSwinger()
        let out = run(&swinger, seconds: 2, sample: jog())
        let settled = out.suffix(90)
        #expect(settled.allSatisfy { $0.engaged })
        #expect(settled.allSatisfy { $0.speed01 > 0.2 })
        // Head direction: straight ahead, no strafe.
        #expect(settled.allSatisfy { abs($0.vector.x) < 1e-5 && $0.vector.y > 0 })
    }

    @Test("Fists held still do not walk")
    func stillFistsIdle() {
        var swinger = RAVEArmSwinger()
        let out = run(&swinger, seconds: 2) { t in
            let (l, r) = jogWrists(t: 0, amplitude: 0, hertz: 0)
            // A millimetre of tracking jitter.
            let jitter = SIMD3<Float>(0.001, -0.001, 0.001) * sinf(Float(t) * 97)
            return (hand(at: l + jitter, fist: true), hand(at: r - jitter, fist: true))
        }
        #expect(out.allSatisfy { !$0.engaged && $0.speed01 == 0 })
    }

    @Test("Swinging open hands does not walk")
    func openHandsIdle() {
        var swinger = RAVEArmSwinger()
        let out = run(&swinger, seconds: 2, sample: jog(fist: false))
        #expect(out.allSatisfy { !$0.engaged && $0.speed01 == 0 })
    }

    @Test("Swinging harder or faster is never slower")
    func speedMonotonic() {
        func meanSpeed(amplitude: Float, hertz: Float) -> Float {
            var swinger = RAVEArmSwinger()
            let out = run(&swinger, seconds: 3, sample: jog(amplitude: amplitude, hertz: hertz)).suffix(135)
            return out.map(\.speed01).reduce(0, +) / Float(out.count)
        }
        let gentle = meanSpeed(amplitude: 0.10, hertz: 1.2)
        let bigger = meanSpeed(amplitude: 0.18, hertz: 1.2)
        let faster = meanSpeed(amplitude: 0.18, hertz: 1.8)
        #expect(gentle > 0)
        #expect(bigger > gentle)
        #expect(faster > bigger)
    }

    @Test("A brisk jog reaches full deflection and holds it")
    func briskJogSaturates() {
        var swinger = RAVEArmSwinger()
        let out = run(&swinger, seconds: 3, sample: jog(amplitude: 0.2, hertz: 2)).suffix(135)
        #expect(out.contains { $0.speed01 >= 0.99 })
        #expect(out.map(\.speed01).reduce(0, +) / Float(out.count) >= 0.9)
        #expect(out.allSatisfy { simd_length($0.vector) <= 1 + 1e-5 })
    }

    @Test("Losing both fists for a few frames mid-swing keeps walking")
    func fistDropoutSurvives() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let dropout = run(&swinger, from: 2, seconds: 5 * frame, sample: jog(fist: false))
        #expect(dropout.allSatisfy { $0.engaged })
        let after = run(&swinger, from: 2 + 5 * frame, seconds: 0.5, sample: jog())
        #expect(after.allSatisfy { $0.engaged })
    }

    @Test("Losing tracking on both hands briefly keeps walking")
    func trackingDropoutSurvives() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let gap = run(&swinger, from: 2, seconds: 0.15) { _ in (nil, nil) }
        #expect(gap.allSatisfy { $0.engaged && $0.support == .grace })
        let after = run(&swinger, from: 2.15, seconds: 0.5, sample: jog())
        #expect(after.suffix(20).allSatisfy { $0.engaged })
    }

    @Test("The gait carries through the stall at each end of a stroke")
    func noDipAtStrokeEnds() {
        var swinger = RAVEArmSwinger()
        let out = run(&swinger, seconds: 3, sample: jog()).suffix(135)
        let speeds = out.map(\.speed01)
        #expect(speeds.min()! > 0.5 * speeds.max()!)
    }

    @Test("Opening the hands and stopping frees them promptly")
    func stopDisengages() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let stop = run(&swinger, from: 2, seconds: 1) { _ in
            let (l, r) = jogWrists(t: 0, amplitude: 0, hertz: 0)
            return (hand(at: l, fist: false), hand(at: r, fist: false))
        }
        let firstFree = stop.firstIndex { !$0.engaged }
        #expect(firstFree != nil)
        #expect(Double(firstFree ?? .max) * frame < 0.6)
        #expect(stop.last!.speed01 == 0)
    }

    @Test("Both hands flicking up jumps once, and jogging alone never jumps")
    func flickJumps() {
        var swinger = RAVEArmSwinger()
        let jogging = run(&swinger, seconds: 2, sample: jog())
        #expect(!jogging.contains { $0.jumpBegan })

        let base = jogWrists(t: 2, amplitude: 0.15, hertz: 1.5)
        let flick = run(&swinger, from: 2, seconds: 0.15) { t in
            let lift = SIMD3<Float>(0, 2.5 * Float(t - 2), 0)
            return (hand(at: base.0 + lift, fist: true), hand(at: base.1 + lift, fist: true))
        }
        #expect(flick.filter(\.jumpBegan).count == 1)
    }

    @Test("Hands direction follows where the fists point")
    func handsDirection() {
        var swinger = RAVEArmSwinger(direction: .hands)
        let right = SIMD3<Float>(1, 0, 0)
        let out = run(&swinger, seconds: 2) { t in
            let (l, r) = jogWrists(t: t, amplitude: 0.15, hertz: 1.5)
            return (hand(at: l, fist: true, pointing: right), hand(at: r, fist: true, pointing: right))
        }
        let last = out.last!
        #expect(last.engaged)
        #expect(last.vector.x > 0.9 * last.speed01)
        #expect(abs(last.vector.y) < 0.1 * last.speed01)
    }

    @Test("Sensitivity changes the effort, not the top speed")
    func sensitivityScalesEffort() {
        var easy = RAVEArmSwinger(tuning: RAVEArmSwingTuning().scaled(sensitivity: 2))
        var stock = RAVEArmSwinger()
        let gentle = jog(amplitude: 0.1, hertz: 1.2)
        let e = run(&easy, seconds: 3, sample: gentle).suffix(90).map(\.speed01)
        let s = run(&stock, seconds: 3, sample: gentle).suffix(90).map(\.speed01)
        #expect(e.reduce(0, +) > s.reduce(0, +))
        #expect(e.allSatisfy { $0 <= 1 })
    }

    @Test("A finger gun is not a fist, so it can't start a swing")
    func fingerGunCannotEngage() {
        var swinger = RAVEArmSwinger()
        let out = run(&swinger, seconds: 2) { t in
            let (l, r) = jogWrists(t: t, amplitude: 0.15, hertz: 1.5)
            return (hand(at: l, fist: true), fingerGun(at: r))
        }
        #expect(out.allSatisfy { !$0.engaged })
    }

    @Test("Pointing the gun hand mid-run frees it and the other arm keeps running")
    func oneArmCarriesTheRun() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let before = run(&swinger, from: 2, seconds: 0.5, sample: jog()).map(\.speed01)
        let aiming = run(&swinger, from: 2.5, seconds: 2, sample: leftJog { _ in fingerGun(at: aimPoint) })

        // Out within the point hold and a frame or two, never back in.
        let freed = aiming.firstIndex { !$0.rightSwinging }
        #expect(freed != nil)
        #expect(Double(freed ?? .max) * frame < 0.15)
        #expect(aiming.dropFirst(freed ?? 0).allSatisfy { !$0.rightSwinging })
        #expect(aiming.allSatisfy { $0.engaged && $0.leftSwinging })

        // The still gun hand doesn't drag the speed down: it is left out of
        // the mean, so one arm jogging reads as both did.
        let settled = aiming.suffix(90).map(\.speed01)
        let mean = settled.reduce(0, +) / Float(settled.count)
        let beforeMean = before.reduce(0, +) / Float(before.count)
        #expect(mean > 0.8 * beforeMean)
    }

    @Test("A two-finger gun frees the gun hand too, and can't start a swing")
    func twoFingerGun() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let aiming = run(&swinger, from: 2, seconds: 1,
                         sample: leftJog { _ in fingerGun(at: aimPoint, twoFinger: true) })
        let freed = aiming.firstIndex { !$0.rightSwinging }
        #expect(freed != nil)
        #expect(Double(freed ?? .max) * frame < 0.15)
        #expect(aiming.allSatisfy { $0.engaged && $0.leftSwinging })

        var fresh = RAVEArmSwinger()
        let out = run(&fresh, seconds: 2) { t in
            let (l, r) = jogWrists(t: t, amplitude: 0.15, hertz: 1.5)
            return (hand(at: l, fist: true), fingerGun(at: r, twoFinger: true))
        }
        #expect(out.allSatisfy { !$0.engaged })
    }

    @Test("An open hand is not a pointing pose")
    func openHandIsNotPointing() {
        // Swinging open hands can't engage at all, so check the exit instead:
        // an open, still gun hand leaves only by the grace, never at once.
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let open = run(&swinger, from: 2, seconds: 1,
                       sample: leftJog { _ in hand(at: aimPoint, fist: false) })
        let freed = open.firstIndex { !$0.rightSwinging } ?? 0
        #expect(Double(freed) * frame >= 0.2)
    }

    @Test("Firing while running on one arm doesn't pull the gun hand back in")
    func firingStaysFree() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        _ = run(&swinger, from: 2, seconds: 0.5, sample: leftJog { _ in fingerGun(at: aimPoint) })
        // Hold the trigger for a second while sweeping the aim side to side
        // quickly, reversals and all.
        let firing = run(&swinger, from: 2.5, seconds: 1, sample: leftJog { t in
            let sweep = SIMD3<Float>(0.08 * sinf(2 * .pi * 2 * Float(t)), 0, 0)
            return fingerGun(at: aimPoint + sweep, trigger: true)
        })
        #expect(firing.allSatisfy { !$0.rightSwinging && $0.engaged })
    }

    @Test("A gun hand that goes back to swinging a fist rejoins")
    func gunHandRejoins() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        _ = run(&swinger, from: 2, seconds: 0.5, sample: leftJog { _ in fingerGun(at: aimPoint) })
        let back = run(&swinger, from: 2.5, seconds: 1.5, sample: jog())
        let rejoined = back.firstIndex { $0.rightSwinging }
        #expect(rejoined != nil)
        #expect(Double(rejoined ?? 0) * frame >= 0.3)
        #expect(back.suffix(30).allSatisfy { $0.rightSwinging && $0.leftSwinging })
    }

    @Test("Running on one arm, that arm's flick jumps")
    func oneArmFlickJumps() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        let oneArm = run(&swinger, from: 2, seconds: 1, sample: leftJog { _ in fingerGun(at: aimPoint) })
        #expect(!oneArm.contains { $0.jumpBegan })
        let base = jogWrists(t: 3, amplitude: 0.15, hertz: 1.5).0
        let flick = run(&swinger, from: 3, seconds: 0.15) { t in
            (hand(at: base + SIMD3(0, 2.5 * Float(t - 3), 0), fist: true), fingerGun(at: aimPoint))
        }
        #expect(flick.filter(\.jumpBegan).count == 1)
    }

    @Test("Stopping the last swinging arm stops the run")
    func lastArmStops() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        _ = run(&swinger, from: 2, seconds: 0.5, sample: leftJog { _ in fingerGun(at: aimPoint) })
        // Stop where the arm is (a teleport would read as one last stroke).
        let rest = jogWrists(t: 2.5, amplitude: 0.15, hertz: 1.5).0
        let stop = run(&swinger, from: 2.5, seconds: 1) { _ in
            (hand(at: rest, fist: false), fingerGun(at: aimPoint))
        }
        #expect(stop.last.map { !$0.engaged && $0.speed01 == 0 } == true)
    }

    @Test("Reset drops engagement")
    func resetDrops() {
        var swinger = RAVEArmSwinger()
        _ = run(&swinger, seconds: 2, sample: jog())
        #expect(swinger.isEngaged)
        swinger.reset()
        #expect(!swinger.isEngaged)
    }
}
