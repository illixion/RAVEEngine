import Foundation
import Testing
import simd
@testable import RAVEInput

/// PoseHub's shared fixture (`Tools/PoseHub/tests/body_stream_fixture.hex` in
/// miscale), copied verbatim, with values from `body_stream_fixture.json`
/// beside it. Regenerate both with `python tests/test_bodystream.py
/// --write-fixture` there and paste the new hex here. It is a made-up person
/// standing 2 m in front of the gauge camera, turned 30° to their left, the
/// left heel raised.
let bodyStreamFixture = """
50484253010200002a00000000000000004a9340a69b443d0000e03f150700b2cdcc4c3dcdcccc3f35eaf4bf0294ec20873d85ebd13f490df9bf05ccf2b0653c85ebd13f3f36f5bf078a8105853d295ccf3f666602c008c2810585bd295ccf3f3333fbbf0ba8707e283e3d0ab73f7b1406c00ce0707e28be3d0ab73f0ad7f3bf0d8f2419433e3333933f3d0a07c00ec7241943be3333933f85ebf1bf0fad356f6e3e6666663fa2e804c010e6023c3bbe6666663ff218ebbf179eac5cb13d1f856b3f333303c018d6ac5cb1bd1f856b3f9a99f9bf19a3e60eec3d0000003f904d01c01adb439eaebd0000003f34bef6bf1b80ba5ac03d295c0f3ed2f204c01cb89bd5d4bd0ad7a33dec51f8bf1d9916ea823dcdcccc3d284608c01ed1202309be0ad7a33c98f8febf1f851ef73a3e0000000003cdf8bf20bd61f6e1bc00000000d5d5e4bf008a00000000295ccf3f000000c0bfedc23dd5de833e88ecd0bcd712763f019e000000001f856b3f000000c000000000ee83843e00000000ea46773f0280ba5ac03d295c0f3ed2f204c009e14f3e03768c3e2b2c73bd4d26703f03b89bd5d4bd0ad7a33dec51f8bf5a542c3da540733edcbd28bcb66c783f0480e60eec3d0000003f904d01c009e14f3e03768c3e2b2c73bd4d26703f05b8439eaebd0000003f34bef6bf5a542c3da540733edcbd28bcb66c783f069e000000003d0ab73f000000c000000000ee83843e00000000ea46773f
"""

func bytes(hex: String) -> [UInt8] {
    let digits = Array(hex.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool { simd_distance(a, b) < tolerance }

@Suite("Body stream")
struct RAVEBodyStreamTests {

    @Test("Decodes the hub's fixture")
    func decodesFixture() throws {
        let frame = try #require(RAVEBodyStreamProtocol.decodeFrame(bytes(hex: bodyStreamFixture)))
        #expect(frame.sequence == 42)
        #expect(frame.captureTime == 1234.5)
        #expect(abs(frame.latency - 0.048) < 1e-6)
        #expect(frame.height == 1.75)
        #expect(!frame.calibrationLoaded)
        #expect(frame.joints.count == 21)
        #expect(Set(frame.trackers.keys) == [.head, .hips, .leftFoot, .rightFoot, .leftKnee, .rightKnee, .chest])

        let wrist = try #require(frame.joints[.leftWrist])
        #expect(close(wrist.position, SIMD3(0.232846, 0.9, -2.076699)))
        #expect(abs(wrist.confidence - 0.678431) < 1e-5)
        #expect(close(try #require(frame.joints[.rightBigToe]).position, SIMD3(-0.027583, 0, -1.787776)))

        let hips = try #require(frame.trackers[.hips])
        #expect(close(hips.position, SIMD3(0, 0.92, -2)))
        #expect(close(hips.rotation.vector.xyz, SIMD3(0, 0.258819, 0)))
        #expect(abs(hips.confidence - 0.619608) < 1e-5)
        let foot = try #require(frame.trackers[.leftFoot])
        #expect(close(foot.position, SIMD3(0.093923, 0.14, -2.077321)))
        #expect(simd_length(foot.rotation.vector - SIMD4(0.203007, 0.274338, -0.059368, 0.938084)) < 1e-5)
    }

    @Test("The space is the page's: facing the camera is +Z, the left is +X")
    func spaceConvention() throws {
        let frame = try #require(RAVEBodyStreamProtocol.decodeFrame(bytes(hex: bodyStreamFixture)))
        let hips = try #require(frame.trackers[.hips])
        // Turned 30° to their left from facing +Z: forward leans toward +X.
        let forward = hips.rotation.act(SIMD3<Float>(0, 0, 1))
        #expect(close(forward, SIMD3(sin(.pi / 6), 0, cos(.pi / 6)), 1e-4))
        #expect(frame.joints[.leftHip]!.position.x > frame.joints[.rightHip]!.position.x)
        // The raised left heel tips that foot's toes down.
        #expect(try #require(frame.trackers[.leftFoot]).rotation.act(SIMD3<Float>(0, 0, 1)).y < -0.2)
    }

    @Test("Refuses truncated, foreign and other-version datagrams")
    func refusesBadDatagrams() {
        let good = bytes(hex: bodyStreamFixture)
        #expect(RAVEBodyStreamProtocol.decodeFrame(Array(good.dropLast())) == nil)
        #expect(RAVEBodyStreamProtocol.decodeFrame(Array(good.prefix(20))) == nil)
        var foreign = good
        foreign[0] = 0x58
        #expect(RAVEBodyStreamProtocol.decodeFrame(foreign) == nil)
        var version = good
        version[4] = 2
        #expect(RAVEBodyStreamProtocol.decodeFrame(version) == nil)
        // Trailing bytes are room for later fields.
        #expect(RAVEBodyStreamProtocol.decodeFrame(good + [1, 2, 3]) != nil)
    }

    @Test("Subscribe and unsubscribe are what the hub expects")
    func subscribeEncoding() {
        #expect(RAVEBodyStreamProtocol.subscribe(name: "AVP") == Array("PHBS".utf8) + [1, 1, 0, 0, 3] + Array("AVP".utf8))
        #expect(RAVEBodyStreamProtocol.unsubscribe() == Array("PHBS".utf8) + [1, 3])
    }

    @Test("Transforming a frame turns and moves joints, trackers and the floor")
    func transform() throws {
        let frame = try #require(RAVEBodyStreamProtocol.decodeFrame(bytes(hex: bodyStreamFixture)))
        let yaw: Float = 0.7, offset = SIMD3<Float>(1, 0.05, -2)
        let moved = frame.transformed(yaw: yaw, translation: offset)
        let turn = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        #expect(close(moved.joints[.nose]!.position, turn.act(frame.joints[.nose]!.position) + offset))
        let forward = moved.trackers[.hips]!.rotation.act(SIMD3<Float>(0, 0, 1))
        #expect(close(forward, turn.act(frame.trackers[.hips]!.rotation.act(SIMD3(0, 0, 1)))))
        #expect(moved.floor == 0.05)
    }
}

// MARK: - Alignment

/// A performer waving their arms and stepping about in the stream's space.
func performerPoint(_ i: Int, _ anchor: RAVEBodyAlignment.Anchor) -> SIMD3<Float> {
    performerPoint(Float(i), anchor)
}

/// The same, at a continuous step: 1 step is 0.09 rad round the arm circles.
func performerPoint(_ step: Float, _ anchor: RAVEBodyAlignment.Anchor) -> SIMD3<Float> {
    let a = step * 0.09
    let body = SIMD3<Float>(0.4 * sin(a * 0.3), 0, -2 + 0.3 * cos(a * 0.2))
    switch anchor {
    case .head: return body + SIMD3(0, 1.62, 0)
    case .leftWrist: return body + SIMD3(0.25 + 0.35 * cos(a), 1.1 + 0.3 * sin(1.3 * a), 0.3 * sin(a))
    case .rightWrist: return body + SIMD3(-0.25 - 0.35 * sin(a), 1.0 + 0.3 * cos(1.1 * a), 0.3 * cos(a))
    }
}

@Suite("Body alignment")
struct RAVEBodyAlignmentTests {
    let yaw: Float = 2.1
    let offset = SIMD3<Float>(0.6, -0.03, 1.4)

    func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(p) + offset
    }

    @Test("rotateYaw is simd_quatf's rotation about +Y")
    func conventions() {
        let v = SIMD3<Float>(0.3, -0.2, 0.9)
        for degrees in stride(from: Float(-170), through: 170, by: 34) {
            let yaw = degrees * .pi / 180
            #expect(close(RAVEBodyAlignment.rotateYaw(yaw, v), simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(v)))
        }
    }

    @Test("Recovers yaw and offset from clean pairs")
    func recoversTransform() throws {
        var alignment = RAVEBodyAlignment()
        for i in 0..<200 {
            for anchor in RAVEBodyAlignment.Anchor.allCases {
                let p = performerPoint(i, anchor)
                alignment.addSample(anchor, stream: p, world: world(p), time: Double(i) / 30)
            }
        }
        let solved = alignment.maybeSolve(now: 200.0 / 30)
        #expect(solved)
        let fit = try #require(alignment.transform)
        #expect(abs(fit.yaw - yaw) < 1e-3)
        #expect(close(fit.translation, offset, 1e-3))
        #expect(alignment.residual < 1e-3)
    }

    @Test("Waits for spread: a still performer does not align")
    func waitsForSpread() {
        var alignment = RAVEBodyAlignment()
        for i in 0..<400 {
            // Tiny circles: plenty of pairs, no spread.
            let p = SIMD3<Float>(0.03 * cos(Float(i)), 1.2, -2 + 0.03 * sin(Float(i)))
            alignment.addSample(.leftWrist, stream: p, world: world(p), time: Double(i) / 30)
        }
        let solved = alignment.maybeSolve(now: 400.0 / 30)
        #expect(!solved)
        #expect(!alignment.isAligned)
    }

    @Test("Shrugs off a tenth of wrong pairs")
    func robustToOutliers() throws {
        var alignment = RAVEBodyAlignment()
        var noise = SystemRandomNumberGenerator()
        for i in 0..<300 {
            for anchor in [RAVEBodyAlignment.Anchor.leftWrist, .rightWrist] {
                let p = performerPoint(i, anchor)
                var w = world(p) + SIMD3(Float.random(in: -0.01...0.01, using: &noise), 0,
                                         Float.random(in: -0.01...0.01, using: &noise))
                // Every tenth pair is a different wrist entirely (left/right swapped by the model).
                if i % 10 == 0 { w += SIMD3(0.5, 0.1, -0.3) }
                alignment.addSample(anchor, stream: p, world: w, time: Double(i) / 30)
            }
        }
        let solved = alignment.maybeSolve(now: 10)
        #expect(solved)
        let fit = try #require(alignment.transform)
        #expect(abs(fit.yaw - yaw) < 0.01)
        #expect(close(fit.translation, offset, 0.01))
    }

    @Test("Old pairs age out")
    func agesOut() {
        var alignment = RAVEBodyAlignment()
        for i in 0..<100 {
            let p = performerPoint(i, .leftWrist)
            alignment.addSample(.leftWrist, stream: p, world: world(p), time: 0)
        }
        alignment.maybeSolve(now: RAVEBodyAlignment.sampleMaxAge + 1)
        #expect(alignment.sampleCount == 0)
    }
}

// MARK: - Source

@Suite("Body stream source")
struct RAVEBodyStreamSourceTests {

    /// A frame of a performer at step i, in the stream's space.
    func frame(_ i: Int, sequence: UInt32, latency: Float = 0.06) -> RAVEBodyFrame {
        frame(Float(i), sequence: sequence, latency: latency)
    }

    func frame(_ i: Float, sequence: UInt32, latency: Float = 0.06) -> RAVEBodyFrame {
        var joints: [RAVEBodyJoint: RAVEBodyJointSample] = [:]
        joints[.leftWrist] = RAVEBodyJointSample(position: performerPoint(i, .leftWrist), confidence: 0.9)
        joints[.rightWrist] = RAVEBodyJointSample(position: performerPoint(i, .rightWrist), confidence: 0.9)
        let identity = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        // The stream's head is between the ears: the headset sits headOffset in front.
        let head = RAVEBodyTrackerPose(position: performerPoint(i, .head) - RAVEBodyAlignment.headOffset,
                                       rotation: identity, confidence: 1)
        return RAVEBodyFrame(sequence: sequence, captureTime: Double(i), latency: latency, height: 1.75,
                             calibrationLoaded: false, joints: joints, trackers: [.head: head])
    }

    @Test("Pairs each frame with where the headset had things when the cameras saw them")
    func alignsWithLatency() throws {
        let yaw: Float = -0.8, offset = SIMD3<Float>(0.2, 0.01, -0.5)
        let turn = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        let dt = 1.0 / 90, latency: Float = 0.06
        // Walking pace: wrists under 1 m/s. The headset sees the performer at
        // tick·dt; the cameras' view of a moment arrives latency later.
        func step(_ time: Double) -> Float { Float(time * 90 / 8) }
        let ticks = 1800
        let delay = Double(latency) + source.configuration.networkDelay
        for tick in 0..<ticks {
            let now = Double(tick) * dt
            source.observe(head: turn.act(performerPoint(step(now), .head)) + offset,
                           leftWrist: turn.act(performerPoint(step(now), .leftWrist)) + offset,
                           rightWrist: turn.act(performerPoint(step(now), .rightWrist)) + offset, now: now)
            if now >= delay, tick % 2 == 0 {
                source.accept(frame(step(now - delay), sequence: UInt32(tick), latency: latency), at: now)
            }
        }
        let now = Double(ticks - 1) * dt
        let status = source.status(now: now)
        #expect(status.aligned)
        let reading = try #require(source.poll(now: now))
        #expect(reading.isAligned)
        // The aligned wrist lands on the headset's wrist for the same moment.
        let arrived = Double(ticks - 2) * dt
        let wrist = try #require(reading.frame.joints[.leftWrist]).position
        #expect(simd_distance(wrist, turn.act(performerPoint(step(arrived - delay), .leftWrist)) + offset) < 0.01)
        #expect(status.alignmentResidualCm < 1)
        #expect(abs(reading.frame.floor - offset.y) < 0.02)
    }

    @Test("Drops an overtaken frame, accepts a restarted hub, counts gaps")
    func sequenceRules() throws {
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        source.accept(frame(0, sequence: 100), at: 1)
        source.accept(frame(1, sequence: 99), at: 1.01)
        #expect(try #require(source.poll(now: 1.02)).frame.sequence == 100)
        source.accept(frame(2, sequence: 104), at: 1.03)
        #expect(source.status(now: 1.04).dropped == 3)
        source.accept(frame(3, sequence: 1), at: 1.05)
        #expect(try #require(source.poll(now: 1.06)).frame.sequence == 104)
        source.accept(frame(4, sequence: 1), at: 2.1)
        #expect(try #require(source.poll(now: 2.11)).frame.sequence == 1)
    }

    @Test("Stale frames are not handed out")
    func staleness() {
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        source.accept(frame(0, sequence: 1), at: 1)
        #expect(source.poll(now: 1.2) != nil)
        #expect(source.poll(now: 1.6) == nil)
        #expect(source.status(now: 1.6).state == .lost)
    }

    /// The example on BODY_STREAM.md's status section, as the hub sends it.
    static let statusJSON = #"""
    {"state":"calibrating","prompt":"frame","text":"The camera 2 (Front Ultra Wide) can't see your feet: tilt it down or move it back","progress":0.4,"scale":null,"cameras":[{"label":"camera 1 (Back Camera)","device":"iPhone16,2","live":true,"fps":60.0,"framing":"ok","placed":false,"moved":false,"progress":0.55,"movement":0.7,"errorPx":null,"lens":"reported"},{"label":"camera 2 (Front Ultra Wide)","framing":"feet","progress":0.2,"later":"ignored"}],"generation":"9f0c2a7d11e04b5a"}
    """#

    @Test("Decodes the hub's setup status, ignoring keys it doesn't know")
    func setupStatus() throws {
        let datagram = RAVEBodyStreamProtocol.magic + [1, 7] + Array(Self.statusJSON.utf8)
        let status = try #require(RAVEBodyStreamProtocol.decodeStatus(datagram))
        #expect(status.knownState == .calibrating && status.prompt == "frame" && status.progress == 0.4)
        #expect(status.scale == nil && status.generation == "9f0c2a7d11e04b5a")
        #expect(status.cameras.count == 2)
        #expect(status.cameras[0].live && status.cameras[0].framesPerSecond == 60 && status.cameras[0].note == "55%")
        #expect(status.cameras[1].note == "feet cut off" && !status.cameras[1].live)
        #expect(RAVEBodyStreamProtocol.decodeFrame(datagram) == nil)
        #expect(RAVEBodyStreamProtocol.decodeStatus(RAVEBodyStreamProtocol.magic + [1, 7] + Array("[1]".utf8)) == nil)
        #expect(RAVEBodyStreamProtocol.decodeStatus(bytes(hex: bodyStreamFixture)) == nil)
    }

    @Test("A source hands out the hub's status while it keeps coming")
    func setupStatusLapses() throws {
        let source = RAVEBodyStreamSource(clock: { 0 })
        source.start()
        defer { source.stop() }
        let datagram = RAVEBodyStreamProtocol.magic + [1, 7] + Array(Self.statusJSON.utf8)
        source.accept(try #require(RAVEBodyStreamProtocol.decodeStatus(datagram)), at: 1)
        #expect(source.status(now: 2).setup?.prompt == "frame")
        #expect(source.status(now: 4.5).setup == nil)
    }
}

extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

/// Against a real hub: `python -m posehub play <recording>` (miscale's
/// Tools/PoseHub), then `RAVE_BODY_HUB=127.0.0.1:7711 swift test --filter
/// liveHub`, or `RAVE_BODY_HUB=discover` to find it over Bonjour. Skipped
/// otherwise.
@Suite("Body stream, live hub")
struct RAVEBodyStreamLiveTests {
    @Test("Subscribes and receives frames", .enabled(if: ProcessInfo.processInfo.environment["RAVE_BODY_HUB"] != nil))
    func liveHub() async throws {
        let setting = ProcessInfo.processInfo.environment["RAVE_BODY_HUB"] ?? ""
        var configuration = RAVEBodyStreamSource.Configuration(name: "RAVEInputTests")
        if setting != "discover" {
            let parts = setting.split(separator: ":")
            configuration.hub = .address(host: String(parts[0]), port: parts.count > 1 ? UInt16(parts[1])! : 7711)
        }
        let source = RAVEBodyStreamSource(configuration: configuration)
        source.start()
        defer { source.stop() }
        let clock = { ProcessInfo.processInfo.systemUptime }
        var status = source.status(now: clock())
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            status = source.status(now: clock())
            if status.state == .receiving, status.framesPerSecond > 30 { break }
        }
        print("live hub: \(status.state.rawValue), \(status.framesPerSecond)/s, hub latency \(status.hubLatencyMs) ms, \(status.joints) joints, \(status.trackers) trackers")
        #expect(status.state == .receiving)
        #expect(status.framesPerSecond > 30)
        let reading = try #require(source.poll(now: clock()))
        #expect(reading.frame.trackers[.hips] != nil)
    }

    /// Against a hub still setting up (`python -m posehub serve --osc off`
    /// with no cameras): `RAVE_BODY_HUB_SETUP=127.0.0.1:7711`. It sends no
    /// frames yet, only its status.
    @Test("Hears a hub that is still setting up", .enabled(if: ProcessInfo.processInfo.environment["RAVE_BODY_HUB_SETUP"] != nil))
    func liveHubSetup() async throws {
        let parts = (ProcessInfo.processInfo.environment["RAVE_BODY_HUB_SETUP"] ?? "").split(separator: ":")
        var configuration = RAVEBodyStreamSource.Configuration(name: "RAVEInputTests")
        configuration.hub = .address(host: String(parts[0]), port: parts.count > 1 ? UInt16(parts[1])! : 7711)
        let source = RAVEBodyStreamSource(configuration: configuration)
        source.start()
        defer { source.stop() }
        var setup: RAVEBodyHubStatus?
        for _ in 0..<50 where setup == nil {
            try await Task.sleep(for: .milliseconds(100))
            setup = source.status(now: ProcessInfo.processInfo.systemUptime).setup
        }
        let status = try #require(setup)
        print("live hub setup: [\(status.state)] \(status.text)")
        #expect(status.knownState == .waiting && status.prompt == "addCameras")
    }
}
