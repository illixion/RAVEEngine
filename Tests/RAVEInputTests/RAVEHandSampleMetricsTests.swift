import Testing
import simd
@testable import RAVEInput

/// A hand scaled by `scale`: wrist at the origin, middle knuckle 9 cm up (at
/// scale 1), fingers extended further up, thumb out to the side.
private func hand(scale s: Float = 1, indexCurled: Bool = false,
                  thumbCurled: Bool = false, bunched: Bool = false) -> RAVEHandSample {
    func finger(_ x: Float, curled: Bool = false) -> RAVEFingerJoints {
        let meta = SIMD3<Float>(x, 0.03, 0) * s
        let knuckle = SIMD3<Float>(x, 0.09, 0) * s
        let tip = curled ? SIMD3<Float>(x, 0.08, 0.03) * s : SIMD3<Float>(x, 0.18, 0) * s
        return RAVEFingerJoints(tip: tip, metacarpal: meta, knuckle: knuckle)
    }
    var h = RAVEHandSample(
        wrist: .zero,
        thumbTip: (thumbCurled ? SIMD3<Float>(-0.01, 0.085, 0.02) : SIMD3<Float>(-0.06, 0.1, 0.02)) * s,
        thumbKnuckle: SIMD3<Float>(-0.03, 0.04, 0.02) * s,
        index: finger(-0.02, curled: indexCurled),
        middle: finger(0),
        ring: finger(0.02),
        little: finger(0.04)
    )
    if bunched {
        let point = SIMD3<Float>(0, 0.14, 0.04) * s
        h.thumbTip = point
        for f in RAVEHandFinger.allCases { h[f].tip = point + SIMD3(Float(f.rawValue) * 0.005, 0, 0) * s }
    }
    return h
}

@Suite("Size-normalised hand metrics")
struct RAVEHandSampleMetricsTests {

    @Test("Palm length is wrist to middle knuckle")
    func palmLength() {
        #expect(abs(hand().palmLength - 0.09) < 1e-6)
    }

    @Test("Ratios are the same for a small hand and a large one")
    func scaleInvariant() {
        let small = hand(scale: 0.8), large = hand(scale: 1.25)
        #expect(abs(small.indexExtensionRatio - large.indexExtensionRatio) < 1e-5)
        #expect(abs(small.thumbExtensionRatio - large.thumbExtensionRatio) < 1e-5)
        #expect(abs(small.curlRatio(.ring) - large.curlRatio(.ring)) < 1e-5)
        #expect(abs(small.fingertipSpreadRatio - large.fingertipSpreadRatio) < 1e-5)
        #expect(small.fingertipSpreadToThumb < large.fingertipSpreadToThumb)
    }

    @Test("Extended index reads ~1, curled drops well below")
    func indexExtension() {
        #expect(abs(hand().indexExtensionRatio - 1) < 1e-5)
        #expect(hand(indexCurled: true).indexExtensionRatio < 0.45)
    }

    @Test("A thumb tucked onto the index knuckle reads low")
    func thumbExtension() {
        #expect(hand().thumbExtensionRatio > 0.4)
        #expect(hand(thumbCurled: true).thumbExtensionRatio < 0.3)
    }

    @Test("Fingertips bunched at the thumb read a small spread")
    func spread() {
        #expect(hand(bunched: true).fingertipSpreadToThumb < 0.02)
        #expect(hand().fingertipSpreadToThumb > 0.08)
    }

    @Test("A degenerate hand reports 1 rather than dividing by zero")
    func degenerate() {
        var h = hand()
        h.middle.knuckle = h.wrist
        #expect(h.indexExtensionRatio == 1)
        #expect(h.thumbExtensionRatio == 1)
    }
}
