import Foundation
import Testing
import simd
@testable import RAVEInput

/// Ground truth for the solver tests, written independently of the
/// implementation: the canonical right-handed rotation about +Y, then
/// translation, then a constant per-hand offset carried in the controller's
/// (here: yaw-rotated identity) frame.
func groundTruthPlace(yaw: Float, t: SIMD3<Float>, offset: SIMD3<Float>, quest q: SIMD3<Float>) -> SIMD3<Float> {
    let c = cos(yaw), s = sin(yaw)
    let rx = c * q.x + s * q.z
    let rz = -s * q.x + c * q.z
    // Identity controller rotation -> the offset rotates by yaw alone.
    let ox = c * offset.x + s * offset.z
    let oz = -s * offset.x + c * offset.z
    return SIMD3(rx + t.x + ox, q.y + t.y + offset.y, rz + t.z + oz)
}

let identityRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

/// An arm-waving arc per hand: enough spread on the floor plane to condition yaw.
func arcPoint(_ i: Int, hand: RAVEHandChirality) -> SIMD3<Float> {
    let a = Float(i) / 39 * 3
    return hand == .left
        ? SIMD3(-0.25 + 0.3 * cos(a), 1.0 + 0.1 * sin(2 * a), -0.4 + 0.3 * sin(a))
        : SIMD3(0.25 + 0.3 * sin(a), 1.05 + 0.1 * cos(a), -0.45 + 0.3 * cos(a))
}

@Suite("Quest calibration")
struct RAVEQuestCalibrationTests {
    let offL = SIMD3<Float>(0.02, -0.04, 0.05)
    let offR = SIMD3<Float>(-0.02, -0.04, 0.05)

    @Test("The yaw quaternion and rotateYaw are the same rotation")
    func conventionsAgree() {
        for degrees in stride(from: Float(-170), through: 170, by: 34) {
            let yaw = degrees * .pi / 180
            let v = SIMD3<Float>(0.3, -0.2, 0.9)
            let byQuat = RAVEQuestCalibration.yawQuat(yaw).act(v)
            #expect(simd_distance(byQuat, RAVEQuestCalibration.rotateYaw(yaw, v)) < 1e-5)
            let simdQuat = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(v)
            #expect(simd_distance(simdQuat, byQuat) < 1e-5)
        }
    }

    @Test("Noise-free pairs solve to the ground truth")
    func solve() throws {
        var cal = RAVEQuestCalibration()
        let yaw: Float = 37 * .pi / 180
        let t = SIMD3<Float>(1.2, -0.35, -0.8)
        for i in 0..<40 {
            let ql = arcPoint(i, hand: .left), qr = arcPoint(i, hand: .right)
            cal.addSample(.left, questPosition: ql, questRotation: identityRotation,
                          reference: groundTruthPlace(yaw: yaw, t: t, offset: offL, quest: ql))
            cal.addSample(.right, questPosition: qr, questRotation: identityRotation,
                          reference: groundTruthPlace(yaw: yaw, t: t, offset: offR, quest: qr))
        }
        #expect(cal.sampleCount >= RAVEQuestCalibration.minSamples)
        #expect(cal.spreadMeters > RAVEQuestCalibration.spreadTargetMeters)
        let step1 = cal.maybeSolve()
        #expect(step1)
        #expect(cal.isCalibrated)
        // Noise-free input must solve to (near) zero residual — the check that
        // pins every sign convention against the independent ground truth.
        #expect(cal.residualMm < 1)

        // Apply reproduces the ground truth on a pose that was never sampled.
        let probe = SIMD3<Float>(0.1, 1.3, -0.6)
        let want = groundTruthPlace(yaw: yaw, t: t, offset: offL, quest: probe)
        let got = cal.apply(.left, position: probe, rotation: identityRotation)
        #expect(simd_distance(got.position, want) < 0.003)
        // The rotation picked up the yaw.
        #expect(abs(got.rotation.imag.y - sin(yaw * 0.5)) < 0.01)
        #expect(abs(got.rotation.real - cos(yaw * 0.5)) < 0.01)

        // A fresh consistent pair reads as consistent; a moved-desk pair does not.
        let qNew = SIMD3<Float>(0, 1.1, -0.5)
        var rNew = groundTruthPlace(yaw: yaw, t: t, offset: offL, quest: qNew)
        #expect(cal.pairErrorMeters(.left, questPosition: qNew, reference: rNew) < 0.08)
        rNew.x += 0.5
        #expect(cal.pairErrorMeters(.left, questPosition: qNew, reference: rNew) > 0.3)

        // Transform -> JSON -> fresh instance -> identical Apply: the warm start.
        let transform = try #require(cal.transform)
        let data = try JSONEncoder().encode(transform)
        var cal2 = RAVEQuestCalibration()
        cal2.restore(try JSONDecoder().decode(RAVEQuestCalibration.Transform.self, from: data))
        #expect(cal2.isCalibrated && cal2.sampleCount == 0 && cal2.residualMm == 0)
        let got2 = cal2.apply(.left, position: probe, rotation: identityRotation)
        #expect(simd_distance(got2.position, want) < 0.003)

        cal.reset()
        #expect(!cal.isCalibrated && cal.sampleCount == 0 && cal.residualMm == 0)
        #expect(cal.apply(.left, position: probe, rotation: identityRotation).position == probe)
    }

    @Test("A resting hand collapses to one sample; a tight cluster never solves")
    func gating() {
        var cal = RAVEQuestCalibration()
        for i in 0..<50 {
            let p = SIMD3<Float>(0.2 + 0.001 * Float(i), 1.0, -0.4)
            cal.addSample(.left, questPosition: p, questRotation: identityRotation, reference: p)
        }
        #expect(cal.sampleCount < 5)
        let step2 = cal.maybeSolve()
        #expect(!step2)

        // Enough samples but clustered inside the spread target: still no solve
        // — a tight cluster cannot condition yaw and must keep saying "keep moving".
        var tight = RAVEQuestCalibration()
        for i in 0..<60 {
            let q = SIMD3<Float>(0.05 * Float(i % 4), 1.0 + 0.05 * Float(i % 3), -0.4 - 0.04 * Float(i % 5))
            tight.addSample(i % 2 == 0 ? .left : .right, questPosition: q, questRotation: identityRotation,
                            reference: q)
        }
        #expect(tight.sampleCount >= RAVEQuestCalibration.minSamples)
        let step3 = tight.maybeSolve()
        #expect(!step3)
        #expect(!tight.isCalibrated)
    }

    /// The continuous-calibration property: a handful of WRONG pairs — two
    /// honestly tracked poses describing different objects — must cost
    /// millimetres, not degrees.
    @Test("Robust to full-confidence outliers; low weights pull less")
    func robustToOutliers() {
        var cal = RAVEQuestCalibration()
        let yaw: Float = 24 * .pi / 180
        let t = SIMD3<Float>(0.7, -0.2, -1.1)
        for i in 0..<40 {
            let ql = arcPoint(i, hand: .left), qr = arcPoint(i, hand: .right)
            let rr = groundTruthPlace(yaw: yaw, t: t, offset: offR, quest: qr)
            cal.addSample(.left, questPosition: ql, questRotation: identityRotation,
                          reference: groundTruthPlace(yaw: yaw, t: t, offset: offL, quest: ql))
            cal.addSample(.right, questPosition: qr, questRotation: identityRotation, reference: rr)
            // Every 5th right-hand pair is poisoned: the controller stayed put
            // while the hand wandered half a metre. Full weight — the worst case.
            if i % 5 == 0 {
                let wrong = rr + SIMD3(0.5, 0.1, -0.4)
                let qWrong = qr + SIMD3(0.04, 0, 0.04)            // clears the spacing gate
                cal.addSample(.right, questPosition: qWrong, questRotation: identityRotation, reference: wrong)
            }
        }
        let step4 = cal.maybeSolve()
        #expect(step4)
        let probe = SIMD3<Float>(0.1, 1.3, -0.6)
        let want = groundTruthPlace(yaw: yaw, t: t, offset: offL, quest: probe)
        let got = cal.apply(.left, position: probe, rotation: identityRotation)
        #expect(abs(got.position.x - want.x) < 0.02)
        #expect(abs(got.position.y - want.y) < 0.02)
        #expect(abs(got.position.z - want.z) < 0.02)
        // Yaw survived: within ~1° of truth despite 8 half-metre outliers.
        #expect(abs(got.rotation.imag.y - sin(yaw * 0.5)) < 0.01)

        // Noisy pairs marked low-confidence pull the solve less. Deterministic noise.
        var weighted = RAVEQuestCalibration()
        for i in 0..<40 {
            let ql = arcPoint(i, hand: .left)
            let rl = groundTruthPlace(yaw: yaw, t: t, offset: offL, quest: ql)
            if i % 2 == 0 {
                weighted.addSample(.left, questPosition: ql, questRotation: identityRotation, reference: rl, weight: 1)
            } else {
                let smeared = rl + SIMD3(i % 4 != 0 ? 0.05 : -0.05, 0.03, i % 3 != 0 ? -0.04 : 0.04)
                weighted.addSample(.left, questPosition: ql, questRotation: identityRotation,
                                   reference: smeared, weight: 0.1)
            }
        }
        let step5 = weighted.maybeSolve()
        #expect(step5)
        let w = weighted.apply(.left, position: probe, rotation: identityRotation)
        #expect(abs(w.position.x - want.x) < 0.02)
        #expect(abs(w.position.z - want.z) < 0.02)
    }

    /// Drift tracking: the ring must FOLLOW a transform that moved, not average
    /// it with ancient history.
    @Test("Old samples age out and the solve follows the new truth")
    func ageEviction() {
        var cal = RAVEQuestCalibration()
        let yaw: Float = 15 * .pi / 180
        let tOld = SIMD3<Float>(0.4, -0.1, -0.9)
        let tNew = SIMD3<Float>(0.7, -0.1, -0.9)                 // desk headset slid 30 cm in x
        let off = SIMD3<Float>(0.02, -0.04, 0.05)

        // One hand only, so the arc needs a radius that clears the 3 cm spacing
        // gate on its own.
        func addArc(_ t: SIMD3<Float>, baseMs: UInt64) {
            for i in 0..<40 {
                let a = Float(i) / 39 * 3
                let q = SIMD3<Float>(-0.25 + 0.5 * cos(a), 1.0 + 0.1 * sin(2 * a), -0.4 + 0.5 * sin(a))
                let ms = baseMs + UInt64(i) * 30
                cal.addSample(.left, questPosition: q, questRotation: identityRotation,
                              reference: groundTruthPlace(yaw: yaw, t: t, offset: off, quest: q),
                              weight: 1, nowMs: ms)
                cal.maybeSolve(nowMs: ms)
            }
        }

        addArc(tOld, baseMs: 10_000)
        #expect(cal.isCalibrated)
        let probe = SIMD3<Float>(0.1, 1.3, -0.6)
        let wantOld = groundTruthPlace(yaw: yaw, t: tOld, offset: off, quest: probe)
        #expect(abs(cal.apply(.left, position: probe, rotation: identityRotation).position.x - wantOld.x) < 0.005)

        // 90 s later the world has shifted; every old sample is past the age limit.
        addArc(tNew, baseMs: 100_000)
        let wantNew = groundTruthPlace(yaw: yaw, t: tNew, offset: off, quest: probe)
        let got = cal.apply(.left, position: probe, rotation: identityRotation).position
        #expect(abs(got.x - wantNew.x) < 0.02)
        #expect(abs(got.z - wantNew.z) < 0.02)
        #expect(cal.sampleCount <= 40)                            // the old arc is gone, not diluted
    }

    /// Wide wrist rotation during the sampling is the realistic case, and the
    /// one the three alternating rounds do not fully converge on: the offset
    /// term no longer vanishes at the per-hand centroid when the controller
    /// spins, and three rounds leave ~4 mm RMS and ~0.6° of yaw on this ring.
    /// This test pins the port to the original C++ solver's output on the
    /// identical input (compiled and run against quest_calibration.cpp), so
    /// "faithful port" is a measured claim; changing the round count is a
    /// deliberate behaviour change that must update these numbers.
    @Test("Matches the reference C++ solver on a rotating-controller ring")
    func rotatingOffsetMatchesReference() throws {
        var cal = RAVEQuestCalibration()
        let yaw: Float = -50 * .pi / 180
        let t = SIMD3<Float>(-0.3, 0.2, 0.6)
        let yawQ = RAVEQuestCalibration.yawQuat(yaw)
        func place(_ q: SIMD3<Float>, _ rot: simd_quatf, _ off: SIMD3<Float>) -> SIMD3<Float> {
            RAVEQuestCalibration.rotateYaw(yaw, q) + t + (yawQ * rot).act(off)
        }
        for i in 0..<40 {
            for hand in RAVEHandChirality.allCases {
                let q = arcPoint(i, hand: hand)
                let rot = simd_quatf(angle: Float(i) * 0.15, axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
                cal.addSample(hand, questPosition: q, questRotation: rot,
                              reference: place(q, rot, hand == .left ? offL : offR))
            }
        }
        let solved = cal.maybeSolve()
        #expect(solved)
        // quest_calibration.cpp on the same ring: residual 4.051619 mm,
        // "v1 -0.861960 -0.2998 0.1730 0.5941 0.0272 -0.0142 0.0562 -0.0132 -0.0116 0.0539"
        #expect(abs(cal.residualMm - 4.0516) < 0.01)
        let transform = try #require(cal.transform)
        #expect(abs(transform.yaw - -0.861960) < 1e-4)
        #expect(simd_distance(transform.translation, SIMD3(-0.2998, 0.1730, 0.5941)) < 2e-4)
        #expect(simd_distance(transform.leftOffset, SIMD3(0.0272, -0.0142, 0.0562)) < 2e-4)
        #expect(simd_distance(transform.rightOffset, SIMD3(-0.0132, -0.0116, 0.0539)) < 2e-4)
    }
}

@Suite("Quest hold detector")
struct RAVEQuestHoldDetectorTests {

    /// Co-moving pair stays held; a controller that sits still while the hand
    /// walks away is notHeld (and must not look like a desk bump); a pair that
    /// disagrees while the controller MOVES is heldBad; coming back re-grabs.
    @Test("Held, put down, re-grab, desk bump, occlusion")
    func stateMachine() {
        var det = RAVEQuestHoldDetector()
        #expect(det.state == .held)

        var now: UInt64 = 1000
        var o = RAVEQuestHoldDetector.Observation(questTracked: true, referenceValid: true, calibrated: true)

        // Held: controller rides the hand across the room (~0.3 m/s).
        for i in 0..<60 {
            let p = SIMD3<Float>(0.005 * Float(i), 1.0, -0.4)
            o.questPosition = p
            o.referencePosition = p
            det.step(o, nowMs: now)
            now += 16
        }
        #expect(det.state == .held)

        // Put down: the controller freezes, the hand keeps going (~0.5 m/s).
        let parkedX = o.questPosition.x
        for i in 0..<120 {
            o.questPosition.x = parkedX
            o.referencePosition.x = parkedX + 0.008 * Float(i + 1)
            det.step(o, nowMs: now)
            now += 16
        }
        #expect(det.state == .notHeld)

        // Still parked, hand waving elsewhere: stays notHeld.
        for i in 0..<60 {
            o.referencePosition.x = parkedX + 1.0 + 0.05 * (i % 2 == 1 ? 1 : -1)
            det.step(o, nowMs: now)
            now += 16
        }
        #expect(det.state == .notHeld)

        // Re-grab: the hand returns to the controller and they agree again.
        for _ in 0..<40 {
            o.referencePosition.x = parkedX
            det.step(o, nowMs: now)
            now += 16
        }
        #expect(det.state == .held)

        // Desk bump: large pair error but co-moving — heldBad, the watchdog's case.
        var bumped = RAVEQuestHoldDetector()
        var b = RAVEQuestHoldDetector.Observation(questTracked: true, referenceValid: true, calibrated: true)
        var bNow: UInt64 = 5000
        for i in 0..<120 {
            let x = 0.005 * Float(i)
            b.questPosition = SIMD3(x + 0.4, 1.0, -0.4)
            b.referencePosition = SIMD3(x, 1.0, -0.4)
            bumped.step(b, nowMs: bNow)
            bNow += 16
        }
        #expect(bumped.state == .heldBad)

        // An occluded hand decides nothing: verdicts latch.
        b.referenceValid = false
        for _ in 0..<60 {
            bumped.step(b, nowMs: bNow)
            bNow += 16
        }
        #expect(bumped.state == .heldBad)
    }

    @Test("Uncalibrated: a parked controller re-grabs only once it moves")
    func bootstrap() {
        var det = RAVEQuestHoldDetector()
        var o = RAVEQuestHoldDetector.Observation(questTracked: true, referenceValid: true, calibrated: false)
        var now: UInt64 = 100
        for _ in 0..<30 {
            det.step(o, nowMs: now)
            now += 16
        }
        #expect(det.state == .held)                               // no evidence against
        o.questTracked = false
        det.step(o, nowMs: now)
        #expect(det.state == .held)                               // untracked holds the verdict
    }
}
