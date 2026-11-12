/*
 RAVE Engine — draw walls as locally fitted planes instead of tracing every
 noisy mesh triangle. Boundary triangles with matching normals and offsets
 share one fitted plane, so their grid lines remain straight across the wall
 patch. Obstacles keep their reconstructed shape for the hologram pass.
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
        struct PlaneGroup {
            var normalSum: SIMD3<Float>
            var weightedCentroid: SIMD3<Float>
            var weight: Float
            var triangleIndices: [Int]

            var normal: SIMD3<Float> { simd_normalize(normalSum) }
            var centroid: SIMD3<Float> { weightedCentroid / weight }
        }

        var planes: [PlaneGroup] = []
        let parallelDot = cos(Float.pi / 6) // 30 degrees of reconstructed normal noise
        let planeTolerance: Float = 0.3
        for (index, triangle) in triangles.enumerated() where triangle.surface.isBoundary {
            let h = SIMD3<Float>(triangle.normal.x, 0, triangle.normal.z)
            guard simd_length(h) > 0.3 else { continue }
            let normal = simd_normalize(h)
            let area = simd_length(simd_cross(triangle.b - triangle.a,
                                              triangle.c - triangle.a)) * 0.5
            guard area > 1e-6 else { continue }
            let centroid = triangle.centroid
            if let group = planes.indices.first(where: {
                let plane = planes[$0]
                return simd_dot(plane.normal, normal) >= parallelDot
                    && abs(simd_dot(plane.normal, centroid - plane.centroid)) <= planeTolerance
            }) {
                planes[group].normalSum += normal * area
                planes[group].weightedCentroid += centroid * area
                planes[group].weight += area
                planes[group].triangleIndices.append(index)
            } else {
                planes.append(PlaneGroup(normalSum: normal * area,
                                         weightedCentroid: centroid * area,
                                         weight: area, triangleIndices: [index]))
            }
        }

        for plane in planes {
            let normal = plane.normal
            let offset = simd_dot(normal, plane.centroid)
            // Tangent along the wall: up × normal. Coordinates are absolute
            // world metres, so separate mesh chunks keep the same grid phase.
            let tangent = SIMD3<Float>(normal.z, 0, -normal.x)
            for index in plane.triangleIndices {
                let t = triangles[index]
                let flattened = [t.a, t.b, t.c].map { point in
                    point - normal * (simd_dot(normal, point) - offset)
                }
                append(flattened, normal: normal, spacing: s) { point in
                    SIMD2(simd_dot(point, tangent), point.y) / s
                }
            }
        }

        for triangle in triangles where !triangle.surface.isBoundary {
            let normal = triangle.normal
            let horizontal = SIMD3<Float>(normal.x, 0, normal.z)
            if simd_length(horizontal) > 0.3 {
                let h = simd_normalize(horizontal)
                let tangent = SIMD3<Float>(h.z, 0, -h.x)
                append([triangle.a, triangle.b, triangle.c], normal: normal, spacing: s) { point in
                    SIMD2(simd_dot(point, tangent), point.y) / s
                }
            } else {
                append([triangle.a, triangle.b, triangle.c], normal: normal, spacing: s) { point in
                    SIMD2(point.x, point.z) / s
                }
            }
        }
    }

    private mutating func append(_ points: [SIMD3<Float>], normal: SIMD3<Float>,
                                 spacing: Float, project: (SIMD3<Float>) -> SIMD2<Float>) {
        let base = UInt32(positions.count)
        for point in points {
            positions.append(point + normal * Self.surfaceOffset)
            normals.append(normal)
            uvs.append(project(point))
        }
        indices.append(contentsOf: [base, base + 1, base + 2])
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
