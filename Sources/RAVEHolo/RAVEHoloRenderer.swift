import Metal
import simd

/// Draws a `RAVEHoloScene` into a render pass the host owns.
///
/// The host keeps everything that is specific to how it presents — the pass
/// descriptor, targets, rasterisation rate map, viewports and vertex
/// amplification — and hands this an encoder that is already configured.
/// This keeps the pipeline, the per-slot buffers and the glyph atlas. Every
/// buffer and the atlas are in `allocations`; add them to the residency set
/// the command buffer uses (Metal 4 does no automatic residency).
///
/// Metal 4 only: the package's macOS floor stays where the rest of the
/// Engine needs it, so availability is marked here rather than raised.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public final class RAVEHoloRenderer {
    public struct Configuration: Sendable {
        public var colorFormat: MTLPixelFormat
        public var depthFormat: MTLPixelFormat
        public var rasterSampleCount: Int
        public var maxViewCount: Int
        /// Frames in flight: one buffer set per slot.
        public var slots: Int
        /// Depth test against the pass (reverse-Z) — nearer content hides the
        /// holograms. Writing depth matters where the compositor reprojects
        /// by the pass's depth.
        public var depthTest: Bool
        public var depthWrite: Bool
        public var maxPanels: Int
        public var maxQuads: Int

        public init(colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, rasterSampleCount: Int = 1,
                    maxViewCount: Int = 2, slots: Int = 3, depthTest: Bool = true, depthWrite: Bool = false,
                    maxPanels: Int = 32, maxQuads: Int = 4096) {
            self.colorFormat = colorFormat; self.depthFormat = depthFormat
            self.rasterSampleCount = rasterSampleCount; self.maxViewCount = maxViewCount
            self.slots = slots; self.depthTest = depthTest; self.depthWrite = depthWrite
            self.maxPanels = maxPanels; self.maxQuads = maxQuads
        }
    }

    /// Look knobs, read every encode.
    public struct Style: Sendable {
        /// Scanline pitch across the panel (m) and how much they darken (0…1).
        public var scanlinePitch: Float = 0.0014
        public var scanlineDepth: Float = 0.22
        /// Brightness dip of the flicker (0…1).
        public var flickerDepth: Float = 0.06
        public init() {}
    }

    public enum Error: Swift.Error { case buffer, function(String), texture }

    public let configuration: Configuration
    public let font: RAVEHoloFont
    public var style = Style()

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let arguments: MTL4ArgumentTable
    private let atlas: MTLTexture
    private let frameBuffer: MTLBuffer
    private let panelBuffer: MTLBuffer
    private let quadBuffer: MTLBuffer

    private static let frameStride = 256
    private static let panelStride = MemoryLayout<PanelGPU>.stride
    private static let quadStride = MemoryLayout<QuadGPU>.stride

    public init(device: MTLDevice, configuration: Configuration, font: RAVEHoloFont) throws {
        self.configuration = configuration
        self.font = font
        let library = try device.makeLibrary(source: RAVEHoloShaders.source, options: nil)
        guard let vertex = library.makeFunction(name: "holoVertex") else { throw Error.function("holoVertex") }
        guard let fragment = library.makeFunction(name: "holoFragment") else { throw Error.function("holoFragment") }

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "RAVEHolo"
        pd.vertexFunction = vertex
        pd.fragmentFunction = fragment
        pd.colorAttachments[0].pixelFormat = configuration.colorFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pd.depthAttachmentPixelFormat = configuration.depthFormat
        pd.rasterSampleCount = configuration.rasterSampleCount
        pd.maxVertexAmplificationCount = configuration.maxViewCount
        pipeline = try device.makeRenderPipelineState(descriptor: pd)

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = configuration.depthTest ? .greaterEqual : .always
        dd.isDepthWriteEnabled = configuration.depthWrite
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { throw Error.buffer }
        depthState = ds

        let at = MTL4ArgumentTableDescriptor()
        at.maxBufferBindCount = 3
        at.maxTextureBindCount = 1
        arguments = try device.makeArgumentTable(descriptor: at)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: font.width,
                                                          height: font.height, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: td) else { throw Error.texture }
        font.pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, font.width, font.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: font.width)
        }
        texture.label = "RAVEHolo.atlas"
        atlas = texture

        let slots = configuration.slots
        guard let f = device.makeBuffer(length: Self.frameStride * slots, options: .storageModeShared),
              let p = device.makeBuffer(length: Self.panelStride * configuration.maxPanels * slots, options: .storageModeShared),
              let q = device.makeBuffer(length: Self.quadStride * configuration.maxQuads * slots, options: .storageModeShared)
        else { throw Error.buffer }
        f.label = "RAVEHolo.frame"; p.label = "RAVEHolo.panels"; q.label = "RAVEHolo.quads"
        frameBuffer = f; panelBuffer = p; quadBuffer = q
    }

    /// Everything the draw touches, for the command buffer's residency set.
    public var allocations: [MTLAllocation] { [atlas, frameBuffer, panelBuffer, quadBuffer] }

    /// Encode `scene` into a configured encoder. `viewProjections` are
    /// world → clip per view (reverse-Z), indexed by amplification id.
    /// Panels or quads past the configured capacity are dropped.
    public func encode(_ scene: RAVEHoloScene, encoder: MTL4RenderCommandEncoder,
                       viewProjections: [simd_float4x4], slot: Int, time: Float) {
        guard !scene.panels.isEmpty, let first = viewProjections.first else { return }
        let slot = slot % configuration.slots

        let frame = (frameBuffer.contents() + slot * Self.frameStride).bindMemory(to: FrameGPU.self, capacity: 1)
        frame.pointee = FrameGPU(viewProjection: (first, viewProjections.count > 1 ? viewProjections[1] : first),
                                 params: SIMD4(time, style.scanlinePitch, style.scanlineDepth, style.flickerDepth))

        let panelBase = slot * configuration.maxPanels
        let quadBase = slot * configuration.maxQuads
        let panels = (panelBuffer.contents() + panelBase * Self.panelStride)
            .bindMemory(to: PanelGPU.self, capacity: configuration.maxPanels)
        let quads = (quadBuffer.contents() + quadBase * Self.quadStride)
            .bindMemory(to: QuadGPU.self, capacity: configuration.maxQuads)
        var quadCount = 0
        for (pi, panel) in scene.panels.prefix(configuration.maxPanels).enumerated() {
            panels[pi] = PanelGPU(model: panel.transform, params: SIMD4(panel.opacity, panel.seed, 0, 0))
            for q in panel.quads {
                guard quadCount < configuration.maxQuads else { break }
                quads[quadCount] = QuadGPU(rect: q.rect, params: q.params, color: q.color,
                                           panel: UInt32(pi), kind: q.kind.rawValue, pad0: 0, pad1: 0)
                quadCount += 1
            }
        }
        guard quadCount > 0 else { return }

        encoder.pushDebugGroup("RAVEHolo")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(arguments, stages: [.vertex, .fragment])
        arguments.setAddress(frameBuffer.gpuAddress + UInt64(slot * Self.frameStride), index: 0)
        arguments.setAddress(panelBuffer.gpuAddress + UInt64(panelBase * Self.panelStride), index: 1)
        arguments.setAddress(quadBuffer.gpuAddress + UInt64(quadBase * Self.quadStride), index: 2)
        arguments.setTexture(atlas.gpuResourceID, index: 0)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quadCount)
        encoder.popDebugGroup()
    }

    // Mirrors HoloFrame / HoloPanelGPU / HoloQuadGPU in the shader source.
    private struct FrameGPU {
        var viewProjection: (simd_float4x4, simd_float4x4)
        var params: SIMD4<Float>
    }
    private struct PanelGPU {
        var model: simd_float4x4
        var params: SIMD4<Float>
    }
    private struct QuadGPU {
        var rect: SIMD4<Float>
        var params: SIMD4<Float>
        var color: SIMD4<Float>
        var panel: UInt32
        var kind: UInt32
        var pad0: UInt32
        var pad1: UInt32
    }
}
