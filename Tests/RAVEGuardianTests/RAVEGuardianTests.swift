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

        // The same spot reached with a fast accelerating swing: warned.
        var fast = RAVEGuardianMonitor()
        var peakAlert: Float = 0
        for i in 0..<30 {
            let elapsed = Float(i) / 90
            let x: Float = 0.4 + 0.5 * 12 * elapsed * elapsed
            frame = fast.update(probes: [.init(id: "hand", kind: .hand, position: [min(x, 1.1), 1.2, 0])],
                                time: Double(i) / 90, map: map, settings: settings)
            peakAlert = max(peakAlert, frame.peakAlert)
            if x >= 1.1 { break }
        }
        #expect(peakAlert > 0.9)
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
        var frame = m.update(probes: [.init(id: "h", kind: .hand, position: [1.3, 1.2, 0])],
                             time: t, map: map, settings: settings)
        #expect(frame.chunkOpacity.isEmpty)
        var peak: Float = 0
        // The swing is fast enough to cue about 0.17 s in, and the wall takes
        // a few riseTimes to light up after that: 0.3 s of swing in all.
        for i in 1...27 {
            t += 1.0 / 90
            let elapsed = Float(i) / 90
            let x = 1.3 + 0.5 * 6 * elapsed * elapsed
            frame = m.update(probes: [.init(id: "h", kind: .hand, position: [x, 1.2, 0])],
                             time: t, map: map, settings: settings)
            peak = max(peak, frame.chunkOpacity.values.max() ?? 0)
        }
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

    @Test func legacyContinuousModeDoesNotShowWallsAtRest() {
        let (map, _) = room()
        var s = settings
        s.visibility = .always
        var m = RAVEGuardianMonitor()
        var frame = RAVEGuardianFrame()
        for i in 0..<120 {
            frame = m.update(probes: [.init(id: "hand", kind: .hand, position: [1.95, 1.6, 0])],
                             time: Double(i) / 90, map: map, settings: s)
        }
        #expect(frame.peakAlert == 0)
        #expect(frame.chunkOpacity.isEmpty)
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

#if canImport(Metal)
import Metal

/// The Metal overlay's shader compiles and draws: a wall a metre ahead,
/// seen straight on, shows lines and clear cells in the grid style and a
/// fill everywhere in the solid one.
@Suite struct RAVEGuardianMetalTests {
    func render(style: RAVEGuardianSettings.Style) throws -> [UInt8]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let size = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var map = RAVEGuardianMap()
        map.replace(anchor: UUID(), with: RAVEGuardianDemoRoom.walls(center: .zero, width: 2, depth: 2))
        let renderer = RAVEGuardianMetalRenderer()
        var appearance = RAVEGuardianSettings.Appearance()
        appearance.style = style
        renderer.publish(map: map, opacity: Dictionary(uniqueKeysWithValues: map.chunks.keys.map { ($0, Float(1)) }),
                         appearance: appearance)
        // Eye at (0.125, 1.125, 0) looking down -z: the wall at z = -1 fills a 60° view.
        let f: Float = 1 / tan(Float.pi / 6), n: Float = 0.05, far: Float = 100
        let projection = simd_float4x4(columns: (SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0),
                                                 SIMD4(0, 0, far / (n - far), -1), SIMD4(0, 0, far * n / (n - far), 0)))
        var view = matrix_identity_float4x4
        view.columns.3 = SIMD4(-0.125, -1.125, 0, 1)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = texture
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clear.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        renderer.encode(commandBuffer: commandBuffer, targets: [
            .init(colorTexture: texture, viewport: MTLViewport(originX: 0, originY: 0, width: Double(size),
                                                               height: Double(size), znear: 0, zfar: 1),
                  viewProjection: projection * view)
        ])
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }   // alpha
    }

    @Test func gridDrawsLinesWithClearCellsAndSolidFills() throws {
        guard let grid = try render(style: .grid), let solid = try render(style: .solid) else { return }
        let size = 128
        // The middle of the frame: a cell centre at the eye's own x and height.
        let centre = grid[(size / 2) * size + size / 2]
        #expect(centre < 30)
        #expect((grid.max() ?? 0) > 180)                 // lines drawn at full opacity
        let lit = grid.filter { $0 > 128 }.count
        #expect(lit > size * size / 50 && lit < size * size / 2)
        #expect(solid.min()! > 100)                      // the wall fills the whole view
    }
}
#endif
