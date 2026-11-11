/*
 RAVE Engine — the guardian drawn with Metal, for hosts with no RealityKit:
 a Compositor Services layer (Longwave's Shell A) or any Metal renderer that
 owns its own passes.

 Split by thread. The main actor decides what shows (`RAVEGuardianOverlay`
 runs the same map and monitor the RealityKit guardian does) and `publish`es
 a snapshot; the host's render thread calls `encode` once per frame with one
 target per eye view. Nothing here awaits or touches the main actor, so a
 render thread that cannot await anything can drive it (RAVEEngine's
 isolation rule); the snapshot sits behind a lock.

 The pattern is computed in the fragment shader from world-space wall
 coordinates (metres along the wall, height), so spacing, line width and style
 change without rebuilding geometry, and lines stay a constant width at any
 distance thanks to `fwidth` antialiasing. Drawn over whatever the host drew
 (no depth test, no depth write, premultiplied blending), for the same reason
 the RealityKit guardian draws over content: a game object nearer than the
 wall must not hide it. Pass loads, never clears.

 Shader source compiles at runtime (SwiftPM's CLI builds no `.metal`).
 */

#if canImport(Metal)

import Foundation
import Metal
import os
import simd

public final class RAVEGuardianMetalRenderer: @unchecked Sendable {

    /// One eye view to draw into.
    public struct Target {
        public var colorTexture: any MTLTexture
        public var colorSlice: Int
        public var viewport: MTLViewport
        public var rasterizationRateMap: (any MTLRasterizationRateMap)?
        /// Clip from world: projection × inverse(world-from-eye).
        public var viewProjection: simd_float4x4

        public init(colorTexture: any MTLTexture, colorSlice: Int = 0, viewport: MTLViewport,
                    rasterizationRateMap: (any MTLRasterizationRateMap)? = nil, viewProjection: simd_float4x4) {
            self.colorTexture = colorTexture
            self.colorSlice = colorSlice
            self.viewport = viewport
            self.rasterizationRateMap = rasterizationRateMap
            self.viewProjection = viewProjection
        }
    }

    private struct Published {
        var map = RAVEGuardianMap()
        var opacity: [RAVEGuardianChunkID: Float] = [:]
        var appearance = RAVEGuardianSettings.Appearance()
    }

    private struct ChunkBuffer {
        var revision: Int
        var buffer: any MTLBuffer
        var vertexCount: Int
    }

    private struct Uniforms {
        var viewProjection: simd_float4x4
        var color: SIMD4<Float>        // linear, alpha = opacity
        var spacing: Float
        var lineWidth: Float
        var style: Int32
        var pad: Float = 0
    }

    private let published = OSAllocatedUnfairLock(initialState: Published())
    // Render-thread state, touched only from `encode`.
    private var device: (any MTLDevice)?
    private var library: (any MTLLibrary)?
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]
    private var buffers: [RAVEGuardianChunkID: ChunkBuffer] = [:]
    private var failed = false

    public init() {}

    /// From the main actor: what to draw next frame.
    public func publish(map: RAVEGuardianMap, opacity: [RAVEGuardianChunkID: Float],
                        appearance: RAVEGuardianSettings.Appearance) {
        published.withLock {
            $0.map = map
            $0.opacity = opacity
            $0.appearance = appearance
        }
    }

    /// Nothing to draw (the guardian is off or the space is closing).
    public func clear() {
        published.withLock { $0.opacity = [:] }
    }

    /// Whether anything shows right now; a host can skip its pass setup otherwise.
    public var hasContent: Bool { published.withLock { !$0.opacity.isEmpty } }

    /// From the render thread: draws the visible chunks into each target, over
    /// what is already there. Encodes nothing when nothing shows.
    public func encode(commandBuffer: any MTLCommandBuffer, targets: [Target]) {
        let snapshot = published.withLock { $0 }
        guard !snapshot.opacity.isEmpty, !targets.isEmpty, !failed else { return }
        let device = commandBuffer.device
        if self.device !== device { reset(device) }

        // Geometry for the chunks that show, rebuilt when their mesh changed.
        var draws: [(buffer: ChunkBuffer, opacity: Float)] = []
        for (id, opacity) in snapshot.opacity where opacity > 0.002 {
            guard let chunk = snapshot.map.chunks[id], let revision = snapshot.map.chunkRevisions[id] else { continue }
            if let cached = buffers[id], cached.revision == revision {
                draws.append((cached, opacity))
                continue
            }
            guard let built = Self.makeBuffer(device: device, chunk: chunk, revision: revision) else { continue }
            buffers[id] = built
            draws.append((built, opacity))
        }
        // Forget buffers for chunks that are gone.
        if buffers.count > snapshot.map.chunks.count {
            buffers = buffers.filter { snapshot.map.chunks[$0.key] != nil }
        }
        guard !draws.isEmpty else { return }

        let a = snapshot.appearance
        let base = SIMD3(Self.linear(a.color.red), Self.linear(a.color.green), Self.linear(a.color.blue))
        let style: Int32 = switch a.style { case .grid: 0; case .lines: 1; case .solid: 2 }

        for target in targets {
            guard let pipeline = pipeline(for: target.colorTexture.pixelFormat) else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.colorTexture
            pass.colorAttachments[0].slice = target.colorSlice
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            pass.rasterizationRateMap = target.rasterizationRateMap
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "RAVEGuardian"
            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setViewport(target.viewport)
            for draw in draws {
                var uniforms = Uniforms(viewProjection: target.viewProjection,
                                        color: SIMD4(base, draw.opacity),
                                        spacing: a.spacing, lineWidth: a.lineWidth, style: style)
                encoder.setVertexBuffer(draw.buffer.buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.buffer.vertexCount)
            }
            encoder.endEncoding()
        }
    }

    // MARK: Resources

    private func reset(_ device: any MTLDevice) {
        self.device = device
        pipelines.removeAll()
        buffers.removeAll()
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            failed = true
            library = nil
        }
    }

    private func pipeline(for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let p = pipelines[format] { return p }
        guard let device, let library,
              let vertex = library.makeFunction(name: "raveGuardianVertex"),
              let fragment = library.makeFunction(name: "raveGuardianFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.label = "RAVEGuardian"
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        d.colorAttachments[0].pixelFormat = format
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipelines[format] = p
        return p
    }

    /// Five floats per vertex: world position (pushed into the room) and wall
    /// coordinates in metres.
    private static func makeBuffer(device: any MTLDevice, chunk: RAVEGuardianChunk, revision: Int) -> ChunkBuffer? {
        let layout = RAVEGuardianMeshLayout(triangles: chunk.triangles, spacing: 1)
        guard !layout.positions.isEmpty else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(layout.positions.count * 5)
        for i in layout.positions.indices {
            let p = layout.positions[i], uv = layout.uvs[i]
            floats += [p.x, p.y, p.z, uv.x, uv.y]
        }
        guard let buffer = device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride,
                                             options: .storageModeShared) else { return nil }
        buffer.label = "RAVEGuardian chunk"
        return ChunkBuffer(revision: revision, buffer: buffer, vertexCount: layout.positions.count)
    }

    static func linear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProjection;
        float4 color;
        float spacing;
        float lineWidth;
        int style;
        float pad;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 wall;
    };

    vertex VertexOut raveGuardianVertex(uint vid [[vertex_id]],
                                        const device float *vertices [[buffer(0)]],
                                        constant Uniforms &u [[buffer(1)]]) {
        const device float *v = vertices + vid * 5;
        VertexOut out;
        out.position = u.viewProjection * float4(v[0], v[1], v[2], 1.0);
        out.wall = float2(v[3], v[4]);
        return out;
    }

    fragment float4 raveGuardianFragment(VertexOut in [[stage_in]],
                                         constant Uniforms &u [[buffer(1)]]) {
        float2 cell = in.wall / u.spacing;
        // Distance to the nearest grid line, in cells, and its screen footprint.
        float2 d = abs(fract(cell + 0.5) - 0.5);
        float2 w = max(fwidth(cell), float2(1e-4));
        float half_width = 0.5 * u.lineWidth / u.spacing;
        float2 line = 1.0 - smoothstep(half_width - w, half_width + w, d);
        float coverage;
        if (u.style == 0) {
            coverage = max(line.x, line.y);
        } else if (u.style == 1) {
            coverage = line.y;
        } else {
            coverage = max(0.45, max(line.x, line.y));
        }
        float a = coverage * u.color.a;
        return float4(u.color.rgb * a, a);
    }
    """
}

#endif
