import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Body reliability")
struct RAVEBodyReliabilityTests {
    @Test("Headset reference wire layout is independent of host endianness")
    func referenceLayout() {
        let head = RAVEBodyTrackerPose(position: SIMD3(0.2, 1.6, -2),
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), confidence: 1)
        let bytes = RAVEBodyStreamProtocol.reference(generation: 123, time: 10, head: head,
            leftWrist: SIMD3(-0.3, 1, -2), rightWrist: nil)
        #expect(bytes.count == 63)
        #expect(Array(bytes.prefix(6)) == Array("PHBS".utf8) + [1, 6])
        var reader = RAVEBodyStreamProtocol.Reader(bytes: bytes, at: 6)
        let generation = reader.u64(), time = reader.f64(), flags = reader.u8(), point = reader.vector()
        let quaternion = (0..<4).map { _ in reader.f32() }
        let wrist = reader.vector()
        #expect(generation == 123)
        #expect(time == 10)
        #expect(flags == 1)
        #expect(simd_distance(point, head.position) < 1e-6)
        #expect(quaternion == [0, 0, 0, 1])
        #expect(simd_distance(wrist, SIMD3(-0.3, 1, -2)) < 1e-6)
    }
    @Test("Generation extension and invalid numeric input")
    func protocolValidation() {
        let good = bytes(hex: bodyStreamFixture)
        let extended = good + Array("PHX1".utf8) + [123, 0, 0, 0, 0, 0, 0, 0]
        #expect(RAVEBodyStreamProtocol.decodeFrame(extended)?.generation == 123)
        var invalid = good
        invalid.replaceSubrange(20..<24, with: [0, 0, 192, 127])
        #expect(RAVEBodyStreamProtocol.decodeFrame(invalid) == nil)
        invalid = good
        invalid.replaceSubrange(32..<36, with: [0, 0, 128, 127])
        #expect(RAVEBodyStreamProtocol.decodeFrame(invalid)?.joints[.nose] == nil)
    }

    @Test("Explicit camera generations retire old packets")
    func generations() throws {
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        var a = RAVEBodyStreamSourceTests().frame(0, sequence: 5000)
        a.generation = 123
        source.accept(a, at: 1)
        let revision = try #require(source.poll(now: 1)).alignmentRevision
        var b = RAVEBodyStreamSourceTests().frame(1, sequence: 1)
        b.generation = 456
        source.accept(b, at: 1.02)
        #expect(try #require(source.poll(now: 1.03)).alignmentRevision > revision)
        source.accept(a, at: 1.04)
        #expect(try #require(source.poll(now: 1.05)).frame.generation == 456)
    }

    @Test("Inference time counts toward expiry")
    func totalAge() throws {
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        source.accept(RAVEBodyStreamSourceTests().frame(0, sequence: 1, latency: 0.45), at: 1)
        #expect(try #require(source.poll(now: 1.01)).age > 0.45)
        #expect(source.poll(now: 1.06) == nil)
        source.accept(RAVEBodyStreamSourceTests().frame(1, sequence: 2, latency: 2), at: 1.1)
        #expect(source.status(now: 1.1).rejected == 1)
    }

    @Test("A well-spread but inconsistent skeleton never certifies alignment")
    func rejectsBadFit() {
        var alignment = RAVEBodyAlignment()
        for i in 0..<200 {
            let p = performerPoint(i, .leftWrist)
            let bad = p + SIMD3<Float>(0, i % 2 == 0 ? 0.4 : -0.4, 0)
            alignment.addSample(.leftWrist, stream: p, world: bad, time: Double(i) / 30)
        }
        alignment.maybeSolve(now: 7)
        #expect(!alignment.isAligned)
        #expect(alignment.residual > RAVEBodyAlignment.maxResidualMeters)
    }

    @Test("A camera-space jump invalidates the fit and recovers from fresh pairs")
    func movedCamera() throws {
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        let dt = 1.0 / 90, delay = 0.06 + source.configuration.networkDelay
        var firstRevision: UInt64?
        for tick in 0..<2700 {
            let now = Double(tick) * dt
            let step = Float(now * 90 / 8)
            source.observe(head: performerPoint(step, .head), leftWrist: performerPoint(step, .leftWrist),
                           rightWrist: performerPoint(step, .rightWrist), now: now)
            if now >= delay, tick % 2 == 0 {
                var frame = RAVEBodyStreamSourceTests().frame(Float((now - delay) * 90 / 8),
                                                              sequence: UInt32(tick))
                if now > 12 { frame = frame.transformed(yaw: 0, translation: SIMD3(0.7, 0, 0)) }
                source.accept(frame, at: now)
            }
            if now > 8, firstRevision == nil, let reading = source.poll(now: now), reading.isAligned {
                firstRevision = reading.alignmentRevision
            }
        }
        let reading = try #require(source.poll(now: 2699 * dt))
        #expect(firstRevision != nil)
        #expect(reading.isAligned)
        #expect(reading.alignmentRevision > (firstRevision ?? 0))
        let actual = try #require(reading.frame.joints[.leftWrist]).position
        let expected = performerPoint(Float((2698 * dt - delay) * 90 / 8), .leftWrist)
        #expect(simd_distance(actual, expected) < 0.03)
    }

    @Test("Clock mapping uses the best RTT and expires")
    func mapsClocks() throws {
        var clock = RAVEBodyClock()
        clock.record(sent: 10, received: 10.01, hubReceived: 1010.004, hubSent: 1010.006)
        #expect(abs(try #require(clock.localTime(1009.95, now: 10.02)) - 9.95) < 1e-8)
        #expect(abs(try #require(clock.uncertainty(now: 10.02)) - 0.004) < 1e-8)
        clock.record(sent: 11, received: 11.2, hubReceived: 1011.19, hubSent: 1011.19)
        #expect(abs(try #require(clock.localTime(1011, now: 11.3)) - 11) < 1e-8)
        #expect(clock.localTime(1025, now: 25) == nil)
        clock.record(sent: .nan, received: 30, hubReceived: 40, hubSent: 40)
        #expect(clock.uncertainty(now: 30) == nil)
    }
}
