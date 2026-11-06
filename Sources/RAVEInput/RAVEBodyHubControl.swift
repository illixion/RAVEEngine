/*
 RAVE Engine — telling a PoseHub what to do, and seeing what its cameras see.

 Two more datagrams of the body stream (`Tools/PoseHub/BODY_STREAM.md`):
 type 8, COMMAND, a consumer's JSON request to the hub (recalibrate, hold,
 configure, record), answered in the next status's `ack`; and type 9,
 PREVIEW, one camera's joints in its own upright picture, sent only to a
 subscriber that asked for them (SUBSCRIBE flag bit 0). Together they let a
 headset run the whole calibration: start it, set how many cameras there are,
 and watch each camera's view of the person.
 */

import Foundation

/// A request to the hub. Each case is one `cmd` of the COMMAND datagram.
public enum RAVEBodyHubCommand: Sendable, Equatable {
    /// Forget the calibration and collect again.
    case recalibrate
    /// Stop collecting and solving (tracking carries on if calibrated).
    case hold
    case resume
    /// Cameras the hub waits for (2...8), the performer's height (m) and,
    /// optionally, the disagreement (px) that counts as a moved camera.
    case configure(cameras: Int?, height: Double?, movedPx: Double?)
    /// A cameras-only take on the hub's disk.
    case record(start: Bool, name: String?)

    public var name: String {
        switch self {
        case .recalibrate: "recalibrate"
        case .hold: "hold"
        case .resume: "resume"
        case .configure: "configure"
        case .record: "record"
        }
    }

    var json: [String: Any] {
        var out: [String: Any] = ["cmd": name]
        switch self {
        case .configure(let cameras, let height, let movedPx):
            if let cameras { out["cameras"] = min(8, max(2, cameras)) }
            if let height { out["height"] = min(2.3, max(1.2, height)) }
            if let movedPx { out["movedPx"] = min(1000, max(4, movedPx)) }
        case .record(let start, let name):
            out["action"] = start ? "start" : "stop"
            if let name { out["name"] = String(name.prefix(64)) }
        default:
            break
        }
        return out
    }
}

/// One camera's joints in its upright picture, normalised, origin top left.
public struct RAVEBodyPreview: Sendable, Equatable {
    public var camera: Int
    public var personSeen: Bool
    /// Hub clock, seconds.
    public var captureTime: Double
    /// Width over height of the upright picture.
    public var aspect: Float
    public var joints: [RAVEBodyJoint: Joint]

    public struct Joint: Sendable, Equatable {
        public var point: SIMD2<Float>
        public var confidence: Float
    }

    /// The bones to draw between joints, as pairs.
    public static let bones: [(RAVEBodyJoint, RAVEBodyJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle), (.leftAnkle, .leftHeel), (.leftHeel, .leftBigToe),
        (.leftAnkle, .leftBigToe), (.rightAnkle, .rightHeel), (.rightHeel, .rightBigToe),
        (.rightAnkle, .rightBigToe), (.leftEar, .nose), (.rightEar, .nose),
    ]
}

extension RAVEBodyStreamProtocol {
    /// SUBSCRIBE asking for PREVIEW datagrams too.
    public static func subscribe(name: String, wantsPreview: Bool) -> [UInt8] {
        let raw = Array(name.utf8.prefix(64))
        return header(.subscribe) + [wantsPreview ? 1 : 0, 0, UInt8(raw.count)] + raw
    }

    /// A COMMAND datagram, or nil when it would not fit in 1 KB.
    public static func command(_ command: RAVEBodyHubCommand) -> [UInt8]? {
        guard let data = try? JSONSerialization.data(withJSONObject: command.json, options: [.sortedKeys]),
              data.count <= 1024 else { return nil }
        return header(.command) + [UInt8](data)
    }

    /// A PREVIEW datagram, or nil for anything else.
    public static func decodePreview(_ bytes: [UInt8]) -> RAVEBodyPreview? {
        let fixed = headerSize + 1 + 1 + 8 + 4 + 1
        guard bytes.count >= fixed, Array(bytes[0..<4]) == magic, bytes[4] == version,
              bytes[5] == Kind.preview.rawValue else { return nil }
        var reader = Reader(bytes: bytes, at: headerSize)
        let camera = Int(reader.u8())
        let flags = reader.u8()
        let time = reader.f64()
        let aspect = reader.f32()
        let count = Int(reader.u8())
        guard time.isFinite, aspect.isFinite, aspect > 0, bytes.count >= fixed + count * 10 else { return nil }
        var joints: [RAVEBodyJoint: RAVEBodyPreview.Joint] = [:]
        for _ in 0..<count {
            let id = reader.u8()
            let confidence = Float(reader.u8()) / 255
            let u = reader.f32(), v = reader.f32()
            if let joint = RAVEBodyJoint(rawValue: id), u.isFinite, v.isFinite {
                joints[joint] = .init(point: SIMD2(u, v), confidence: confidence)
            }
        }
        return RAVEBodyPreview(camera: camera, personSeen: flags & 1 != 0, captureTime: time, aspect: aspect, joints: joints)
    }
}
