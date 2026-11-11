import Foundation
import Testing
import simd
@testable import RAVEGuardian

/// A 4 x 3 m room, 2.5 m high, walls at x = ±2 and z = ±1.5, floor at y = 0.
private func room(anchor: UUID = UUID()) -> (RAVEGuardianMap, UUID) {
    var map = RAVEGuardianMap()
    map.replace(anchor: anchor, with: RAVEGuardianDemoRoom.walls(center: .zero, width: 4, depth: 3))
    return (map, anchor)
}

@Suite struct RAVEGuardianGeometryTests {
    @Test func closestPointCoversFaceEdgeAndVertex() {
        let t = RAVEGuardianTriangle([0, 0, 0], [1, 0, 0], [0, 1, 0], surface: .wall)!
        #expect(simd_distance(t.closestPoint(to: [0.2, 0.2, 1]), [0.2, 0.2, 0]) < 1e-6)
        #expect(simd_distance(t.closestPoint(to: [0.5, -1, 0]), [0.5, 0, 0]) < 1e-6)
        #expect(simd_distance(t.closestPoint(to: [-1, -1, 0]), [0, 0, 0]) < 1e-6)
        #expect(simd_distance(t.closestPoint(to: [1, 1, 0]), [0.5, 0.5, 0]) < 1e-6)
    }

    @Test func normalIsOrientedIntoTheRoom() {
        let t = RAVEGuardianTriangle([0, 0, 0], [0, 1, 0], [1, 0, 0], inward: [0, 0, 1], surface: .wall)!
        #expect(t.normal.z > 0.99)
        #expect(RAVEGuardianTriangle([0, 0, 0], [1, 0, 0], [2, 0, 0], surface: .wall) == nil)
    }

    @Test func boundaryFacesMustStandUpright() {
        let floorish = RAVEGuardianTriangle([0, 0, 0], [1, 0, 0], [0, 0, 1], surface: .wall)!
        let upright = RAVEGuardianTriangle([0, 0, 0], [1, 0, 0], [0, 1, 0], surface: .wall)!
        #expect(!RAVEGuardianFaceFilter.accepts(floorish, floorY: 0))
        #expect(RAVEGuardianFaceFilter.accepts(upright, floorY: 0))
        let rug = RAVEGuardianTriangle([0, 0.02, 0], [1, 0.02, 0], [0, 0.05, 1], surface: .obstacle)!
        let table = RAVEGuardianTriangle([0, 0.7, 0], [1, 0.7, 0], [0, 0.72, 1], surface: .obstacle)!
        #expect(!RAVEGuardianFaceFilter.accepts(rug, floorY: 0))
        #expect(RAVEGuardianFaceFilter.accepts(table, floorY: 0))
    }
}

@Suite struct RAVEGuardianMapTests {
    @Test func chunksByMetreAndFindsTheNearestWall() throws {
        let (map, _) = room()
        #expect(map.chunks.count > 4)
        let hit = try #require(map.nearest(to: [1.6, 1.2, 0], within: 1, includeObstacles: false))
        #expect(abs(hit.distance - 0.4) < 1e-5)
        #expect(hit.normal.x < -0.99)
        #expect(map.nearest(to: [0, 1.2, 0], within: 1, includeObstacles: false) == nil)
    }

    @Test func replacingAnAnchorDropsItsOldChunksAndBumpsRevisions() {
        var (map, id) = room()
        let before = map.revision
        map.replace(anchor: id, with: [RAVEGuardianTriangle([0, 0, 0], [0.5, 0, 0], [0, 0.5, 0], surface: .wall)!])
        #expect(map.chunks.count == 1)
        #expect(map.revision == before + 1)
        map.remove(anchor: id)
        #expect(map.isEmpty)
    }

    @Test func obstaclesAreSkippedUnlessAsked() {
        var map = RAVEGuardianMap()
        map.replace(anchor: UUID(), with: [RAVEGuardianTriangle([0, 0.7, 0], [1, 0.7, 0], [0, 0.7, 1], surface: .obstacle)!])
        #expect(map.nearest(to: [0.2, 0.9, 0.2], within: 1, includeObstacles: false) == nil)
        #expect(map.nearest(to: [0.2, 0.9, 0.2], within: 1, includeObstacles: true) != nil)
    }
}

@Suite struct RAVEGuardianMonitorTests {
    let settings = RAVEGuardianSettings()

    @Test func alertRampsInsideTheMarginAndLooksAheadWhenFast() {
        let s = settings
        #expect(RAVEGuardianMonitor.alert(clearance: 1.0, approachSpeed: 0, settings: s) == 0)
        #expect(RAVEGuardianMonitor.alert(clearance: s.warningDistance * 0.2, approachSpeed: 0, settings: s) == 1)
        let mid = RAVEGuardianMonitor.alert(clearance: s.warningDistance * 0.6, approachSpeed: 0, settings: s)
        #expect(mid > 0 && mid < 1)
        // 0.8 m away, still: nothing. Punching at 2 m/s: full warning.
        #expect(RAVEGuardianMonitor.alert(clearance: 0.8, approachSpeed: 2, settings: s) == 1)
        // Below the minimum approach speed the lookahead is ignored.
        #expect(RAVEGuardianMonitor.alert(clearance: 0.8, approachSpeed: 0.2, settings: s) == 0)
        var off = s
        off.lookahead = 0
        #expect(RAVEGuardianMonitor.alert(clearance: 0.8, approachSpeed: 2, settings: off) == 0)
    }

    @Test func aFastHandLightsTheWallBeforeAStillOne() {
        let (map, _) = room()
        // Still hand 0.9 m from the +x wall: nothing.
        var still = RAVEGuardianMonitor()
        var frame = RAVEGuardianFrame()
        for i in 0..<30 {
            frame = still.update(probes: [.init(id: "hand", kind: .hand, position: [1.1, 1.2, 0])],
                                 time: Double(i) / 90, map: map, settings: settings)
        }
        #expect(frame.peakAlert == 0)
        #expect(frame.chunkOpacity.isEmpty)

        // The same spot reached at 2.5 m/s toward the wall: warned.
        var fast = RAVEGuardianMonitor()
        for i in 0..<30 {
            let x: Float = 0.4 + Float(i) / 90 * 2.5
            frame = fast.update(probes: [.init(id: "hand", kind: .hand, position: [min(x, 1.1), 1.2, 0])],
                                time: Double(i) / 90, map: map, settings: settings)
            if x >= 1.1 { break }
        }
        #expect(frame.peakAlert > 0.9)
        let state = try! #require(frame.probes.first)
        #expect(state.approachSpeed > 1.5)
        // Only the wall the hand is heading for lights up, not the far one.
        #expect(frame.chunkOpacity.keys.allSatisfy { map.chunks[$0]!.bounds.center.x > 0 })
        #expect(!frame.chunkOpacity.isEmpty)
    }

    @Test func opacityFadesOutAfterTheHandLeaves() {
        let (map, _) = room()
        var m = RAVEGuardianMonitor()
        var t = 0.0
        var frame = m.update(probes: [.init(id: "h", kind: .hand, position: [1.9, 1.2, 0])], time: t, map: map, settings: settings)
        #expect(frame.peakAlert == 1)
        let peak = frame.chunkOpacity.values.max() ?? 0
        #expect(peak > 0.8)
        for _ in 0..<10 {
            t += 1.0 / 90
            frame = m.update(probes: [.init(id: "h", kind: .hand, position: [0, 1.2, 0])], time: t, map: map, settings: settings)
        }
        let afterShort = frame.chunkOpacity.values.max() ?? 0
        #expect(afterShort > 0.2 && afterShort < peak)   // falls slowly, not off at once
        for _ in 0..<400 {
            t += 1.0 / 90
            frame = m.update(probes: [.init(id: "h", kind: .hand, position: [0, 1.2, 0])], time: t, map: map, settings: settings)
        }
        #expect(frame.chunkOpacity.isEmpty)
    }

    @Test func alwaysModeShowsNearbyWallsAtRest() {
        let (map, _) = room()
        var s = settings
        s.visibility = .always
        var m = RAVEGuardianMonitor()
        var frame = RAVEGuardianFrame()
        for i in 0..<120 {
            frame = m.update(probes: [.init(id: "head", kind: .head, position: [0, 1.6, 0])],
                             time: Double(i) / 90, map: map, settings: s)
        }
        #expect(frame.peakAlert == 0)
        #expect(!frame.chunkOpacity.isEmpty)
        for v in frame.chunkOpacity.values { #expect(abs(v - s.appearance.restingOpacity) < 0.02) }
    }

    @Test func disabledOrUnwatchedDrawsNothing() {
        let (map, _) = room()
        var off = settings
        off.isEnabled = false
        var m = RAVEGuardianMonitor()
        let probe = RAVEGuardianProbe(id: "h", kind: .hand, position: [1.95, 1.2, 0])
        #expect(m.update(probes: [probe], time: 0, map: map, settings: off).chunkOpacity.isEmpty)
        var noHands = settings
        noHands.watchesHands = false
        var m2 = RAVEGuardianMonitor()
        let frame = m2.update(probes: [probe], time: 0, map: map, settings: noHands)
        #expect(frame.probes.isEmpty)
        #expect(frame.chunkOpacity.isEmpty)
    }

    @Test func aTrackingGapDoesNotReadAsATeleportingPunch() {
        let (map, _) = room()
        var m = RAVEGuardianMonitor()
        _ = m.update(probes: [.init(id: "h", kind: .hand, position: [-1, 1.2, 0])], time: 0, map: map, settings: settings)
        let frame = m.update(probes: [.init(id: "h", kind: .hand, position: [1.0, 1.2, 0])], time: 1.0, map: map, settings: settings)
        #expect(frame.probes.first?.approachSpeed == 0)
        #expect(frame.peakAlert == 0)
    }
}

@Suite struct RAVEGuardianLayoutTests {
    @Test func uvsRunAlongTheWallInGridCells() {
        let t = RAVEGuardianTriangle([0, 0, -1], [1, 0, -1], [1, 1, -1], inward: [0, 0, 1], surface: .wall)!
        let layout = RAVEGuardianMeshLayout(triangles: [t], spacing: 0.25)
        #expect(layout.positions.count == 3 && layout.indices == [0, 1, 2])
        // Pushed toward the room by the surface offset.
        #expect(abs(layout.positions[0].z - (-1 + RAVEGuardianMeshLayout.surfaceOffset)) < 1e-6)
        // 1 m along the wall = 4 cells; 1 m up = 4 cells.
        #expect(abs(abs(layout.uvs[1].x - layout.uvs[0].x) - 4) < 1e-4)
        #expect(abs(layout.uvs[2].y - layout.uvs[1].y - 4) < 1e-4)
    }

    @Test func patternsDrawLinesOnTheTileEdges() {
        let grid = RAVEGuardianPattern.coverage(style: .grid, lineFraction: 0.1)
        let n = RAVEGuardianPattern.size
        #expect(grid[0] == 1)                         // corner
        #expect(grid[(n / 2) * n + n / 2] == 0)       // cell centre
        #expect(grid[(n / 2) * n] == 1)               // left edge, mid height
        let lines = RAVEGuardianPattern.coverage(style: .lines, lineFraction: 0.1)
        #expect(lines[(n / 2) * n] == 0)              // no vertical lines
        #expect(lines[n / 2] == 1)                    // horizontal edge
        let solid = RAVEGuardianPattern.coverage(style: .solid, lineFraction: 0.1)
        #expect(solid.min()! >= 0.45)
    }
}

@Suite struct RAVEGuardianSettingsTests {
    @Test func defaultsAreOnAndDecodeFromAnOlderBlob() throws {
        #expect(RAVEGuardianSettings().isEnabled)
        let old = #"{"visibility":"always","warningDistance":0.7}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RAVEGuardianSettings.self, from: old)
        #expect(s.isEnabled)
        #expect(s.visibility == .always)
        #expect(s.warningDistance == 0.7)
        #expect(s.appearance == RAVEGuardianSettings.Appearance())
        let roundTrip = try JSONDecoder().decode(RAVEGuardianSettings.self, from: JSONEncoder().encode(s))
        #expect(roundTrip == s)
    }

    @Test func sanitizedClampsOutOfRangeValues() {
        var s = RAVEGuardianSettings()
        s.warningDistance = -1
        s.appearance.spacing = 0
        s.appearance.color.red = 3
        let c = s.sanitized()
        #expect(c.warningDistance == RAVEGuardianSettings.warningDistanceRange.lowerBound)
        #expect(c.appearance.spacing == RAVEGuardianSettings.Appearance.spacingRange.lowerBound)
        #expect(c.appearance.color.red == 1)
    }

    @MainActor @Test func storePersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "RAVEGuardianTests-\(UUID())")!
        let a = RAVEGuardianSettingsStore(defaults: defaults, key: "g")
        a.settings.isEnabled = false
        a.settings.appearance.style = .lines
        let b = RAVEGuardianSettingsStore(defaults: defaults, key: "g")
        #expect(!b.settings.isEnabled)
        #expect(b.settings.appearance.style == .lines)
    }
}
