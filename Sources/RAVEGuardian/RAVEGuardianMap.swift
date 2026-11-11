/*
 RAVE Engine — the guardian's map: the room's barrier triangles (walls, doors,
 windows, and optionally furniture) from the reconstructed world mesh, cut
 into one-metre chunks per mesh anchor.

 A chunk is both the unit of query (a probe only tests triangles in chunks
 whose bounds come within reach) and the unit of drawing (each chunk is one
 entity whose opacity follows the probes near it, so only the stretch of wall
 you are about to hit lights up). Foundation and simd only, an
 isolation-free value type: a render loop or the main actor can own it.

 Triangles arrive in world space with a normal pointing into the room (the
 platform half orients it from the mesh's own vertex normals), which is what
 lets the drawn outline sit a little in front of the real wall instead of
 z-fighting an occlusion mesh at the same depth.
 */

import Foundation
import simd

/// What a barrier face is. Walls, doors and windows are the room's boundary;
/// obstacles are furniture and appliances, shown only when the settings say.
public enum RAVEGuardianSurface: UInt8, Sendable, Equatable {
    case wall
    case door
    case window
    case obstacle

    public var isBoundary: Bool { self != .obstacle }
}

public struct RAVEGuardianTriangle: Sendable, Equatable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    public var c: SIMD3<Float>
    /// Unit normal facing into the room.
    public var normal: SIMD3<Float>
    public var surface: RAVEGuardianSurface

    /// Builds the triangle and orients its normal toward `inward` (any vector
    /// pointing into the room, e.g. the mesh's averaged vertex normal). A
    /// degenerate triangle returns nil.
    public init?(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                 inward: SIMD3<Float>? = nil, surface: RAVEGuardianSurface) {
        let n = simd_cross(b - a, c - a)
        let length = simd_length(n)
        guard length > 1e-8 else { return nil }
        var unit = n / length
        if let inward, simd_dot(unit, inward) < 0 { unit = -unit }
        self.a = a; self.b = b; self.c = c
        self.normal = unit
        self.surface = surface
    }

    public var centroid: SIMD3<Float> { (a + b + c) / 3 }

    /// The point on this triangle closest to `p` (Ericson, Real-Time
    /// Collision Detection 5.1.5).
    public func closestPoint(to p: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            return a + ab * (d1 / (d1 - d3))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            return a + ac * (d2 / (d2 - d6))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
        }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }
}

/// An axis-aligned box.
public struct RAVEGuardianBounds: Sendable, Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) { self.min = min; self.max = max }

    public init?(_ triangles: [RAVEGuardianTriangle]) {
        guard let first = triangles.first else { return nil }
        var lo = simd_min(simd_min(first.a, first.b), first.c)
        var hi = simd_max(simd_max(first.a, first.b), first.c)
        for t in triangles.dropFirst() {
            lo = simd_min(lo, simd_min(simd_min(t.a, t.b), t.c))
            hi = simd_max(hi, simd_max(simd_max(t.a, t.b), t.c))
        }
        self.min = lo; self.max = hi
    }

    /// Distance from `p` to the box, zero inside it.
    public func distance(to p: SIMD3<Float>) -> Float {
        let d = simd_max(simd_max(min - p, p - max), .zero)
        return simd_length(d)
    }

    public var center: SIMD3<Float> { (min + max) / 2 }
}

public struct RAVEGuardianChunkID: Hashable, Sendable {
    public var anchor: UUID
    public var cell: SIMD3<Int32>
    public var isObstacle: Bool
}

public struct RAVEGuardianChunk: Sendable, Equatable {
    public var id: RAVEGuardianChunkID
    public var triangles: [RAVEGuardianTriangle]
    public var bounds: RAVEGuardianBounds
}

/// The nearest barrier to a point.
public struct RAVEGuardianHit: Sendable, Equatable {
    public var distance: Float
    public var point: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var chunk: RAVEGuardianChunkID
}

public struct RAVEGuardianMap: Sendable {
    /// Chunk edge, metres. A metre keeps a typical room wall to a handful of
    /// chunks (few entities to fade) while still lighting only the stretch
    /// near a hand.
    public static let cellSize: Float = 1.0

    public private(set) var chunks: [RAVEGuardianChunkID: RAVEGuardianChunk] = [:]
    private var anchorChunks: [UUID: [RAVEGuardianChunkID]] = [:]
    /// Bumped on every change, so a renderer can tell which chunks to rebuild.
    public private(set) var revision: Int = 0
    /// Per chunk, the revision it last changed at.
    public private(set) var chunkRevisions: [RAVEGuardianChunkID: Int] = [:]

    public init() {}

    public var isEmpty: Bool { chunks.isEmpty }
    public var triangleCount: Int { chunks.values.reduce(0) { $0 + $1.triangles.count } }

    /// Replace everything one mesh anchor contributed.
    public mutating func replace(anchor: UUID, with triangles: [RAVEGuardianTriangle]) {
        var buckets: [RAVEGuardianChunkID: [RAVEGuardianTriangle]] = [:]
        for t in triangles {
            let c = t.centroid / Self.cellSize
            let cell = SIMD3<Int32>(Int32(c.x.rounded(.down)), Int32(c.y.rounded(.down)), Int32(c.z.rounded(.down)))
            let id = RAVEGuardianChunkID(anchor: anchor, cell: cell, isObstacle: t.surface == .obstacle)
            buckets[id, default: []].append(t)
        }
        revision += 1
        let old = Set(anchorChunks[anchor] ?? [])
        for id in old where buckets[id] == nil {
            chunks[id] = nil
            chunkRevisions[id] = nil
        }
        for (id, tris) in buckets {
            guard let bounds = RAVEGuardianBounds(tris) else { continue }
            let chunk = RAVEGuardianChunk(id: id, triangles: tris, bounds: bounds)
            if chunks[id] != chunk {
                chunks[id] = chunk
                chunkRevisions[id] = revision
            }
        }
        anchorChunks[anchor] = buckets.isEmpty ? nil : Array(buckets.keys)
    }

    public mutating func remove(anchor: UUID) {
        guard let ids = anchorChunks.removeValue(forKey: anchor) else { return }
        revision += 1
        for id in ids {
            chunks[id] = nil
            chunkRevisions[id] = nil
        }
    }

    public mutating func removeAll() {
        guard !chunks.isEmpty || !anchorChunks.isEmpty else { return }
        chunks.removeAll()
        anchorChunks.removeAll()
        chunkRevisions.removeAll()
        revision += 1
    }

    /// The nearest barrier triangle within `maxDistance` of `p`, or nil.
    /// Obstacles count only when `includeObstacles`.
    public func nearest(to p: SIMD3<Float>, within maxDistance: Float,
                        includeObstacles: Bool) -> RAVEGuardianHit? {
        var best: RAVEGuardianHit?
        var bestDistance = maxDistance
        for chunk in chunks.values {
            if chunk.id.isObstacle && !includeObstacles { continue }
            guard chunk.bounds.distance(to: p) <= bestDistance else { continue }
            for t in chunk.triangles {
                let q = t.closestPoint(to: p)
                let d = simd_distance(p, q)
                if d <= bestDistance {
                    bestDistance = d
                    best = RAVEGuardianHit(distance: d, point: q, normal: t.normal, chunk: chunk.id)
                }
            }
        }
        return best
    }
}

/// Barrier selection by face class and orientation, shared by every platform
/// adapter so the rules live once.
public enum RAVEGuardianFaceFilter {
    /// A boundary face must stand within this of vertical (|n.y| below it):
    /// visionOS labels a little of the floor/ceiling seam `.wall`, and a
    /// horizontal "wall" face would light up under your feet.
    public static let maxBoundaryNormalY: Float = 0.7
    /// Obstacle faces below this height (metres above the floor estimate)
    /// are ignored: a rug edge or a skirting board is not something to warn
    /// a swinging hand about.
    public static let minObstacleHeight: Float = 0.15

    public static func accepts(_ triangle: RAVEGuardianTriangle, floorY: Float?) -> Bool {
        if triangle.surface.isBoundary {
            return abs(triangle.normal.y) < maxBoundaryNormalY
        }
        if let floorY {
            let top = max(triangle.a.y, triangle.b.y, triangle.c.y)
            return top - floorY >= minObstacleHeight
        }
        return true
    }
}

/// A stand-in room: four walls of a box, tessellated like a scene mesh
/// (25 cm cells), normals inward. For the simulator, which has no scene
/// reconstruction, for debug endpoints and for tests.
public enum RAVEGuardianDemoRoom {
    public static func walls(center: SIMD3<Float>, width: Float, depth: Float,
                             height: Float = 2.5, floorY: Float = 0,
                             cell: Float = 0.25) -> [RAVEGuardianTriangle] {
        var tris: [RAVEGuardianTriangle] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ d: SIMD3<Float>, inward: SIMD3<Float>) {
            let u = b - a, v = d - a
            let nu = max(1, Int((simd_length(u) / cell).rounded()))
            let nv = max(1, Int((simd_length(v) / cell).rounded()))
            for i in 0..<nu {
                for j in 0..<nv {
                    func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
                        a + u * (Float(i) / Float(nu)) + v * (Float(j) / Float(nv))
                    }
                    if let t = RAVEGuardianTriangle(p(i, j), p(i + 1, j), p(i + 1, j + 1), inward: inward, surface: .wall) { tris.append(t) }
                    if let t = RAVEGuardianTriangle(p(i, j), p(i + 1, j + 1), p(i, j + 1), inward: inward, surface: .wall) { tris.append(t) }
                }
            }
        }
        let x0 = center.x - width / 2, x1 = center.x + width / 2
        let z0 = center.z - depth / 2, z1 = center.z + depth / 2
        let up = SIMD3<Float>(0, height, 0)
        let y = floorY
        quad([x0, y, z0], [x1, y, z0], [x0, y, z0] + up, inward: [0, 0, 1])
        quad([x0, y, z1], [x1, y, z1], [x0, y, z1] + up, inward: [0, 0, -1])
        quad([x0, y, z0], [x0, y, z1], [x0, y, z0] + up, inward: [1, 0, 0])
        quad([x1, y, z0], [x1, y, z1], [x1, y, z0] + up, inward: [-1, 0, 0])
        return tris
    }
}
