import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite struct RAVEGazeSourceTests {

    @Test func parsesStandInJSON() throws {
        let json = #"{"frames":9,"latest":{"t":1.5,"seq":42,"pivot":[0.464,0.577],"direction":[0.1,0.0,-0.99],"fov":[-1,1,1,-1]}}"#
        let s = try #require(RAVEHTTPGazeSource.parse(Data(json.utf8)))
        #expect(s.sequence == 42)
        #expect(abs(s.pivot.x - 0.464) < 1e-5)
        #expect(abs(s.direction.z + 0.99) < 1e-5)
    }

    @Test func rejectsMissingReading() {
        #expect(RAVEHTTPGazeSource.parse(Data(#"{"frames":0,"latest":null}"#.utf8)) == nil)
        #expect(RAVEHTTPGazeSource.parse(Data("nope".utf8)) == nil)
    }

    @Test func coneHitAndMiss() {
        let now = Date()
        let ahead = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), receivedAt: now)
        #expect(RAVEGazeTarget.isLookedAt(ahead, point: SIMD3(0.05, 0, -1), cone: 8, now: now))
        #expect(!RAVEGazeTarget.isLookedAt(ahead, point: SIMD3(1, 0, -1), cone: 8, now: now))
    }

    @Test func staleOrMissingSampleIsNotLooking() {
        let now = Date()
        let old = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), receivedAt: now - 2)
        #expect(!RAVEGazeTarget.isLookedAt(old, point: SIMD3(0, 0, -1), now: now))
        #expect(!RAVEGazeTarget.isLookedAt(nil, point: SIMD3(0, 0, -1), now: now))
    }

    @Test func pointAtOriginHasNoAngle() {
        #expect(RAVEGazeTarget.angleDegrees(gaze: SIMD3(0, 0, -1), to: .zero) == nil)
    }
}
