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

/// PoseHub's control fixtures (`Tools/PoseHub/tests/body_stream_*_fixture.hex`
/// in miscale), copied verbatim: the hub's encoder and this decoder must agree.
@Suite("Body hub control fixtures")
struct RAVEBodyHubControlFixtureTests {
    let subscribe = "50484253010101000766697874757265"
    let command = "5048425301087b22636d64223a22636f6e666967757265222c2263616d65726173223a332c22686569676874223a312e382c226d6f7665645078223a31322e302c226964223a377d"
    let preview = "504842530109010100000000004a93400000103f0400e60000003fcdcccc3d0bcccdcccc3e9a99993e0c339a99193f9a99993e1bff6666e63e3333733f"
    let status = "5048425301077b227374617465223a2263616c6962726174696e67222c2270726f6d7074223a226d6f7665222c2274657874223a224b656570206d6f76696e673a2073717561742c2073746570207369646520746f207369646520616e64207761766520796f75722061726d73222c2270726f6772657373223a302e342c227363616c65223a6e756c6c2c2267656e65726174696f6e223a2239663063326137643131653034623561222c226578706563746564223a322c22686569676874223a312e37352c226d6f7665645078223a382e302c2268656c64223a66616c73652c227265737461727473223a312c227265636f7264696e67223a7b226e616d65223a22737175617473222c227365636f6e6473223a342e322c226672616d6573223a3235307d2c2261636b223a7b22636d64223a22636f6e666967757265222c226f6b223a66616c73652c226572726f72223a22686569676874206d75737420626520312e3220746f20322e33206d6574726573222c226964223a377d2c2263616d65726173223a5b7b22696e646578223a302c226c6162656c223a2263616d657261203120284261636b29222c22646576696365223a226950686f6e6531362c32222c226c697665223a747275652c22667073223a33302e302c226672616d696e67223a226f6b222c22706c61636564223a747275652c226d6f766564223a66616c73652c2270726f6772657373223a312e302c226d6f76656d656e74223a312e302c226572726f725078223a312e322c226c656e73223a227265706f72746564222c22706f7365223a7b22706f736974696f6e223a5b302e302c312e302c302e305d2c22666f7277617264223a5b302e302c302e302c2d312e305d2c227570223a5b302e302c312e302c302e305d7d2c22666f76223a7b2268223a34362e302c2276223a37342e367d2c22706f727472616974223a747275652c227365656e4a6f696e7473223a31392c22736565696e67223a747275657d2c7b22696e646578223a312c226c6162656c223a2263616d6572612032202846726f6e7420556c747261205769646529222c22646576696365223a2269506164222c226c697665223a747275652c22667073223a33302e302c226672616d696e67223a226e6f6e65222c22706c61636564223a66616c73652c226d6f766564223a66616c73652c2270726f6772657373223a302e302c226d6f76656d656e74223a302e302c226572726f725078223a6e756c6c2c226c656e73223a22736f6c766564222c22706f7365223a6e756c6c2c22666f76223a7b2268223a37302e302c2276223a34332e367d2c22706f727472616974223a66616c73652c227365656e4a6f696e7473223a302c22736565696e67223a66616c73657d5d7d"

    @Test("Subscribe: the same bytes as the hub's, flag bit 0 set")
    func subscribeBytes() {
        #expect(RAVEBodyStreamProtocol.subscribe(name: "fixture", wantsPreview: true) == bytes(hex: subscribe))
    }

    @Test("Command: a configure decodes to the hub's JSON")
    func commandBytes() throws {
        let wire = bytes(hex: command)
        #expect(Array(wire[0..<6]) == RAVEBodyStreamProtocol.magic + [1, 8])
        let json = try #require(JSONSerialization.jsonObject(with: Data(wire[6...])) as? [String: Any])
        #expect(json["cmd"] as? String == "configure" && json["cameras"] as? Int == 3 && json["height"] as? Double == 1.8)
        // Ours carries the same fields (the hub's fixture adds an id Swift does not send).
        let ours = try #require(RAVEBodyStreamProtocol.command(.configure(cameras: 3, height: 1.8, movedPx: 12)))
        let mine = try #require(JSONSerialization.jsonObject(with: Data(ours[6...])) as? [String: Any])
        #expect(mine["cmd"] as? String == "configure" && mine["cameras"] as? Int == 3 && mine["movedPx"] as? Double == 12)
    }

    @Test("Preview: the hub's datagram decodes")
    func previewBytes() throws {
        let preview = try #require(RAVEBodyStreamProtocol.decodePreview(bytes(hex: preview)))
        #expect(preview.camera == 1 && preview.personSeen && preview.captureTime == 1234.5 && preview.aspect == 0.5625)
        #expect(preview.joints.count == 4)
        #expect(preview.joints[.nose]?.point == SIMD2(0.5, 0.1))
        #expect(abs((preview.joints[.nose]?.confidence ?? 0) - 0.902) < 0.01)
        #expect(preview.joints[.leftAnkle]?.confidence == 1)
    }

    @Test("Status: the hub's datagram decodes with every new field")
    func statusBytes() throws {
        let status = try #require(RAVEBodyStreamProtocol.decodeStatus(bytes(hex: status)))
        #expect(status.state == "calibrating" && status.expected == 2 && status.height == 1.75 && status.movedPx == 8)
        #expect(!status.held && status.restarts == 1)
        #expect(status.recording == .init(name: "squats", seconds: 4.2, frames: 250))
        #expect(status.ack?.ok == false && status.ack?.error == "height must be 1.2 to 2.3 metres")
        #expect(status.cameras.count == 2)
        let first = status.cameras[0]
        #expect(first.pose == .init(position: [0, 1, 0], forward: [0, 0, -1], up: [0, 1, 0]))
        #expect(first.horizontalFov == 46 && first.verticalFov == 74.6 && first.portrait && first.seenJoints == 19)
        #expect(status.cameras[1].pose == nil && !status.cameras[1].portrait && status.cameras[1].seenJoints == 0)
    }
}
