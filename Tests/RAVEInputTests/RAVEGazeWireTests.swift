import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite struct RAVEGazeWireTests {

    @Test func roundTripsEveryField() throws {
        let s = RAVEGazeSample(sequence: 1234, direction: SIMD3(0.1, -0.2, -0.97),
                               pivot: SIMD2(0.4, 0.6), distance: 1.75)
        let data = RAVEGazeWire.encode(s, providerTime: 98765.4321)
        #expect(data.count == RAVEGazeWire.byteCount)
        let m = try #require(RAVEGazeWire.decode(data, receivedAt: s.receivedAt))
        #expect(m.sample == s)
        #expect(m.providerTime == 98765.4321)
    }

    @Test func missingDistanceStaysMissing() throws {
        let s = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1))
        let m = try #require(RAVEGazeWire.decode(RAVEGazeWire.encode(s, providerTime: 0)))
        #expect(m.sample.distance == nil)
    }

    @Test func rejectsForeignAndShortMessages() {
        #expect(RAVEGazeWire.decode(Data("hello server".utf8)) == nil)
        var d = RAVEGazeWire.encode(RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1)), providerTime: 0)
        #expect(RAVEGazeWire.decode(d.prefix(20)) == nil)
        d[2] = 9
        #expect(RAVEGazeWire.decode(d) == nil)
    }

    @Test func acceptsAppendedFields() {
        var d = RAVEGazeWire.encode(RAVEGazeSample(sequence: 7, direction: SIMD3(0, 0, -1)), providerTime: 1)
        d.append(contentsOf: [1, 2, 3, 4])
        #expect(RAVEGazeWire.decode(d)?.sample.sequence == 7)
    }

    @Test func pushSourceKeepsFirstArrivalOfARepeat() {
        let src = RAVEPushGazeSource()
        let t0 = Date(timeIntervalSince1970: 100)
        let s = RAVEGazeSample(sequence: 5, direction: SIMD3(0, 0, -1))
        #expect(src.ingest(RAVEGazeWire.encode(s, providerTime: 0), receivedAt: t0))
        #expect(src.ingest(RAVEGazeWire.encode(s, providerTime: 0), receivedAt: t0 + 5))
        #expect(src.latest?.receivedAt == t0)
        #expect(src.received == 1)
        #expect(!src.ingest(Data([1, 2, 3])))
    }
}
