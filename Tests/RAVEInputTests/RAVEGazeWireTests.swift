import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite struct RAVEGazeWireTests {

    @Test func provenanceSurvivesWireAndOnlyExternalSensorsMayExport() throws {
        for origin in [RAVEGazeOrigin.unknown, .foveatedStreamingProvider, .externalSensor] {
            let sample = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), origin: origin)
            let bytes = RAVEGazeWire.encode(sample, providerTime: 0)
            let decoded = try #require(RAVEGazeWire.decode(bytes))
            #expect(decoded.sample.origin == origin)
            #expect(decoded.sample.origin.allowsApplicationExport == (origin == .externalSensor))
        }
    }

    @Test func providerChannelCannotPromoteExportPermission() throws {
        let source = RAVEPushGazeSource(restrictedToProvider: true)
        let external = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), origin: .externalSensor)
        #expect(source.ingest(RAVEGazeWire.encode(external, providerTime: 5), usesLocalProviderClock: true))
        let stored = try #require(source.latest)
        #expect(stored.origin == .foveatedStreamingProvider)
        #expect(!stored.origin.allowsApplicationExport)
        let relayed = try #require(RAVEGazeWire.decode(RAVEGazeWire.encode(stored, providerTime: 5)))
        #expect(!relayed.sample.origin.allowsApplicationExport)
    }

    @Test func sourceSwitchRetractsExportEvenWhenSequenceRepeats() throws {
        let source = RAVEPushGazeSource()
        source.push(RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), origin: .externalSensor))
        #expect(source.latest?.origin.allowsApplicationExport == true)
        source.push(RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), origin: .foveatedStreamingProvider))
        #expect(source.latest?.origin.allowsApplicationExport == false)
    }

    @Test func unknownWireFlagsNeverGrantExport() throws {
        let sample = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1), origin: .externalSensor)
        var bytes = RAVEGazeWire.encode(sample, providerTime: 0)
        bytes[3] = 0x84  // unknown flag + claimed external sensor
        #expect(try #require(RAVEGazeWire.decode(bytes)).sample.origin == .unknown)
        bytes[3] = 6     // unknown origin value
        #expect(try #require(RAVEGazeWire.decode(bytes)).sample.origin == .unknown)
    }

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
    @Test func captureClockMustBeEstablishedLocally() throws {
        let source = RAVEPushGazeSource()
        let sample = RAVEGazeSample(sequence: 5, direction: SIMD3(0, 0, -1))
        let bytes = RAVEGazeWire.encode(sample, providerTime: 123.5)
        #expect(source.ingest(bytes))
        #expect(source.latest?.localCaptureTime == nil)
        source.reset()
        #expect(source.ingest(bytes, usesLocalProviderClock: true))
        #expect(source.latest?.localCaptureTime == 123.5)
    }

    @Test func resetClearsCaptureTimeAndAcceptsRestartedSequence() {
        let source = RAVEPushGazeSource()
        let sample = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1))
        #expect(source.ingest(RAVEGazeWire.encode(sample, providerTime: 10), usesLocalProviderClock: true))
        // A repeated sequence cannot refresh either capture or receipt time.
        #expect(source.ingest(RAVEGazeWire.encode(sample, providerTime: 20), usesLocalProviderClock: true))
        #expect(source.latest?.localCaptureTime == 10)
        source.reset()
        #expect(source.latest == nil)
        #expect(source.ingest(RAVEGazeWire.encode(sample, providerTime: 30), usesLocalProviderClock: true))
        #expect(source.latest?.localCaptureTime == 30)
    }

    @Test func rejectsInvalidProviderTimestamps() {
        let sample = RAVEGazeSample(sequence: 1, direction: SIMD3(0, 0, -1))
        for time in [Double.nan, .infinity, -1] {
            #expect(RAVEGazeWire.decode(RAVEGazeWire.encode(sample, providerTime: time)) == nil)
        }
    }

}
