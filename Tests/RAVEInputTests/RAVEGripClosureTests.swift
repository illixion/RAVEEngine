import Foundation
import Testing
import simd
@testable import RAVEInput

/// A hand with every finger bent by the same three joint angles (degrees):
/// knuckle, middle joint, end joint. Phalanges 4.5, 2.5 and 2 cm, curling
/// toward +z from a palm pointing up +y.
private func hand(_ knuckle: Float, _ middle: Float, _ end: Float, scale s: Float = 1) -> RAVEHandSample {
    func finger(_ x: Float) -> RAVEFingerJoints {
        let base = SIMD3<Float>(x, 0.08, 0) * s
        var point = base, angle: Float = 0
        for (bend, length) in [(knuckle, Float(0.045)), (middle, 0.025), (end, 0.02)] {
            angle += bend * .pi / 180
            point += SIMD3<Float>(0, cos(angle), sin(angle)) * length * s
        }
        return RAVEFingerJoints(tip: point, metacarpal: SIMD3<Float>(x, 0.01, 0) * s, knuckle: base)
    }
    return RAVEHandSample(wrist: .zero, thumbTip: SIMD3<Float>(-0.05, 0.09, 0.02) * s,
                          thumbKnuckle: SIMD3<Float>(-0.03, 0.04, 0.02) * s,
                          index: finger(-0.02), middle: finger(0), ring: finger(0.02), little: finger(0.04))
}

@Suite("Grip closure")
struct RAVEGripClosureTests {
    @Test("Open, relaxed, holding, gripping and a fist read in order")
    func closureOrder() {
        let open = hand(0, 0, 0).gripClosure
        let relaxed = hand(20, 30, 15).gripClosure
        let holding = hand(40, 50, 30).gripClosure
        let gripping = hand(60, 70, 40).gripClosure
        let fist = hand(90, 100, 70).gripClosure
        #expect(open < 0.01)
        #expect(relaxed > 0.25 && relaxed < 0.45)
        #expect(holding > 0.6 && holding < 0.75)
        #expect(gripping > 0.85)
        #expect(fist == 1)
    }

    @Test("Hand size doesn't change it")
    func scaleFree() {
        #expect(abs(hand(40, 50, 30, scale: 0.8).gripClosure - hand(40, 50, 30, scale: 1.25).gripClosure) < 1e-4)
    }

    @Test("Coincident joints read open")
    func degenerate() {
        var h = hand(60, 70, 40)
        h.index.tip = h.index.knuckle
        #expect(h.gripClosure(.index) == 0)
    }

    @Test("The grip gate holds through a relaxed hand and lets go of an open one")
    func gate() {
        var gate = RAVEGestureGate(tuning: .grip)
        #expect(!gate.update(value: hand(20, 30, 15).gripClosure, now: 0).engaged)
        #expect(gate.update(value: hand(40, 50, 30).gripClosure, now: 0.1).began)
        // Relaxing while holding is not letting go.
        for step in 1...20 { #expect(gate.update(value: hand(20, 30, 15).gripClosure, now: 0.1 + Double(step) * 0.05).engaged) }
        // Opening wide releases after the grace.
        #expect(gate.update(value: hand(0, 5, 0).gripClosure, now: 1.2).engaged)
        #expect(gate.update(value: hand(0, 5, 0).gripClosure, now: 1.31).ended)
    }
}
