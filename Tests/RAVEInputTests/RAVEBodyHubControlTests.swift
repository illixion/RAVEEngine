import Foundation
import Testing
import simd
@testable import RAVEInput

@Suite("Body hub control")
struct RAVEBodyHubControlTests {

    private func payload(_ datagram: [UInt8]) throws -> [String: Any] {
        #expect(Array(datagram[0..<4]) == RAVEBodyStreamProtocol.magic)
        #expect(datagram[4] == 1)
        return try #require(JSONSerialization.jsonObject(with: Data(datagram[6...])) as? [String: Any])
    }

    @Test("Commands are type 8 with a JSON body")
    func commands() throws {
        let recalibrate = try #require(RAVEBodyStreamProtocol.command(.recalibrate))
        #expect(recalibrate[5] == 8)
        #expect(try payload(recalibrate)["cmd"] as? String == "recalibrate")
        #expect(try payload(#require(RAVEBodyStreamProtocol.command(.hold)))["cmd"] as? String == "hold")
        #expect(try payload(#require(RAVEBodyStreamProtocol.command(.resume)))["cmd"] as? String == "resume")
    }

    @Test("configure carries only what it was given, and clamps to the hub's ranges")
    func configure() throws {
        let some = try payload(#require(RAVEBodyStreamProtocol.command(.configure(cameras: 3, height: nil, movedPx: nil))))
        #expect(some["cameras"] as? Int == 3)
        #expect(some["height"] == nil && some["movedPx"] == nil)
        let wild = try payload(#require(RAVEBodyStreamProtocol.command(.configure(cameras: 99, height: 5, movedPx: 1)))) 
        #expect(wild["cameras"] as? Int == 8)
        #expect(wild["height"] as? Double == 2.3)
        #expect(wild["movedPx"] as? Double == 4)
        let low = try payload(#require(RAVEBodyStreamProtocol.command(.configure(cameras: 0, height: 0.2, movedPx: nil))))
        #expect(low["cameras"] as? Int == 2)
        #expect(low["height"] as? Double == 1.2)
    }

    @Test("record starts and stops, with a bounded name")
    func record() throws {
        let start = try payload(#require(RAVEBodyStreamProtocol.command(.record(start: true, name: String(repeating: "a", count: 200)))))
        #expect(start["action"] as? String == "start")
        #expect((start["name"] as? String)?.count == 64)
        let stop = try payload(#require(RAVEBodyStreamProtocol.command(.record(start: false, name: nil))))
        #expect(stop["action"] as? String == "stop")
        #expect(stop["name"] == nil)
    }

    @Test("A subscription asks for previews with flag bit 0")
    func subscribeFlags() {
        let plain = RAVEBodyStreamProtocol.subscribe(name: "x")
        let asking = RAVEBodyStreamProtocol.subscribe(name: "x", wantsPreview: true)
        #expect(plain[6] == 0)
        #expect(asking[6] == 1)
        #expect(Array(asking.dropFirst(7)) == Array(plain.dropFirst(7)))
    }

    private func f32(_ v: Float) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v.bitPattern >> ($0 * 8)) } }
    private func f64(_ v: Double) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v.bitPattern >> ($0 * 8)) } }

    private func previewBytes(joints: [(UInt8, UInt8, Float, Float)], flags: UInt8 = 1) -> [UInt8] {
        var out = RAVEBodyStreamProtocol.magic + [1, 9, 1, flags]
        out += f64(12.5) + f32(0.5625) + [UInt8(joints.count)]
        for (id, confidence, u, v) in joints { out += [id, confidence] + f32(u) + f32(v) }
        return out
    }

    @Test("Decodes a preview: the camera, its joints and their picture positions")
    func preview() throws {
        let bytes = previewBytes(joints: [(0, 255, 0.5, 0.1), (27, 128, 0.4, 0.95), (99, 255, 0.1, 0.1)])
        let preview = try #require(RAVEBodyStreamProtocol.decodePreview(bytes))
        #expect(preview.camera == 1)
        #expect(preview.personSeen)
        #expect(preview.captureTime == 12.5)
        #expect(preview.aspect == 0.5625)
        #expect(preview.joints.count == 2, "an unknown id is skipped")
        #expect(preview.joints[.nose]?.point == SIMD2(0.5, 0.1))
        #expect(abs((preview.joints[.leftAnkle]?.confidence ?? 0) - 0.5) < 0.01)
    }

    @Test("Refuses a truncated, foreign or non-finite preview")
    func previewRefusals() {
        let good = previewBytes(joints: [(0, 255, 0.5, 0.1)])
        #expect(RAVEBodyStreamProtocol.decodePreview(Array(good.dropLast())) == nil)
        #expect(RAVEBodyStreamProtocol.decodePreview(Array(good.prefix(10))) == nil)
        var other = good
        other[5] = 2
        #expect(RAVEBodyStreamProtocol.decodePreview(other) == nil)
        var nan = good
        nan.replaceSubrange(nan.count - 8..<nan.count - 4, with: f32(.nan))
        #expect(RAVEBodyStreamProtocol.decodePreview(nan)?.joints.isEmpty == true)
    }

    @Test("Status carries camera poses, controls and the last answer; an old hub's status still reads")
    func status() throws {
        let json = """
        {"state":"held","prompt":"held","text":"Paused","progress":0.2,"expected":3,"height":1.78,"movedPx":12,
         "held":true,"restarts":2,"recording":{"name":"squat","seconds":3.5,"frames":105},
         "ack":{"cmd":"configure","ok":false,"error":"cameras must be 2...8"},
         "cameras":[{"label":"camera 1","live":true,"fps":30,"framing":"ok","placed":true,"moved":false,
                     "progress":1,"errorPx":1.5,"seenJoints":19,"portrait":true,"fov":{"h":43,"v":70},
                     "pose":{"position":[1,1.2,-2],"forward":[0,0,1],"up":[0,1,0]}},
                    {"label":"camera 2","pose":null}]}
        """
        let bytes = RAVEBodyStreamProtocol.magic + [1, 7] + [UInt8](json.utf8)
        let status = try #require(RAVEBodyStreamProtocol.decodeStatus(bytes))
        #expect(status.knownState == .held)
        #expect(status.held && status.expected == 3 && status.height == 1.78 && status.movedPx == 12)
        #expect(status.restarts == 2)
        #expect(status.recording == .init(name: "squat", seconds: 3.5, frames: 105))
        #expect(status.ack == .init(cmd: "configure", ok: false, error: "cameras must be 2...8"))
        let first = status.cameras[0]
        #expect(first.pose == .init(position: [1, 1.2, -2], forward: [0, 0, 1], up: [0, 1, 0]))
        #expect(first.horizontalFov == 43 && first.verticalFov == 70 && first.portrait && first.seenJoints == 19)
        #expect(status.cameras[1].pose == nil && !status.cameras[1].portrait)

        let old = RAVEBodyStreamProtocol.magic + [1, 7] + Array(#"{"state":"tracking","cameras":[{"label":"a"}]}"#.utf8)
        let legacy = try #require(RAVEBodyStreamProtocol.decodeStatus(old))
        #expect(!legacy.held && legacy.expected == nil && legacy.recording == nil && legacy.ack == nil)
    }

    @Test("A malformed pose drops the pose, not the status")
    func badPose() throws {
        let json = #"{"state":"tracking","cameras":[{"label":"a","pose":{"position":[1,2],"forward":[0,0,1],"up":[0,1,0]}}]}"#
        let status = try #require(RAVEBodyStreamProtocol.decodeStatus(RAVEBodyStreamProtocol.magic + [1, 7] + Array(json.utf8)))
        #expect(status.cameras.count == 1 && status.cameras[0].pose == nil)
    }
}
