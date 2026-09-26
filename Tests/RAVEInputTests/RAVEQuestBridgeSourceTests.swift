import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Quest alignment loop")
struct RAVEQuestAlignmentTests {
    let yaw: Float = 30 * .pi / 180
    let t = SIMD3<Float>(0.5, -0.2, -0.7)
    let off = SIMD3<Float>(0.02, -0.04, 0.05)

    private func observation(_ i: Int, _ hand: RAVEHandChirality, shift: SIMD3<Float> = .zero,
                             referenceShift: SIMD3<Float> = .zero) -> RAVEQuestAlignment.HandObservation {
        let q = arcPoint(i % 40, hand: hand) + shift
        return .init(questTracked: true, questPosition: q, questRotation: identityRotation,
                     reference: groundTruthPlace(yaw: yaw, t: t, offset: off, quest: q) + referenceShift)
    }

    /// Drive until the first solve; returns (alignment, now at the solve, pulses seen).
    private func calibrated() -> (RAVEQuestAlignment, UInt64, Int) {
        var alignment = RAVEQuestAlignment()
        var now: UInt64 = 1000
        var pulses = 0
        for i in 0..<40 {
            let r = alignment.step(left: observation(i, .left), right: observation(i, .right), nowMs: now)
            if r.pulse { pulses += 1 }
            if r.solved { break }
            now += 14
        }
        return (alignment, now, pulses)
    }

    @Test("First solve pulses twice, 250 ms apart")
    func calibrationPulse() {
        var (alignment, solvedAt, pulses) = calibrated()
        #expect(alignment.isCalibrated)
        #expect(pulses == 1)
        #expect(alignment.calibration.residualMm < 2)
        let early = alignment.tickPulses(nowMs: solvedAt + RAVEQuestAlignment.secondPulseDelayMs - 1)
        #expect(!early)
        let due = alignment.tickPulses(nowMs: solvedAt + RAVEQuestAlignment.secondPulseDelayMs)
        #expect(due)
        let again = alignment.tickPulses(nowMs: solvedAt + 5000)
        #expect(!again)                                           // once only
    }

    @Test("Moved desk: every pair disagrees for > 1 s → reset, then recalibrates")
    func watchdog() {
        var (alignment, now, _) = calibrated()
        let moved = SIMD3<Float>(0.6, 0, 0)                       // the desk headset slid 60 cm
        var resetAt: UInt64?
        for i in 0..<120 {
            let r = alignment.step(left: observation(i, .left, referenceShift: moved),
                                   right: observation(i, .right, referenceShift: moved), nowMs: now)
            if r.watchdogReset { resetAt = now; break }
            #expect(alignment.isCalibrated)
            now += 14
        }
        #expect(resetAt != nil)
        #expect(!alignment.isCalibrated)
        // Fresh pairs against the new truth converge again.
        var solved = false
        for i in 0..<60 {
            now += 14
            if alignment.step(left: observation(i, .left, referenceShift: moved),
                              right: observation(i, .right, referenceShift: moved), nowMs: now).solved {
                solved = true
            }
        }
        #expect(solved)
        let probe = SIMD3<Float>(0.1, 1.2, -0.5)
        let want = groundTruthPlace(yaw: yaw, t: t, offset: off, quest: probe) + moved
        #expect(simd_distance(alignment.apply(.left, position: probe, rotation: identityRotation).position, want) < 0.01)
    }

    @Test("A put-down controller is not evidence and does not trip the watchdog")
    func putDownKeepsCalibration() {
        var (alignment, now, _) = calibrated()
        // Left controller parked; the left hand walks away at ~0.5 m/s. Right keeps agreeing.
        let parked = arcPoint(39, hand: .left)
        var sawNotHeld = false
        for i in 0..<200 {
            let reference = groundTruthPlace(yaw: yaw, t: t, offset: off, quest: parked)
                + SIMD3(0.008 * Float(min(i, 120)), 0, 0) + SIMD3(0, 0, i > 120 ? 0.05 * Float(i % 2) : 0)
            let left = RAVEQuestAlignment.HandObservation(questTracked: true, questPosition: parked,
                                                          questRotation: identityRotation, reference: reference)
            let r = alignment.step(left: left, right: observation(i, .right), nowMs: now)
            #expect(!r.watchdogReset)
            if r.left == .notHeld { sawNotHeld = true }
            now += 16
        }
        #expect(sawNotHeld)
        #expect(alignment.verdict(.left) == .notHeld)
        #expect(alignment.isCalibrated)
    }

    @Test("A warm start is confirmed by one agreeing frame, or discarded by the watchdog")
    func warmStart() throws {
        let (source, _, _) = calibrated()
        let transform = try #require(source.calibration.transform)

        var good = RAVEQuestAlignment()
        good.restore(transform)
        #expect(good.isWarmStart && good.isCalibrated)
        _ = good.step(left: observation(0, .left), right: observation(0, .right), nowMs: 5000)
        #expect(!good.isWarmStart)

        var stale = RAVEQuestAlignment()
        stale.restore(transform)
        var now: UInt64 = 5000
        var reset = false
        for i in 0..<100 where !reset {
            reset = stale.step(left: observation(i, .left, referenceShift: SIMD3(0, 0, 1)),
                               right: observation(i, .right, referenceShift: SIMD3(0, 0, 1)), nowMs: now).watchdogReset
            now += 14
        }
        #expect(reset && !stale.isWarmStart && !stale.isCalibrated)
    }
}

/// The source's protocol behaviour and poll mapping, without a socket:
/// `process(datagram:)` is the whole state machine behind the listener.
@Suite("Quest bridge source")
struct RAVEQuestBridgeSourceTests {

    final class FakeClock: @unchecked Sendable {
        var now: Double = 100
    }

    private func makeSource(_ clock: FakeClock, suite: String? = nil,
                            configure: (inout RAVEQuestBridgeSource.Configuration) -> Void = { _ in })
        -> RAVEQuestBridgeSource {
        var config = RAVEQuestBridgeSource.Configuration()
        config.persistenceKey = suite == nil ? nil : "test.calibration"
        config.defaultsSuiteName = suite
        configure(&config)
        return RAVEQuestBridgeSource(configuration: config, clock: { clock.now })
    }

    private func packet(version: UInt8 = 2, sequence: UInt8 = 0, left: SIMD3<Float>, right: SIMD3<Float>,
                        buttons: RAVEQuestBridgeProtocol.Buttons = []) -> [UInt8] {
        RAVEQuestBridgeProtocol.ControllerState(
            sequence: sequence, flags: [.leftTracked, .rightTracked, .battery, .touch],
            left: .init(position: left, trigger: 0.7, grip: 0.4, stick: SIMD2(0.1, 0.9)),
            right: .init(position: right, grip: 0.9),
            buttons: buttons, batteryLeft: 80, batteryRight: 0xFF,
            protocolVersion: version, sender: 1).encoded()
    }

    @Test("Probe replies at the negotiated version with the nonce echoed")
    func probeReply() throws {
        let source = makeSource(FakeClock())
        let v1 = source.process(datagram: RAVEQuestBridgeProtocol.Probe(protocolVersion: 1, nonce: 77).encoded(),
                                senderHost: "q", now: 1)
        let reply1Bytes = try #require(v1.reply)
        let reply1 = try #require(RAVEQuestBridgeProtocol.Status(reply1Bytes))
        #expect(reply1.protocolVersion == 1)                      // a v1 app rejects anything else
        #expect(reply1.nonce == 77 && reply1.flags == 1 && reply1.packetsReceived == 0)
        #expect(v1.heartbeat == nil)

        let v2 = source.process(datagram: RAVEQuestBridgeProtocol.Probe(protocolVersion: 2, nonce: 5).encoded(),
                                senderHost: "q", now: 1)
        let reply2 = try #require(v2.reply)
        #expect(RAVEQuestBridgeProtocol.Status(reply2)?.protocolVersion == 2)
        #expect(reply2.count == 16)                               // a v2 app gets no trailer
        #expect(reply1Bytes.count == 16)
    }

    @Test("v3 probes get kind, name and accepting; busy while another sender streams")
    func discoveryReply() throws {
        let clock = FakeClock()
        let source = makeSource(clock) { $0.serviceName = "Desk AVP" }
        func probe(from host: String, at now: Double) throws -> RAVEQuestBridgeProtocol.HostInfo {
            let out = source.process(datagram: RAVEQuestBridgeProtocol.Probe(protocolVersion: 3, nonce: 9).encoded(),
                                     senderHost: host, now: now)
            #expect(out.heartbeat == nil)
            let bytes = try #require(out.reply)
            #expect(bytes.count == 64)
            let status = try #require(RAVEQuestBridgeProtocol.Status(bytes))
            #expect(status.protocolVersion == 3 && status.nonce == 9)
            return try #require(status.hostInfo)
        }
        let idle = try probe(from: "10.0.0.2", at: 1)
        #expect(idle.hostKind == .visionOSApp && idle.name == "Desk AVP" && idle.isAccepting)

        // 10.0.0.2 starts streaming: still accepting for it, busy for anyone else.
        _ = source.process(datagram: packet(version: 3, left: .zero, right: .zero), senderHost: "10.0.0.2", now: 2)
        #expect(try probe(from: "10.0.0.2", at: 2.1).isAccepting)
        #expect(try !probe(from: "10.0.0.3", at: 2.1).isAccepting)
        // A probe is never a sender: the stream still belongs to 10.0.0.2.
        #expect(try !probe(from: "10.0.0.3", at: 2.2).isAccepting)
        // The stream goes quiet past lostAfter: accepting again for everyone.
        #expect(try probe(from: "10.0.0.3", at: 2 + source.configuration.lostAfter + 0.01).isAccepting)
    }

    @Test("Advertising is on by default; the probe name falls back to the app name")
    func discoveryDefaults() throws {
        let source = makeSource(FakeClock())
        #expect(source.configuration.advertise)
        let out = source.process(datagram: RAVEQuestBridgeProtocol.Probe(protocolVersion: 3, nonce: 1).encoded(),
                                 senderHost: "q", now: 1)
        let reply = try #require(out.reply)
        let info = try #require(RAVEQuestBridgeProtocol.Status(reply)?.hostInfo)
        #expect(info.name == RAVEQuestBridgeSource.appDisplayName && !info.name.isEmpty)
    }

    @Test("Heartbeat on the first packet, then every interval, at the sender's version")
    func heartbeat() throws {
        let source = makeSource(FakeClock())
        let p = packet(version: 0, left: .zero, right: .zero)     // a v1 sender
        let first = source.process(datagram: p, senderHost: "q", now: 10)
        let beatBytes = try #require(first.heartbeat)
        let beat = try #require(RAVEQuestBridgeProtocol.Status(beatBytes))
        #expect(beat.protocolVersion == 1 && beat.nonce == 0 && beat.packetsReceived == 1)
        #expect(source.process(datagram: p, senderHost: "q", now: 11).heartbeat == nil)
        let later = source.process(datagram: p, senderHost: "q", now: 12.01)
        let laterBytes = try #require(later.heartbeat)
        #expect(RAVEQuestBridgeProtocol.Status(laterBytes)?.packetsReceived == 3)
        // Haptic/status packets from the LAN are not ours to act on.
        #expect(source.process(datagram: RAVEQuestBridgeProtocol.Haptic(controller: 0, duration: 1, frequency: 1,
                                                                         amplitude: 1).encoded(),
                               senderHost: "q", now: 13) == .init())
    }

    @Test("Poll maps buttons per hand, keeps analog grip, and publishes no pose before calibration")
    func pollMapping() throws {
        let clock = FakeClock()
        let source = makeSource(clock)
        #expect(source.poll(now: clock.now) == RAVETrackedControllerFrame())
        _ = source.process(datagram: packet(left: SIMD3(0, 1, 0), right: SIMD3(0.3, 1, 0),
                                            buttons: [.x, .leftThumbTouch, .a, .rightMenu, .rightTriggerTouch]),
                           senderHost: "q", now: clock.now)
        let frame = source.poll(now: clock.now)
        let left = try #require(frame.left)
        let right = try #require(frame.right)
        #expect(left.buttons == [.primary, .thumbTouch])
        #expect(right.buttons == [.primary, .menu, .triggerTouch])
        #expect(left.touchValid && right.touchValid)
        #expect(left.trigger == 0.7 && left.grip == 0.4 && left.stick == SIMD2(0.1, 0.9))
        #expect(right.grip == 0.9)
        #expect(left.batteryPercent == 80 && right.batteryPercent == nil)
        #expect(!left.isTracked && !right.isTracked)             // not aligned yet
        #expect(frame.trackedPose(.left) == nil)
        #expect(source.poll(now: clock.now + 2) == RAVETrackedControllerFrame())   // lost
    }

    @Test("End to end: packets + hands calibrate, publish ARKit-space poses, persist, restore untrusted")
    func endToEnd() throws {
        let suite = "RAVEQuestBridgeSourceTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let clock = FakeClock()
        let source = makeSource(clock, suite: suite)
        let yaw: Float = -20 * .pi / 180
        let t = SIMD3<Float>(0.3, 0.1, -1.0)
        let off = SIMD3<Float>(0.0, -0.03, 0.04)

        #expect(source.status.phase == .idle)
        for i in 0..<60 {
            let ql = arcPoint(i % 40, hand: .left), qr = arcPoint(i % 40, hand: .right)
            _ = source.process(datagram: packet(sequence: UInt8(i), left: ql, right: qr), senderHost: "q",
                               now: clock.now)
            source.observeReferences(left: groundTruthPlace(yaw: yaw, t: t, offset: off, quest: ql),
                                     right: groundTruthPlace(yaw: yaw, t: t, offset: off, quest: qr),
                                     now: clock.now)
            clock.now += 0.014
        }
        let frame = source.poll(now: clock.now)
        let left = try #require(frame.trackedPose(.left))
        let want = groundTruthPlace(yaw: yaw, t: t, offset: off, quest: arcPoint(19, hand: .left))
        #expect(simd_distance(left.position, want) < 0.005)
        #expect(left.isInHand)

        // `status` needs a listener to report a phase; the persisted transform
        // is what survives, so check that instead.
        let restored = makeSource(clock, suite: suite)
        _ = restored.process(datagram: packet(left: arcPoint(3, hand: .left), right: arcPoint(3, hand: .right)),
                             senderHost: "q", now: clock.now)
        // Restored but unconfirmed: no pose until a fresh pair agrees.
        #expect(restored.poll(now: clock.now).trackedPose(.left) == nil)
        restored.observeReferences(left: groundTruthPlace(yaw: yaw, t: t, offset: off, quest: arcPoint(3, hand: .left)),
                                   right: groundTruthPlace(yaw: yaw, t: t, offset: off, quest: arcPoint(3, hand: .right)),
                                   now: clock.now)
        #expect(restored.poll(now: clock.now).trackedPose(.left) != nil)

        restored.resetCalibration()
        #expect(UserDefaults(suiteName: suite)?.data(forKey: "test.calibration") == nil)
        #expect(restored.poll(now: clock.now).trackedPose(.left) == nil)
    }

    @Test("Hand samples anchor at the palm centre by default")
    func anchor() {
        let sample = RAVEHandSample(
            wrist: SIMD3(0, 0, 0), thumbTip: .zero, thumbKnuckle: .zero,
            index: .init(tip: .zero, metacarpal: .zero, knuckle: .zero),
            middle: .init(tip: .zero, metacarpal: .zero, knuckle: SIMD3(0, 0.1, 0)),
            ring: .init(tip: .zero, metacarpal: .zero, knuckle: .zero),
            little: .init(tip: .zero, metacarpal: .zero, knuckle: .zero))
        #expect(RAVEQuestCalibrationAnchor.palmCenter.point(in: sample) == SIMD3(0, 0.05, 0))
        #expect(RAVEQuestCalibrationAnchor.wrist.point(in: sample) == .zero)
    }

    /// Live loopback against the real listener. Opt-in (it binds a port):
    /// `RAVE_QUEST_LIVE=1 swift test --filter liveLoopback`, then run
    /// `tools/test_sender.py --port 19520 --count 200` from the Controller
    /// Bridge repository within 10 s. Without the env var it sends its own
    /// packets over loopback.
    @Test("Live loopback over UDP", .enabled(if: ProcessInfo.processInfo.environment["RAVE_QUEST_LOOPBACK"] == "1"
                                             || ProcessInfo.processInfo.environment["RAVE_QUEST_LIVE"] == "1"))
    func liveLoopback() async throws {
        var config = RAVEQuestBridgeSource.Configuration()
        config.port = 19520
        config.persistenceKey = nil
        let source = RAVEQuestBridgeSource(configuration: config)
        try source.start()
        defer { source.stop() }
        let external = ProcessInfo.processInfo.environment["RAVE_QUEST_LIVE"] == "1"
        if !external {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(19520).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            try await Task.sleep(for: .milliseconds(300))
            for i in 0..<20 {
                let bytes = packet(sequence: UInt8(i), left: SIMD3(0, 1, 0), right: SIMD3(0.3, 1, 0))
                _ = bytes.withUnsafeBytes { raw in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(14))
            }
        }
        let deadline = Date().addingTimeInterval(external ? 10 : 2)
        while source.status.packetsReceived < 20 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let status = source.status
        #expect(status.packetsReceived >= 20)
        #expect(status.phase == .seen)
        #expect(status.senderVersion >= 2)
        #expect(status.sender == (external ? .testTool : .questApp))
        #expect(status.batteryLeft != nil)
    }

    /// Live discovery reply over a real socket. Opt-in like `liveLoopback`
    /// (it binds a port): `RAVE_QUEST_LOOPBACK=1 swift test --filter
    /// liveDiscovery` probes over loopback itself. With `RAVE_QUEST_LIVE=1` it
    /// also stays up 10 s for `tools/test_sender.py --discover --port 19522`
    /// from the Controller Bridge repository — which on macOS also exercises
    /// the broadcast path (macOS needs no multicast entitlement).
    @Test("Live discovery reply over UDP", .enabled(if: ProcessInfo.processInfo.environment["RAVE_QUEST_LOOPBACK"] == "1"
                                                    || ProcessInfo.processInfo.environment["RAVE_QUEST_LIVE"] == "1"))
    func liveDiscovery() async throws {
        var config = RAVEQuestBridgeSource.Configuration()
        config.port = 19522
        config.persistenceKey = nil
        config.serviceName = "RAVE loopback host"
        let source = RAVEQuestBridgeSource(configuration: config)
        try source.start()
        defer { source.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(19522).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let probe = RAVEQuestBridgeProtocol.Probe(protocolVersion: 3, nonce: 0xC0FFEE).encoded()
        _ = probe.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        #expect(n == 64)
        let status = try #require(RAVEQuestBridgeProtocol.Status(Array(buffer.prefix(max(n, 0)))))
        #expect(status.nonce == 0xC0FFEE && status.protocolVersion == 3)
        let info = try #require(status.hostInfo)
        #expect(info.name == "RAVE loopback host" && info.isAccepting && info.hostKind == .visionOSApp)
        #expect(source.status.packetsReceived == 0)               // a probe is not a sender

        if ProcessInfo.processInfo.environment["RAVE_QUEST_LIVE"] == "1" {
            try await Task.sleep(for: .seconds(10))
        }
    }
}
