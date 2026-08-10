import Testing
import simd
@testable import RAVEInput

/// A hand lying in the XY plane: wrist below the origin, fingers pointing +Y,
/// knuckles spread along X. The palm plane is therefore the XY plane and its
/// two candidate normals are ±Z. `thumbZ` picks the palmar side.
///
/// `indexX`/`littleX` are explicit because their order is what makes a left
/// hand a left hand: on a right hand held palm-toward-you the little finger is
/// to the *left* of the index.
private func flatHand(thumbZ: Float, indexX: Float = -0.03, littleX: Float = 0.03) -> RAVEHandSample {
    func finger(x: Float) -> RAVEFingerJoints {
        RAVEFingerJoints(
            tip: SIMD3(x, 0.10, 0),
            metacarpal: SIMD3(x, 0, 0),
            knuckle: SIMD3(x, 0.04, 0)
        )
    }
    let span = littleX - indexX
    return RAVEHandSample(
        wrist: SIMD3(0, -0.05, 0),
        thumbTip: SIMD3(indexX - span * 0.5, 0.06, thumbZ),
        thumbKnuckle: SIMD3(indexX - span * 0.4, 0.01, thumbZ),
        index: finger(x: indexX),
        middle: finger(x: indexX + span / 3),
        ring: finger(x: indexX + 2 * span / 3),
        little: finger(x: littleX)
    )
}

@Suite("Palm pose")
struct RAVEPalmPoseTests {

    @Test("The palm normal follows the thumb, not a chirality rule")
    func thumbDecidesTheSide() {
        // Same joint layout, thumb on opposite sides — the normal must flip.
        let front = RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: 0.04))
        let back = RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: -0.04))
        let frontNormal = try! #require(front).palmNormalOut
        let backNormal = try! #require(back).palmNormalOut
        #expect(frontNormal.z > 0.9)
        #expect(backNormal.z < -0.9)
    }

    @Test("Mirroring the knuckle order does not flip the normal")
    func chiralityIndependent() {
        // A left hand has its little finger on the other side of the index. The
        // cross product flips with it; the thumb test must undo that, because
        // both hands' thumbs sit on the palmar side.
        let rightish = RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: 0.04, indexX: -0.03, littleX: 0.03))
        let leftish = RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: 0.04, indexX: 0.03, littleX: -0.03))
        #expect(try! #require(rightish).palmNormalOut.z > 0.9)
        #expect(try! #require(leftish).palmNormalOut.z > 0.9)
    }

    @Test("The pose sits over the palm, not on the wrist")
    func positionIsPalmCentre() {
        let pose = try! #require(RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: 0.04)))
        // Midpoint of wrist (y = -0.05) and middle knuckle (y = 0.04).
        #expect(abs(pose.position.y - (-0.005)) < 1e-6)
        #expect(pose.fingersDirection.y > 0.99)
    }

    @Test("A thumb too close to the palm plane reports nothing rather than guessing")
    func edgeOnHandIsUnresolved() {
        // 2 mm is inside the 5 mm evidence threshold.
        #expect(RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: 0.002)) == nil)
    }

    @Test("Degenerate joints report nothing rather than NaN")
    func degenerateSample() {
        var collapsed = flatHand(thumbZ: 0.04)
        collapsed.middle.knuckle = collapsed.wrist
        #expect(RAVEPalmGeometry.palmPose(from: collapsed) == nil)
    }
}

@Suite("Palm facing metrics")
struct RAVEPalmFacingTests {

    private var pose: RAVEPalmPose {
        try! #require(RAVEPalmGeometry.palmPose(from: flatHand(thumbZ: 0.04)))
    }

    @Test("Squarely facing reads 1, edge-on reads 0, away reads -1")
    func plainFacingRange() {
        let centre = pose.position
        #expect(abs(try! #require(RAVEPalmGeometry.facing(pose, towards: centre + SIMD3(0, 0, 1))) - 1) < 1e-5)
        #expect(abs(try! #require(RAVEPalmGeometry.facing(pose, towards: centre + SIMD3(1, 0, 0)))) < 1e-5)
        #expect(abs(try! #require(RAVEPalmGeometry.facing(pose, towards: centre + SIMD3(0, 0, -1))) + 1) < 1e-5)
    }

    @Test("Pitch — a target up the finger axis — collapses the plain metric but not the invariant one")
    func pitchInvarianceIsTheWholeDifference() {
        let centre = pose.position
        // 45° up the finger axis (+Y) while still square on Z.
        let tilted = centre + simd_normalize(SIMD3<Float>(0, 1, 1))

        let plain = try! #require(RAVEPalmGeometry.facing(pose, towards: tilted))
        let invariant = try! #require(RAVEPalmGeometry.pitchInvariantFacing(pose, towards: tilted))

        // A real forgiving-trigger threshold engages at 0.88; the plain metric
        // would have dropped this pose out of the cone, the invariant one keeps it in.
        #expect(plain < 0.75)
        #expect(invariant > 0.99)
    }

    @Test("A sideways swing is rejected by both metrics")
    func sidewaysSwingStillFails() {
        let centre = pose.position
        let sideways = centre + simd_normalize(SIMD3<Float>(1, 0, 0.2))
        #expect(try! #require(RAVEPalmGeometry.facing(pose, towards: sideways)) < 0.3)
        #expect(try! #require(RAVEPalmGeometry.pitchInvariantFacing(pose, towards: sideways)) < 0.3)
    }

    @Test("A target at the palm centre reports nothing")
    func coincidentTarget() {
        #expect(RAVEPalmGeometry.facing(pose, towards: pose.position) == nil)
        #expect(RAVEPalmGeometry.pitchInvariantFacing(pose, towards: pose.position) == nil)
    }
}
