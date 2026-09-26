/*
 RAVE Engine — the Controller Bridge wire format, in Swift.

 The canonical definition is `protocol/quest_bridge_protocol.h` in the
 Controller Bridge repository (illixion/controller-bridge); this is a codec
 for it, not a second definition. Every offset below is the header's, and the
 golden-byte tests in RAVEQuestBridgeProtocolTests build packets by hand at
 those offsets so a drift on either side fails a test rather than a session.

 Framework-free on purpose — bytes in, values out — so the whole protocol is
 exercised by `swift test` on the host. The socket lives in
 `RAVEQuestBridgeSource`.

 Versions: v1 packets end in a zeroed reserved word, v2 splits it into
 `protocolVersion` and `sender`. A v1 packet therefore decodes with
 `protocolVersion == 0`, and `negotiatedVersion(peer:)` is what a host must
 answer with — a v1 Quest app rejects any status whose version is not exactly 1.
 v3 adds discovery: a probe reply negotiated at v3+ appends a 48-byte
 `HostInfo` (kind, accepting, name) after the 16-byte status, so an older
 sender — which never announces v3 — never sees it, and an older host answers
 a v3 probe with the plain 16 bytes.
 */

/// Constants and codecs for the Controller Bridge UDP protocol.
public enum RAVEQuestBridgeProtocol {
    public static let version: UInt8 = 3
    /// First version whose probe replies carry `HostInfo`.
    public static let hostInfoVersion: UInt8 = 3
    public static let minimumVersion: UInt8 = 1

    /// Controller state (and probes) arrive here.
    public static let defaultPort: UInt16 = 9520
    /// Haptics and heartbeats go to the sender's address on port + 1.
    public static let hapticPortOffset: UInt16 = 1
    /// DNS-SD service type a host may advertise.
    public static let bonjourServiceType = "_controllerbridge._udp"

    public enum PacketType: UInt8, Sendable {
        case controllerState = 0x01
        case haptic = 0x02
        case probe = 0xF0
        case status = 0xF1
    }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let leftTracked  = Flags(rawValue: 1 << 0)
        public static let rightTracked = Flags(rawValue: 1 << 1)
        /// battery_left/right carry readings.
        public static let battery      = Flags(rawValue: 1 << 2)
        /// The touch button bits carry readings (v2).
        public static let touch        = Flags(rawValue: 1 << 3)
    }

    public struct Buttons: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let a             = Buttons(rawValue: 1 << 0)
        public static let b             = Buttons(rawValue: 1 << 1)
        public static let x             = Buttons(rawValue: 1 << 2)
        public static let y             = Buttons(rawValue: 1 << 3)
        public static let leftStick     = Buttons(rawValue: 1 << 4)
        public static let rightStick    = Buttons(rawValue: 1 << 5)
        public static let leftMenu      = Buttons(rawValue: 1 << 6)
        public static let rightMenu     = Buttons(rawValue: 1 << 7)
        public static let leftTriggerTouch  = Buttons(rawValue: 1 << 8)
        public static let rightTriggerTouch = Buttons(rawValue: 1 << 9)
        public static let leftThumbTouch    = Buttons(rawValue: 1 << 10)
        public static let rightThumbTouch   = Buttons(rawValue: 1 << 11)
        public static let leftGrip      = Buttons(rawValue: 1 << 12)
        public static let rightGrip     = Buttons(rawValue: 1 << 13)
    }

    /// `qcb_controller_state_t.sender`.
    public enum Sender: UInt8, Sendable {
        case unknown = 0
        case questApp = 1
        case testTool = 2
    }

    /// `qcb_host_info_t.host_kind` (v3).
    public enum HostKind: UInt8, Sendable {
        case other = 0
        case visionOSApp = 1
        case steamVRDriver = 2
        case testTool = 3
    }

    public static let statusDriverReady: UInt16 = 1 << 0
    /// `QCB_HOST_ACCEPTING`: not streaming from a different sender right now.
    public static let hostAccepting: UInt8 = 1 << 0
    /// `QCB_HOST_NAME_MAX`, UTF-8 bytes.
    public static let hostNameMaxBytes = 44
    public static let batteryUnknown: UInt8 = 0xFF

    /// The version to speak to a peer that announced `peer` (0 = a v1
    /// controller packet, which carried none).
    public static func negotiatedVersion(peer: UInt8) -> UInt8 {
        max(minimumVersion, min(peer, version))
    }

    // MARK: Packets

    /// One controller's slice of a 0x01 packet, in the Quest's own space.
    public struct Hand: Sendable, Equatable {
        public var position: SIMD3<Float>
        /// x, y, z, w.
        public var rotation: SIMD4<Float>
        public var trigger: Float
        public var grip: Float
        public var stick: SIMD2<Float>

        public init(position: SIMD3<Float> = .zero, rotation: SIMD4<Float> = SIMD4(0, 0, 0, 1),
                    trigger: Float = 0, grip: Float = 0, stick: SIMD2<Float> = .zero) {
            self.position = position
            self.rotation = rotation
            self.trigger = trigger
            self.grip = grip
            self.stick = stick
        }
    }

    /// `qcb_controller_state_t`, 100 bytes.
    public struct ControllerState: Sendable, Equatable {
        public static let size = 100

        public var sequence: UInt8
        public var flags: Flags
        public var left: Hand
        public var right: Hand
        public var buttons: Buttons
        public var batteryLeft: UInt8
        public var batteryRight: UInt8
        /// 0 from a v1 sender.
        public var protocolVersion: UInt8
        /// Raw `sender` byte; see `senderKind`.
        public var sender: UInt8

        public init(sequence: UInt8 = 0, flags: Flags = [], left: Hand = Hand(), right: Hand = Hand(),
                    buttons: Buttons = [], batteryLeft: UInt8 = RAVEQuestBridgeProtocol.batteryUnknown,
                    batteryRight: UInt8 = RAVEQuestBridgeProtocol.batteryUnknown,
                    protocolVersion: UInt8 = RAVEQuestBridgeProtocol.version,
                    sender: UInt8 = Sender.unknown.rawValue) {
            self.sequence = sequence
            self.flags = flags
            self.left = left
            self.right = right
            self.buttons = buttons
            self.batteryLeft = batteryLeft
            self.batteryRight = batteryRight
            self.protocolVersion = protocolVersion
            self.sender = sender
        }

        public var senderKind: Sender { Sender(rawValue: sender) ?? .unknown }

        public subscript(chirality: RAVEHandChirality) -> Hand {
            get { chirality == .left ? left : right }
            set { if chirality == .left { left = newValue } else { right = newValue } }
        }

        public func isTracked(_ chirality: RAVEHandChirality) -> Bool {
            flags.contains(chirality == .left ? .leftTracked : .rightTracked)
        }

        /// 0…100, or nil when the flag is clear or the side reads unknown (or
        /// anything over 100, which no sender means).
        public func battery(_ chirality: RAVEHandChirality) -> UInt8? {
            guard flags.contains(.battery) else { return nil }
            let raw = chirality == .left ? batteryLeft : batteryRight
            return raw <= 100 ? raw : nil
        }

        public init?(bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= Self.size,
                  bytes[0] == PacketType.controllerState.rawValue else { return nil }
            var r = ByteReader(bytes, offset: 1)
            sequence = r.u8()
            flags = Flags(rawValue: r.u16())
            let lp = r.vec3(), lr = r.vec4()
            let rp = r.vec3(), rr = r.vec4()
            let la = r.vec4(), ra = r.vec4()        // trigger, grip, stick x, stick y
            left = Hand(position: lp, rotation: lr, trigger: la.x, grip: la.y, stick: SIMD2(la.z, la.w))
            right = Hand(position: rp, rotation: rr, trigger: ra.x, grip: ra.y, stick: SIMD2(ra.z, ra.w))
            buttons = Buttons(rawValue: r.u32())
            batteryLeft = r.u8()
            batteryRight = r.u8()
            protocolVersion = r.u8()
            sender = r.u8()
        }

        public init?(_ bytes: [UInt8]) {
            guard let value = bytes.withUnsafeBytes({ ControllerState(bytes: $0) }) else { return nil }
            self = value
        }

        public func encoded() -> [UInt8] {
            var w = ByteWriter(capacity: Self.size)
            w.u8(PacketType.controllerState.rawValue)
            w.u8(sequence)
            w.u16(flags.rawValue)
            w.vec3(left.position); w.vec4(left.rotation)
            w.vec3(right.position); w.vec4(right.rotation)
            for hand in [left, right] {
                w.f32(hand.trigger); w.f32(hand.grip); w.f32(hand.stick.x); w.f32(hand.stick.y)
            }
            w.u32(buttons.rawValue)
            w.u8(batteryLeft)
            w.u8(batteryRight)
            w.u8(protocolVersion)
            w.u8(sender)
            return w.bytes
        }
    }

    /// `qcb_haptic_packet_t`, 14 bytes, host → Quest.
    public struct Haptic: Sendable, Equatable {
        public static let size = 14
        /// 0 = left, 1 = right.
        public var controller: UInt8
        public var duration: Float
        public var frequency: Float
        public var amplitude: Float

        public init(controller: UInt8, duration: Float, frequency: Float, amplitude: Float) {
            self.controller = controller
            self.duration = duration
            self.frequency = frequency
            self.amplitude = amplitude
        }

        public init(_ haptic: RAVEControllerHaptic) {
            self.init(controller: haptic.chirality == .left ? 0 : 1, duration: haptic.duration,
                      frequency: haptic.frequency, amplitude: min(max(haptic.amplitude, 0), 1))
        }

        public init?(bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= Self.size, bytes[0] == PacketType.haptic.rawValue else { return nil }
            var r = ByteReader(bytes, offset: 1)
            controller = r.u8()
            duration = r.f32()
            frequency = r.f32()
            amplitude = r.f32()
        }

        public init?(_ bytes: [UInt8]) {
            guard let value = bytes.withUnsafeBytes({ Haptic(bytes: $0) }) else { return nil }
            self = value
        }

        public func encoded() -> [UInt8] {
            var w = ByteWriter(capacity: Self.size)
            w.u8(PacketType.haptic.rawValue)
            w.u8(controller)
            w.f32(duration)
            w.f32(frequency)
            w.f32(amplitude)
            return w.bytes
        }
    }

    /// `qcb_discovery_packet_t`, 8 bytes, Quest → host.
    public struct Probe: Sendable, Equatable {
        public static let size = 8
        public var protocolVersion: UInt8
        public var nonce: UInt32

        public init(protocolVersion: UInt8 = RAVEQuestBridgeProtocol.version, nonce: UInt32) {
            self.protocolVersion = protocolVersion
            self.nonce = nonce
        }

        public init?(bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= Self.size, bytes[0] == PacketType.probe.rawValue else { return nil }
            var r = ByteReader(bytes, offset: 1)
            protocolVersion = r.u8()
            _ = r.u16()                              // reserved
            nonce = r.u32()
        }

        public init?(_ bytes: [UInt8]) {
            guard let value = bytes.withUnsafeBytes({ Probe(bytes: $0) }) else { return nil }
            self = value
        }

        public func encoded() -> [UInt8] {
            var w = ByteWriter(capacity: Self.size)
            w.u8(PacketType.probe.rawValue)
            w.u8(protocolVersion)
            w.u16(0)
            w.u32(nonce)
            return w.bytes
        }
    }

    /// `qcb_host_info_t`, 48 bytes (v3): who answered a probe. Appended to a
    /// probe reply negotiated at v3 or later, never to a heartbeat.
    public struct HostInfo: Sendable, Equatable {
        public static let size = 48
        /// Raw `host_kind`; see `hostKind`.
        public var kind: UInt8
        /// Raw `host_flags`; see `isAccepting`.
        public var flags: UInt8
        /// At most `hostNameMaxBytes` of UTF-8; `init` cuts longer names at a
        /// character boundary.
        public private(set) var name: String

        public init(kind: HostKind, accepting: Bool, name: String) {
            self.init(rawKind: kind.rawValue, flags: accepting ? RAVEQuestBridgeProtocol.hostAccepting : 0,
                      name: name)
        }

        public init(rawKind: UInt8, flags: UInt8, name: String) {
            self.kind = rawKind
            self.flags = flags
            self.name = Self.truncated(name)
        }

        public var hostKind: HostKind { HostKind(rawValue: kind) ?? .other }
        public var isAccepting: Bool { flags & RAVEQuestBridgeProtocol.hostAccepting != 0 }

        /// `name` cut to the field, whole characters only (a grapheme never
        /// splits, so the Quest never shows half an emoji).
        static func truncated(_ name: String) -> String {
            var out = ""
            var bytes = 0
            for character in name {
                let n = character.utf8.count
                if bytes + n > RAVEQuestBridgeProtocol.hostNameMaxBytes { break }
                out.append(character)
                bytes += n
            }
            return out
        }

        /// Reads the 48 bytes starting at `offset`.
        init(bytes: UnsafeRawBufferPointer, offset: Int) {
            kind = bytes[offset]
            flags = bytes[offset + 1]
            let length = min(Int(bytes[offset + 2]), RAVEQuestBridgeProtocol.hostNameMaxBytes)
            let start = offset + 4
            name = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<start + length]),
                          as: UTF8.self)
        }

        fileprivate func encode(into w: inout ByteWriter) {
            let utf8 = Array(name.utf8.prefix(RAVEQuestBridgeProtocol.hostNameMaxBytes))
            w.u8(kind)
            w.u8(flags)
            w.u8(UInt8(utf8.count))
            w.u8(0)                                  // reserved
            for b in utf8 { w.u8(b) }
            for _ in utf8.count..<RAVEQuestBridgeProtocol.hostNameMaxBytes { w.u8(0) }
        }
    }

    /// `qcb_status_packet_t`, 16 bytes, host → Quest: a probe reply (nonce
    /// echoed) or an unsolicited heartbeat (nonce 0). A probe reply at v3+
    /// carries `hostInfo` too (`qcb_status_ex_packet_t`, 64 bytes).
    public struct Status: Sendable, Equatable {
        public static let size = 16
        /// With the host-info trailer.
        public static let extendedSize = 64
        public var protocolVersion: UInt8
        public var flags: UInt16
        public var nonce: UInt32
        public var packetsReceived: UInt32
        /// Encoded only when set; decoded only when `protocolVersion` >= 3 and
        /// the datagram holds all 64 bytes (a shorter one is an older host).
        public var hostInfo: HostInfo?

        public init(protocolVersion: UInt8, flags: UInt16 = RAVEQuestBridgeProtocol.statusDriverReady,
                    nonce: UInt32 = 0, packetsReceived: UInt32, hostInfo: HostInfo? = nil) {
            self.protocolVersion = protocolVersion
            self.flags = flags
            self.nonce = nonce
            self.packetsReceived = packetsReceived
            self.hostInfo = hostInfo
        }

        public init?(bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= Self.size, bytes[0] == PacketType.status.rawValue else { return nil }
            var r = ByteReader(bytes, offset: 1)
            protocolVersion = r.u8()
            flags = r.u16()
            nonce = r.u32()
            packetsReceived = r.u32()
            if protocolVersion >= RAVEQuestBridgeProtocol.hostInfoVersion, bytes.count >= Self.extendedSize {
                hostInfo = HostInfo(bytes: bytes, offset: Self.size)
            }
        }

        public init?(_ bytes: [UInt8]) {
            guard let value = bytes.withUnsafeBytes({ Status(bytes: $0) }) else { return nil }
            self = value
        }

        public func encoded() -> [UInt8] {
            var w = ByteWriter(capacity: Self.extendedSize)
            w.u8(PacketType.status.rawValue)
            w.u8(protocolVersion)
            w.u16(flags)
            w.u32(nonce)
            w.u32(packetsReceived)
            w.u32(0)                                 // reserved
            hostInfo?.encode(into: &w)
            return w.bytes
        }
    }

    /// Any packet this protocol defines.
    public enum Packet: Sendable, Equatable {
        case controllerState(ControllerState)
        case haptic(Haptic)
        case probe(Probe)
        case status(Status)
    }

    /// Decode one datagram, or nil for anything unknown or short. Longer
    /// datagrams decode their known prefix — a future version may append.
    public static func decode(_ bytes: UnsafeRawBufferPointer) -> Packet? {
        guard let first = bytes.first, let type = PacketType(rawValue: first) else { return nil }
        switch type {
        case .controllerState: return ControllerState(bytes: bytes).map(Packet.controllerState)
        case .haptic: return Haptic(bytes: bytes).map(Packet.haptic)
        case .probe: return Probe(bytes: bytes).map(Packet.probe)
        case .status: return Status(bytes: bytes).map(Packet.status)
        }
    }

    public static func decode(_ bytes: [UInt8]) -> Packet? {
        bytes.withUnsafeBytes { decode($0) }
    }
}

// MARK: - Little-endian byte helpers

private struct ByteReader {
    let bytes: UnsafeRawBufferPointer
    var offset: Int

    init(_ bytes: UnsafeRawBufferPointer, offset: Int) {
        self.bytes = bytes
        self.offset = offset
    }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16 {
        defer { offset += 2 }
        return UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    mutating func u32() -> UInt32 {
        defer { offset += 4 }
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func vec3() -> SIMD3<Float> { SIMD3(f32(), f32(), f32()) }
    mutating func vec4() -> SIMD4<Float> { SIMD4(f32(), f32(), f32(), f32()) }
}

private struct ByteWriter {
    var bytes: [UInt8]

    init(capacity: Int) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift))) }
    }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func vec3(_ v: SIMD3<Float>) { f32(v.x); f32(v.y); f32(v.z) }
    mutating func vec4(_ v: SIMD4<Float>) { f32(v.x); f32(v.y); f32(v.z); f32(v.w) }
}
