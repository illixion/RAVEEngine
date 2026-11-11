/*
 RAVE Engine — a chunk's triangles laid out for drawing: un-shared vertices
 pushed a little into the room, with texture coordinates projected from world
 space so the grid lies flat and continuous along each real wall.

 The projection: a near-vertical face is unrolled along the horizontal
 tangent of its normal (u) and world height (v); a near-horizontal face
 (a table top, with furniture on) uses world x/z. Coplanar faces share a
 tangent, so a flat wall's grid lines run straight across all its triangles.
 The coordinates are in units of grid cells (metres / spacing) and the
 texture repeats, so the line spacing is set here, not in the texture.
 */

import Foundation
import simd

public struct RAVEGuardianMeshLayout: Sendable, Equatable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []

    /// How far the outline sits in front of the real surface, metres. Enough
    /// to win the depth test against an occlusion mesh at the wall itself
    /// (spatial-ai-character draws one), small enough to read as "on" it.
    public static let surfaceOffset: Float = 0.015

    public init() {}

    public init(triangles: [RAVEGuardianTriangle], spacing: Float) {
        let s = max(spacing, 0.01)
        positions.reserveCapacity(triangles.count * 3)
        uvs.reserveCapacity(triangles.count * 3)
        normals.reserveCapacity(triangles.count * 3)
        indices.reserveCapacity(triangles.count * 3)
        for t in triangles {
            let n = t.normal
            let project: (SIMD3<Float>) -> SIMD2<Float>
            let horizontal = SIMD3<Float>(n.x, 0, n.z)
            if simd_length(horizontal) > 0.3 {
                let h = simd_normalize(horizontal)
                // Tangent along the wall: up × normal.
                let tangent = SIMD3<Float>(h.z, 0, -h.x)
                project = { p in SIMD2(simd_dot(p, tangent), p.y) / s }
            } else {
                project = { p in SIMD2(p.x, p.z) / s }
            }
            let base = UInt32(positions.count)
            for p in [t.a, t.b, t.c] {
                positions.append(p + n * Self.surfaceOffset)
                normals.append(n)
                uvs.append(project(p))
            }
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
    }
}

/// The repeating tile the outline is drawn with: white on transparent, tinted
/// by the material. Pixels are premultiplied RGBA8, `size` × `size`.
public enum RAVEGuardianPattern {
    public static let size = 128

    /// Coverage (0...1) of each pixel of the tile for a style. `lineFraction`
    /// is the line width as a fraction of one grid cell.
    public static func coverage(style: RAVEGuardianSettings.Style, lineFraction: Float) -> [Float] {
        let n = size
        let half = max(lineFraction, 1 / Float(n)) * Float(n) / 2
        var out = [Float](repeating: 0, count: n * n)
        // Distance in pixels from the nearest cell edge, with a one-pixel
        // soft edge so the lines don't shimmer at distance.
        func line(_ i: Int) -> Float {
            let c = Float(i) + 0.5
            let d = min(c, Float(n) - c)
            return max(0, min(1, half - d + 0.5))
        }
        for y in 0..<n {
            for x in 0..<n {
                let v: Float
                switch style {
                case .grid: v = max(line(x), line(y))
                case .lines: v = line(y)
                case .solid: v = max(0.45, max(line(x), line(y)))
                }
                out[y * n + x] = v
            }
        }
        return out
    }

    public static func rgba(style: RAVEGuardianSettings.Style, lineFraction: Float) -> [UInt8] {
        let cov = coverage(style: style, lineFraction: lineFraction)
        var bytes = [UInt8](repeating: 0, count: cov.count * 4)
        for (i, c) in cov.enumerated() {
            let v = UInt8((c * 255).rounded())
            bytes[i * 4 + 0] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = v
        }
        return bytes
    }
}
