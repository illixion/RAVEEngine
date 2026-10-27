/*
 RAVE Engine — what a PoseHub says while a person sets its cameras up.

 Twice a second the hub sends its setup state to every subscriber (the body
 stream's type 7, `Tools/PoseHub/BODY_STREAM.md`): whether it is waiting for
 cameras, calibrating or tracking, one prompt for what to do next, and per
 camera whether it frames the person and how much of the calibration it has
 seen. An app shows or says it as it is, so setup reads the same on a phone,
 a headset or a PC. States and fractions only, never positions.

 Codes are kept as strings so a newer hub's states pass through; the enums
 below name the ones this version knows.
 */

import Foundation

public struct RAVEBodyHubStatus: Sendable, Equatable, Decodable {
    /// `waiting`, `calibrating`, `solving`, `failed`, `tracking`.
    public var state: String
    /// What to do next: `addCameras`, `stepIn`, `frame`, `move`, `solving`,
    /// `retry`, `tracking`.
    public var prompt: String
    /// The prompt in English, ready to show or speak.
    public var text: String
    /// 0–1, the calibration so far; 1 when tracking.
    public var progress: Double
    /// Where the metres come from: `height`, `legs` or `headset`.
    public var scale: String?
    /// The calibration generation (hex) the frames carry.
    public var generation: String?
    public var cameras: [Camera]

    public enum State: String, Sendable {
        case waiting, calibrating, solving, failed, tracking
    }

    public var knownState: State? { State(rawValue: state) }
    public var isTracking: Bool { state == State.tracking.rawValue }

    public struct Camera: Sendable, Equatable, Decodable {
        /// "camera 2 (Front Ultra Wide)".
        public var label: String
        public var device: String?
        public var live: Bool
        public var framesPerSecond: Double
        /// `ok`, `none`, `close`, `feet`, `head`, `far`.
        public var framing: String
        /// Solved into the space and contributing.
        public var placed: Bool
        /// Knocked or picked up: out until solved again.
        public var moved: Bool
        /// 0–1, this camera's share of the calibration.
        public var progress: Double
        /// Median disagreement with the other cameras, pixels at 720p.
        public var errorPx: Double?

        /// A short note for a list row: what is wrong with its view, else
        /// how far along it is.
        public var note: String {
            if moved { return "moved: keep moving in its view" }
            switch framing {
            case "none": return "can't see you"
            case "close": return "too close"
            case "feet": return "feet cut off"
            case "head": return placed ? "sees your legs" : "head cut off"
            case "far": return "too far"
            default: break
            }
            return placed ? "placed" : "\(Int((progress * 100).rounded()))%"
        }

        enum CodingKeys: String, CodingKey {
            case label, device, live, fps, framing, placed, moved, progress, errorPx
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? "camera"
            device = try c.decodeIfPresent(String.self, forKey: .device)
            live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
            framesPerSecond = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 0
            framing = try c.decodeIfPresent(String.self, forKey: .framing) ?? "none"
            placed = try c.decodeIfPresent(Bool.self, forKey: .placed) ?? false
            moved = try c.decodeIfPresent(Bool.self, forKey: .moved) ?? false
            progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            errorPx = try c.decodeIfPresent(Double.self, forKey: .errorPx)
        }
    }

    enum CodingKeys: String, CodingKey {
        case state, prompt, text, progress, scale, generation, cameras
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        progress = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0))
        scale = try c.decodeIfPresent(String.self, forKey: .scale)
        generation = try c.decodeIfPresent(String.self, forKey: .generation)
        cameras = try c.decodeIfPresent([Camera].self, forKey: .cameras) ?? []
    }
}

extension RAVEBodyStreamProtocol {
    /// A STATUS datagram (type 7), or nil for anything else.
    public static func decodeStatus(_ bytes: [UInt8]) -> RAVEBodyHubStatus? {
        guard bytes.count > headerSize, Array(bytes[0..<4]) == magic, bytes[4] == version,
              bytes[5] == Kind.status.rawValue else { return nil }
        return try? JSONDecoder().decode(RAVEBodyHubStatus.self, from: Data(bytes[headerSize...]))
    }
}
