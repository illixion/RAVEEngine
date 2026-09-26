import Foundation
import Testing
import simd
@testable import RAVEInput

/// Golden bytes, built by hand at the offsets `quest_bridge_protocol.h`
/// documents (and static_asserts), never through the codec — so a drift in
/// either definition fails here instead of in a headset session.
@Suite("Controller Bridge protocol")
struct RAVEQuestBridgeProtocolTests {

    private func put<T: FixedWidthInteger>(_ value: T, _ bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for (i, b) in raw.enumerated() { bytes[offset + i] = b }
        }
    }

    private func put(_ value: Float, _ bytes: inout [UInt8], at offset: Int) {
        put(value.bitPattern, &bytes, at: offset)
    }

    /// The same packet Longwave's host test builds for its legacy ingest, plus
    /// the v2 trailer.
    private func goldenControllerState(version: UInt8, sender: UInt8) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 100)
        pkt[0] = 0x01
        pkt[1] = 42                                              // sequence, NOT a version
        put(UInt16(0x000F), &pkt, at: 2)                         // both tracked + battery + touch
        for (i, v) in [-0.2, 1.1, -0.4].enumerated() { put(Float(v), &pkt, at: 4 + 4 * i) }
        for (i, v) in [0, 0.7071068, 0, 0.7071068].enumerated() { put(Float(v), &pkt, at: 16 + 4 * i) }
        for (i, v) in [0.25, 1.05, -0.35].enumerated() { put(Float(v), &pkt, at: 32 + 4 * i) }
        for (i, v) in [0, 0, 0, 1].enumerated() { put(Float(v), &pkt, at: 44 + 4 * i) }
        let analog: [Float] = [0.9, 0.8, 0.1, -0.2, 0.05, 0.6, 0.3, 0.4]
        for (i, v) in analog.enumerated() { put(v, &pkt, at: 60 + 4 * i) }
        put(UInt32((1 << 0) | (1 << 7) | (1 << 8) | (1 << 11)), &pkt, at: 92)   // A, R menu, L trig touch, R thumb touch
        pkt[96] = 87
        pkt[97] = 0xFF
        pkt[98] = version
        pkt[99] = sender
        return pkt
    }

    @Test("0x01 decodes at the header's offsets")
    func controllerStateGolden() throws {
        let state = try #require(RAVEQuestBridgeProtocol.ControllerState(goldenControllerState(version: 2, sender: 1)))
        #expect(state.sequence == 42)
        #expect(state.flags == [.leftTracked, .rightTracked, .battery, .touch])
        #expect(state.left.position == SIMD3(-0.2, 1.1, -0.4))
        #expect(abs(state.left.rotation.y - 0.7071068) < 1e-7)
        #expect(state.right.position == SIMD3(0.25, 1.05, -0.35))
        #expect(state.right.rotation == SIMD4(0, 0, 0, 1))
        #expect(state.left.trigger == 0.9 && state.left.grip == 0.8)
        #expect(state.left.stick == SIMD2(0.1, -0.2))
        #expect(state.right.trigger == 0.05 && state.right.grip == 0.6)     // analog grip survives
        #expect(state.right.stick == SIMD2(0.3, 0.4))
        #expect(state.buttons == [.a, .rightMenu, .leftTriggerTouch, .rightThumbTouch])
        #expect(state.battery(.left) == 87)
        #expect(state.battery(.right) == nil)                                // 0xFF = unknown
        #expect(state.protocolVersion == 2)
        #expect(state.senderKind == .questApp)
    }

    @Test("Encoding reproduces the golden bytes exactly")
    func controllerStateRoundTrip() throws {
        let golden = goldenControllerState(version: 2, sender: 1)
        let state = try #require(RAVEQuestBridgeProtocol.ControllerState(golden))
        #expect(state.encoded() == golden)
        #expect(state.encoded().count == RAVEQuestBridgeProtocol.ControllerState.size)
    }

    @Test("A v1 packet (reserved word zero) decodes as version 0, sender unknown")
    func v1ControllerState() throws {
        var golden = goldenControllerState(version: 0, sender: 0)
        put(UInt16(0x0007), &golden, at: 2)                      // v1 never set the touch flag
        let state = try #require(RAVEQuestBridgeProtocol.ControllerState(golden))
        #expect(state.protocolVersion == 0)
        #expect(state.senderKind == .unknown)
        #expect(!state.flags.contains(.touch))
        #expect(RAVEQuestBridgeProtocol.negotiatedVersion(peer: state.protocolVersion) == 1)
    }

    @Test("Short, unknown and mistyped datagrams are rejected; longer ones decode their prefix")
    func rejectsGarbage() {
        let golden = goldenControllerState(version: 2, sender: 1)
        #expect(RAVEQuestBridgeProtocol.ControllerState(Array(golden.prefix(99))) == nil)
        #expect(RAVEQuestBridgeProtocol.decode([UInt8]()) == nil)
        #expect(RAVEQuestBridgeProtocol.decode([0x7E, 1, 2, 3]) == nil)
        var mistyped = golden
        mistyped[0] = 0x02
        #expect(RAVEQuestBridgeProtocol.ControllerState(mistyped) == nil)
        #expect(RAVEQuestBridgeProtocol.decode(golden + [1, 2, 3, 4]) != nil)
    }

    @Test("Haptic 0x02 is 14 bytes: type, controller, duration, frequency, amplitude")
    func hapticGolden() throws {
        var golden = [UInt8](repeating: 0, count: 14)
        golden[0] = 0x02
        golden[1] = 1
        put(Float(0.12), &golden, at: 2)
        put(Float(60), &golden, at: 6)
        put(Float(0.6), &golden, at: 10)
        let haptic = RAVEQuestBridgeProtocol.Haptic(
            RAVEControllerHaptic(chirality: .right, duration: 0.12, frequency: 60, amplitude: 0.6))
        #expect(haptic.encoded() == golden)
        #expect(RAVEQuestBridgeProtocol.Haptic(golden) == haptic)
        // Amplitude is clamped on the way out; the Quest trusts it.
        #expect(RAVEQuestBridgeProtocol.Haptic(
            RAVEControllerHaptic(chirality: .left, duration: 0, amplitude: 3)).amplitude == 1)
    }

    @Test("Probe 0xF0 and status 0xF1 layouts")
    func probeAndStatusGolden() throws {
        var probe = [UInt8](repeating: 0, count: 8)
        probe[0] = 0xF0
        probe[1] = 1
        put(UInt32(0xDEADBEEF), &probe, at: 4)
        let decoded = try #require(RAVEQuestBridgeProtocol.Probe(probe))
        #expect(decoded.protocolVersion == 1 && decoded.nonce == 0xDEADBEEF)
        #expect(decoded.encoded() == probe)

        var status = [UInt8](repeating: 0, count: 16)
        status[0] = 0xF1
        status[1] = 1
        put(UInt16(1), &status, at: 2)                           // DRIVER_READY
        put(UInt32(0xDEADBEEF), &status, at: 4)
        put(UInt32(1234), &status, at: 8)
        let reply = RAVEQuestBridgeProtocol.Status(protocolVersion: 1, nonce: 0xDEADBEEF, packetsReceived: 1234)
        #expect(reply.encoded() == status)
        #expect(RAVEQuestBridgeProtocol.Status(status) == reply)
    }

    /// `qcb_status_ex_packet_t`: status at 0…15, then host_kind 16,
    /// host_flags 17, name_length 18, reserved 19, name 20…63 zero-padded.
    @Test("v3 probe reply: 16-byte status + 48-byte host info at the header's offsets")
    func hostInfoGolden() throws {
        var golden = [UInt8](repeating: 0, count: 64)
        golden[0] = 0xF1
        golden[1] = 3
        put(UInt16(1), &golden, at: 2)
        put(UInt32(0x01020304), &golden, at: 4)
        put(UInt32(99), &golden, at: 8)
        golden[16] = 1                                           // QCB_HOST_VISIONOS_APP
        golden[17] = 1                                           // QCB_HOST_ACCEPTING
        let name = Array("Ixion's Vision Pro".utf8)
        golden[18] = UInt8(name.count)
        for (i, b) in name.enumerated() { golden[20 + i] = b }

        let reply = RAVEQuestBridgeProtocol.Status(
            protocolVersion: 3, nonce: 0x01020304, packetsReceived: 99,
            hostInfo: .init(kind: .visionOSApp, accepting: true, name: "Ixion's Vision Pro"))
        #expect(reply.encoded() == golden)
        let decoded = try #require(RAVEQuestBridgeProtocol.Status(golden))
        #expect(decoded == reply)
        let info = try #require(decoded.hostInfo)
        #expect(info.hostKind == .visionOSApp && info.isAccepting && info.name == "Ixion's Vision Pro")
        #expect(RAVEQuestBridgeProtocol.decode(golden) == .status(reply))

        // Busy SteamVR driver: kind 2, flags 0.
        var busy = golden
        busy[16] = 2
        busy[17] = 0
        let busyInfo = try #require(RAVEQuestBridgeProtocol.Status(busy)?.hostInfo)
        #expect(busyInfo.hostKind == .steamVRDriver && !busyInfo.isAccepting)
        // Unknown kinds read as "other", not as a failure.
        busy[16] = 200
        #expect(RAVEQuestBridgeProtocol.Status(busy)?.hostInfo?.hostKind == .other)
    }

    @Test("Host info is read only at v3+ with all 64 bytes; heartbeats stay 16")
    func hostInfoCompatibility() throws {
        let full = RAVEQuestBridgeProtocol.Status(
            protocolVersion: 3, nonce: 1, packetsReceived: 0,
            hostInfo: .init(kind: .steamVRDriver, accepting: true, name: "PC")).encoded()
        #expect(full.count == 64)
        // An older host's 16-byte answer to a v3 probe: no host info, no failure.
        let short = try #require(RAVEQuestBridgeProtocol.Status(Array(full.prefix(16))))
        #expect(short.hostInfo == nil && short.nonce == 1)
        // A v2 status never carries it, even if a datagram happened to be long.
        var v2 = full
        v2[1] = 2
        #expect(try #require(RAVEQuestBridgeProtocol.Status(v2)).hostInfo == nil)
        // Truncated trailer: ignored rather than half-read.
        #expect(try #require(RAVEQuestBridgeProtocol.Status(Array(full.prefix(40)))).hostInfo == nil)
        // A heartbeat (no host info) is the plain 16 bytes at any version.
        #expect(RAVEQuestBridgeProtocol.Status(protocolVersion: 3, packetsReceived: 5).encoded().count == 16)
        // A name_length past the field is clamped, not trusted.
        var bogus = full
        bogus[18] = 250
        #expect(RAVEQuestBridgeProtocol.Status(bogus)?.hostInfo?.name.utf8.count == 44)
    }

    @Test("Host names are cut to 44 UTF-8 bytes at a character boundary")
    func hostNameTruncation() throws {
        let ascii = String(repeating: "a", count: 60)
        #expect(RAVEQuestBridgeProtocol.HostInfo(kind: .other, accepting: true, name: ascii).name.utf8.count == 44)
        // 43 ASCII bytes + a 2-byte "é" would be 45: the é is dropped whole.
        let accented = String(repeating: "b", count: 43) + "é"
        let cut = RAVEQuestBridgeProtocol.HostInfo(kind: .other, accepting: true, name: accented)
        #expect(cut.name == String(repeating: "b", count: 43))
        // A multi-scalar grapheme (flag, 8 bytes) never splits.
        let flag = String(repeating: "c", count: 40) + "🇱🇹"
        let flagCut = RAVEQuestBridgeProtocol.HostInfo(kind: .other, accepting: true, name: flag)
        #expect(flagCut.name == String(repeating: "c", count: 40))
        let bytes = RAVEQuestBridgeProtocol.Status(protocolVersion: 3, nonce: 0, packetsReceived: 0,
                                                   hostInfo: cut).encoded()
        #expect(bytes[18] == 43 && bytes[20 + 43] == 0)
    }

    @Test("Version negotiation: answer at min(peer, ours), never below 1")
    func negotiation() {
        #expect(RAVEQuestBridgeProtocol.negotiatedVersion(peer: 0) == 1)
        #expect(RAVEQuestBridgeProtocol.negotiatedVersion(peer: 1) == 1)
        #expect(RAVEQuestBridgeProtocol.negotiatedVersion(peer: 2) == 2)
        #expect(RAVEQuestBridgeProtocol.negotiatedVersion(peer: 3) == 3)
        #expect(RAVEQuestBridgeProtocol.negotiatedVersion(peer: 9) == RAVEQuestBridgeProtocol.version)
    }

    /// Bytes produced by `tools/test_sender.py`'s `build_packet(t=1.25, seq=7)`
    /// in the Controller Bridge repository — Python's `struct.pack` as a third,
    /// independent encoder of the same layout.
    @Test("Decodes a packet from the Python test sender")
    func pythonTestSender() throws {
        let hex = RAVEQuestBridgeProtocolTests.pythonGoldenHex
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        let state = try #require(RAVEQuestBridgeProtocol.ControllerState(bytes))
        #expect(state.sequence == 7)
        #expect(state.flags.isSuperset(of: [.leftTracked, .rightTracked, .battery, .touch]))
        #expect(state.battery(.left) == 87 && state.battery(.right) == 64)
        #expect(state.protocolVersion == 2)
        #expect(state.senderKind == .testTool)
        // build_packet: left_trigger = 0.5 + 0.5·sin(1.2·t)
        #expect(abs(state.left.trigger - Float(0.5 + 0.5 * sin(1.2 * 1.25))) < 1e-6)
        // left x = −0.25 + 0.08·cos(2π·0.5·t)
        #expect(abs(state.left.position.x - Float(-0.25 + 0.08 * cos(Double.pi * 1.25))) < 1e-6)
        #expect(state.encoded() == bytes)
    }

    static let pythonGoldenHex = "01070f008df69cbe95516a3f2790b6be5ccb8d3d0000000000000000bc627f3f8df69c3e387b623f194679be5ccb8d3d0000000000000000bc627f3feaad7f3f52b56b3fbf17cdbe7835993e7c1f7a3ff03f573ffbf6ffbeb8eb073c0d0f000057400202"
}
