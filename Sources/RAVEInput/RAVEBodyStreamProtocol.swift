/*
 RAVE Engine — the body stream: a whole body from cameras, as joints and
 tracker poses.

 PoseHub (miscale's `Tools/PoseHub`) watches the performer with two or more
 cameras, triangulates a metric skeleton and sends it over UDP to whoever
 subscribes. The wire format is specified once, in
 `Tools/PoseHub/BODY_STREAM.md`; this file is its Swift decoder, and the
 shared fixture in `RAVEBodyStreamTests` pins it to the hub's encoder (and to
 the Longwave broker's C++ decoder, which reads the same bytes).

 The space a frame comes in: metres, right-handed, +Y up, the floor at y = 0,
 the origin on the floor under the performer at calibration. Its horizontal
 axes are the cameras' business, so a consumer with a world of its own (the
 headset's) fits yaw and offset to it — `RAVEBodyAlignment` — and moves frames
 into it with `transformed(yaw:translation:)`.

 Tracker rotations use RAVERig's body frame, +X to the tracker's left, +Y up,
 +Z forward, so a hips or foot pose goes straight into a
 `PerformerLowerBody`. Pure value types, isolation-free.
 */

import simd

public enum RAVEBodyStreamProtocol {
    public static let magic: [UInt8] = Array("PHBS".utf8)
    public static let version: UInt8 = 1
    /// The hub's UDP port.
    public static let defaultPort: UInt16 = 7711
    /// What the hub advertises itself as.
    public static let bonjourServiceType = "_posehub._udp"
    /// A subscription lapses after 3 s of silence at the hub; resend well
    /// inside that.
    public static let subscribeInterval: Double = 1

    enum Kind: UInt8 {
        case subscribe = 1
        case frame = 2
        case unsubscribe = 3
        case ping = 4
        case pong = 5
        case reference = 6
    }

    static let headerSize = 6
    static let frameHeaderSize = 30
    static let jointSize = 14
    static let trackerSize = 30

    /// SUBSCRIBE: the consumer's `name` shows in the hub's log.
    public static func subscribe(name: String) -> [UInt8] {
        let raw = Array(name.utf8.prefix(64))
        return header(.subscribe) + [0, 0, UInt8(raw.count)] + raw
    }

    public static func unsubscribe() -> [UInt8] { header(.unsubscribe) }

    public static func ping(sentAt: Double) -> [UInt8] {
        header(.ping) + (0..<8).map { UInt8(truncatingIfNeeded: sentAt.bitPattern >> ($0 * 8)) }
    }

    public struct Pong: Sendable {
        public var sent: Double
        public var hubReceived: Double
        public var hubSent: Double
    }

    public static func decodePong(_ bytes: [UInt8]) -> Pong? {
        guard bytes.count == 30, Array(bytes[0..<4]) == magic,
              bytes[4] == version, bytes[5] == Kind.pong.rawValue else { return nil }
        var reader = Reader(bytes: bytes, at: headerSize)
        let pong = Pong(sent: reader.f64(), hubReceived: reader.f64(), hubSent: reader.f64())
        return [pong.sent, pong.hubReceived, pong.hubSent].allSatisfy(\.isFinite) ? pong : nil
    }

    /// Headset observations in the hub's space and clock. Head is between
    /// the ears, using the stream's anatomical frame; wrists are optional.
    public static func reference(generation: UInt64, time: Double, head: RAVEBodyTrackerPose,
                                 leftWrist: SIMD3<Float>?, rightWrist: SIMD3<Float>?) -> [UInt8] {
        var out = header(.reference)
        func u64(_ bits: UInt64) { out += (0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) } }
        func f32(_ value: Float) { out += (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) } }
        func point(_ p: SIMD3<Float>) { f32(p.x); f32(p.y); f32(p.z) }
        u64(generation)
        u64(time.bitPattern)
        out.append((leftWrist == nil ? 0 : 1) | (rightWrist == nil ? 0 : 2))
        point(head.position)
        for value in [head.rotation.imag.x, head.rotation.imag.y, head.rotation.imag.z, head.rotation.real] { f32(value) }
        if let leftWrist { point(leftWrist) }
        if let rightWrist { point(rightWrist) }
        return out
    }

    static func header(_ kind: Kind) -> [UInt8] { magic + [version, kind.rawValue] }

    /// A FRAME datagram, or nil for anything else: another type, another
    /// version, a foreign or truncated datagram. Bytes past the trackers are
    /// ignored (room for later fields).
    public static func decodeFrame(_ bytes: [UInt8]) -> RAVEBodyFrame? {
        guard bytes.count >= frameHeaderSize,
              Array(bytes[0..<4]) == magic, bytes[4] == version, bytes[5] == Kind.frame.rawValue else { return nil }
        var reader = Reader(bytes: bytes, at: headerSize)
        let flags = reader.u16()
        let sequence = reader.u32()
        let captureTime = reader.f64()
        let latency = reader.f32()
        let height = reader.f32()
        let jointCount = Int(reader.u8())
        let trackerCount = Int(reader.u8())
        guard captureTime.isFinite, latency.isFinite, latency >= 0,
              height.isFinite, height > 0 else { return nil }
        guard bytes.count >= frameHeaderSize + jointCount * jointSize + trackerCount * trackerSize else { return nil }
        var joints: [RAVEBodyJoint: RAVEBodyJointSample] = [:]
        for _ in 0..<jointCount {
            let id = reader.u8()
            let confidence = Float(reader.u8()) / 255
            let position = reader.vector()
            if let joint = RAVEBodyJoint(rawValue: id), position.isFinite {
                joints[joint] = RAVEBodyJointSample(position: position, confidence: confidence)
            }
        }
        var trackers: [RAVEBodyTrackerRole: RAVEBodyTrackerPose] = [:]
        for _ in 0..<trackerCount {
            let role = reader.u8()
            let confidence = Float(reader.u8()) / 255
            let position = reader.vector()
            let q = SIMD4<Float>(reader.f32(), reader.f32(), reader.f32(), reader.f32())
            let length = simd_length(q)
            guard let role = RAVEBodyTrackerRole(rawValue: role), position.isFinite,
                  length.isFinite, length > 0.5, length < 1.5 else { continue }
            trackers[role] = RAVEBodyTrackerPose(position: position, rotation: simd_normalize(simd_quatf(vector: q)),
                                                 confidence: confidence)
        }
        var frame = RAVEBodyFrame(sequence: sequence, captureTime: captureTime, latency: latency, height: height,
                                 calibrationLoaded: flags & 1 != 0, joints: joints, trackers: trackers)
        frame.headIsReference = flags & 2 != 0
        // Optional extension. Old v1 receivers ignore these trailing bytes.
        if bytes.count >= reader.at + 12, Array(bytes[reader.at..<reader.at + 4]) == Array("PHX1".utf8) {
            reader.at += 4
            frame.generation = reader.u64()
        }
        return frame
    }

    /// Little-endian reads; the caller has checked the length.
    struct Reader {
        let bytes: [UInt8]
        var at: Int

        mutating func u8() -> UInt8 {
            defer { at += 1 }
            return bytes[at]
        }

        mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }

        mutating func u32() -> UInt32 {
            var v: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) { v |= UInt32(u8()) << UInt32(shift) }
            return v
        }

        mutating func u64() -> UInt64 {
            var v: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 8) { v |= UInt64(u8()) << UInt64(shift) }
            return v
        }

        mutating func f32() -> Float { Float(bitPattern: u32()) }
        mutating func f64() -> Double { Double(bitPattern: u64()) }
        mutating func vector() -> SIMD3<Float> { SIMD3(f32(), f32(), f32()) }
    }
}

/// A body joint, by its BlazePose landmark index. Left and right are the
/// performer's own.
public enum RAVEBodyJoint: UInt8, CaseIterable, Sendable {
    case nose = 0
    case leftEye = 2
    case rightEye = 5
    case leftEar = 7
    case rightEar = 8
    case leftShoulder = 11
    case rightShoulder = 12
    case leftElbow = 13
    case rightElbow = 14
    case leftWrist = 15
    case rightWrist = 16
    case leftHip = 23
    case rightHip = 24
    case leftKnee = 25
    case rightKnee = 26
    case leftAnkle = 27
    case rightAnkle = 28
    case leftHeel = 29
    case rightHeel = 30
    case leftBigToe = 31
    case rightBigToe = 32
}

/// A pose the hub derives from the joints, the way a tracker strapped there
/// would report it.
public enum RAVEBodyTrackerRole: UInt8, CaseIterable, Sendable {
    /// Between the ears, facing the nose.
    case head = 0
    /// Between the hip joints.
    case hips = 1
    /// At the ankle, forward from heel to toe.
    case leftFoot = 2
    case rightFoot = 3
    /// At the knee, facing as the foot does.
    case leftKnee = 4
    case rightKnee = 5
    /// Between the shoulders.
    case chest = 6
}

public struct RAVEBodyJointSample: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// 0 to 1: the weakest camera's confidence in it.
    public var confidence: Float

    public init(position: SIMD3<Float>, confidence: Float) {
        self.position = position
        self.confidence = confidence
    }
}

public struct RAVEBodyTrackerPose: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// +X to the tracker's left, +Y up, +Z forward.
    public var rotation: simd_quatf
    /// 0 to 1: its weakest joint's.
    public var confidence: Float

    public init(position: SIMD3<Float>, rotation: simd_quatf, confidence: Float) {
        self.position = position
        self.rotation = rotation
        self.confidence = confidence
    }
}

/// One fused skeleton.
public struct RAVEBodyFrame: Sendable, Equatable {
    /// Changes whenever the hub restarts or recalibrates its cameras.
    public var generation: UInt64? = nil
    /// The head tracker is a headset reference, not an independent camera
    /// measurement. Do not feed it back into camera-space alignment.
    public var headIsReference = false
    /// +1 per frame at the hub.
    public var sequence: UInt32
    /// When the cameras saw it, on the hub's clock (seconds). Useful only for
    /// differences: the hub's clock is not this device's.
    public var captureTime: Double
    /// Seconds from the cameras seeing it to the hub sending it.
    public var latency: Float
    /// The performer's height as the hub was told it; the scale comes from it.
    public var height: Float
    /// The hub loaded a saved camera calibration rather than solving one.
    public var calibrationLoaded: Bool
    /// The joints at least two cameras saw.
    public var joints: [RAVEBodyJoint: RAVEBodyJointSample]
    public var trackers: [RAVEBodyTrackerRole: RAVEBodyTrackerPose]
    /// Where the hub's floor is in this frame's space: 0 until transformed.
    public var floor: Float = 0

    public init(sequence: UInt32, captureTime: Double, latency: Float, height: Float, calibrationLoaded: Bool,
                joints: [RAVEBodyJoint: RAVEBodyJointSample], trackers: [RAVEBodyTrackerRole: RAVEBodyTrackerPose]) {
        self.sequence = sequence
        self.captureTime = captureTime
        self.latency = latency
        self.height = height
        self.calibrationLoaded = calibrationLoaded
        self.joints = joints
        self.trackers = trackers
    }

    /// The frame moved into another gravity-aligned space: turned `yaw`
    /// radians about +Y (right-handed, `simd_quatf(angle: yaw, axis: +Y)`),
    /// then moved by `translation`.
    public func transformed(yaw: Float, translation: SIMD3<Float>) -> RAVEBodyFrame {
        let turn = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        var out = self
        out.joints = joints.mapValues { RAVEBodyJointSample(position: turn.act($0.position) + translation, confidence: $0.confidence) }
        out.trackers = trackers.mapValues {
            RAVEBodyTrackerPose(position: turn.act($0.position) + translation, rotation: simd_normalize(turn * $0.rotation),
                                confidence: $0.confidence)
        }
        out.floor = floor + translation.y
        return out
    }
}

extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
