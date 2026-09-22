import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import simd
@testable import RAVEHolo

/// The atlas has to hold a readable distance field for every HUD character,
/// layout has to put text where the alignment says, and the renderer has to
/// compile its runtime shader source — the one part no other test reaches.
@Suite struct RAVEHoloTests {
    static let font = RAVEHoloFont()

    @Test func everyDefaultCharacterHasAGlyph() {
        for c in RAVEHoloFont.defaultCharacters {
            #expect(Self.font.glyphs[c] != nil, "missing \(c)")
        }
        #expect(Self.font.capHeight > 0.5 && Self.font.capHeight < 0.9)
    }

    @Test func glyphRectanglesFitTheAtlas() {
        for (c, g) in Self.font.glyphs where g.size.x > 0 {
            #expect(g.uv.x >= 0 && g.uv.z <= 1 && g.uv.y >= 0 && g.uv.w <= 1, "\(c) outside the atlas")
            #expect(g.uv.z > g.uv.x && g.uv.w > g.uv.y)
        }
    }

    /// The bar of an "I" is inside (above 0.5) and the padding is outside.
    @Test func distanceFieldIsSignedAroundTheOutline() throws {
        let font = Self.font
        let g = try #require(font.glyphs["I"])
        let x0 = Int(g.uv.x * Float(font.width)), x1 = Int(g.uv.z * Float(font.width))
        let y0 = Int(g.uv.y * Float(font.height)), y1 = Int(g.uv.w * Float(font.height))
        let centre = font.pixels[((y0 + y1) / 2) * font.width + (x0 + x1) / 2]
        let corner = font.pixels[(y0 + 1) * font.width + x0 + 1]
        #expect(centre > 160)
        #expect(corner < 64)
    }

    @Test func distanceFieldOfASquareMeasuresFromItsEdge() {
        // 20×20 with a filled 10×10 middle: the centre is 5 px inside.
        var coverage = [UInt8](repeating: 0, count: 400)
        for y in 5..<15 { for x in 5..<15 { coverage[y * 20 + x] = 255 } }
        let field = RAVEHoloFont.signedDistanceField(coverage: coverage, width: 20, height: 20, spread: 8)
        let centre = Float(field[10 * 20 + 10]) / 255
        let outside = Float(field[0]) / 255
        #expect(abs(centre - (0.5 + 0.5 * 4.5 / 8)) < 0.02)
        #expect(outside < 0.1)
    }

    @Test func textAlignmentAnchorsTheRun() {
        var panel = RAVEHoloPanel(transform: matrix_identity_float4x4)
        let width = panel.text("100", font: Self.font, x: 0, y: 0, capHeight: 0.02,
                               alignment: .trailing, color: SIMD4(1, 1, 1, 1))
        #expect(width > 0.02 && width < 0.06)
        let right = panel.quads.map { $0.rect.x + $0.rect.z }.max() ?? 0
        // The last glyph's quad carries its spread padding past the pen.
        #expect(abs(right) < 0.01)
        #expect(panel.quads.allSatisfy { $0.kind == .glyph })
    }

    @Test func facingTransformLooksAtTheViewerUpright() {
        let m = RAVEHoloPanel.facing(position: SIMD3(0, 1, -1), viewer: SIMD3(0, 1.6, 0))
        let n = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let right = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        #expect(simd_dot(n, simd_normalize(SIMD3<Float>(0, 0.6, 1))) > 0.999)
        #expect(abs(right.y) < 1e-5)
    }

    @Test func rendererCompilesItsShaders() throws {
        guard #available(macOS 26.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let r = try RAVEHoloRenderer(device: device,
                                     configuration: .init(colorFormat: .rgba16Float, depthFormat: .depth32Float),
                                     font: Self.font)
        #expect(r.allocations.count == 4)
    }
}

/// Draws a representative panel offscreen through Metal 4 and checks light
/// lands where the text is. `RAVEHOLO_SNAPSHOT=/path.png` also writes the
/// frame out, for looking at the style without a headset.
@Suite struct RAVEHoloRenderTests {
    @Test func rendersAPanel() throws {
        guard #available(macOS 26.0, *), let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeMTL4CommandQueue(), let commandBuffer = device.makeCommandBuffer(),
              let allocator = device.makeCommandAllocator() else { return }
        let size = 512
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size / 2, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size / 2, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .private
        let color = try #require(device.makeTexture(descriptor: cd))
        let depth = try #require(device.makeTexture(descriptor: dd))
        let holo = try RAVEHoloRenderer(device: device,
                                        configuration: .init(colorFormat: .rgba16Float, depthFormat: .depth32Float,
                                                             maxViewCount: 1, slots: 1),
                                        font: RAVEHoloTests.font)

        let amber = SIMD3<Float>(1.0, 0.56, 0.12)
        var panel = RAVEHoloPanel(transform: matrix_identity_float4x4)
        panel.fill(x: -0.04, y: -0.02, width: 0.08, height: 0.04, corner: 0.004, color: SIMD4(0.015, 0.01, 0.006, 0.42))
        panel.frame(x: -0.04, y: -0.02, width: 0.08, height: 0.04, corner: 0.004, line: 0.0006, color: SIMD4(amber, 0.85))
        panel.text("HEALTH", font: RAVEHoloTests.font, x: -0.035, y: 0.0105, capHeight: 0.0034, tracking: 0.0006, color: SIMD4(amber * 0.8, 0.9))
        panel.text("100", font: RAVEHoloTests.font, x: 0.035, y: 0.004, capHeight: 0.0105, alignment: .trailing, color: SIMD4(amber, 1))
        panel.bar(x: -0.035, y: 0.0, width: 0.05, height: 0.0028, fraction: 0.7, segments: 10, gap: 0.0007, color: SIMD4(amber, 0.95))
        panel.text("SUIT", font: RAVEHoloTests.font, x: -0.035, y: -0.0095, capHeight: 0.0034, tracking: 0.0006, color: SIMD4(amber * 0.8, 0.9))
        panel.text("45", font: RAVEHoloTests.font, x: 0.035, y: -0.016, capHeight: 0.0105, alignment: .trailing, color: SIMD4(amber, 1))
        panel.bar(x: -0.035, y: -0.02 + 0.0035, width: 0.05, height: 0.0028, fraction: 0.45, segments: 10, gap: 0.0007, color: SIMD4(amber, 0.95))
        var scene = RAVEHoloScene()
        scene.panels = [panel]

        // Orthographic, reverse-Z: the 8 × 4 cm panel fills the frame.
        var vp = matrix_identity_float4x4
        vp.columns.0.x = 2 / 0.084
        vp.columns.1.y = 2 / 0.042
        vp.columns.2.z = 0.5
        vp.columns.3.z = 0.5

        let rsd = MTLResidencySetDescriptor()
        let residency = try device.makeResidencySet(descriptor: rsd)
        residency.addAllocations(holo.allocations + [color, depth])
        residency.commit()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.useResidencySet(residency)
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        let enc = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(size), height: Double(size / 2), znear: 0, zfar: 1))
        holo.encode(scene, encoder: enc, viewProjections: [vp], slot: 0, time: 0)
        enc.endEncoding()
        commandBuffer.endCommandBuffer()
        let done = DispatchSemaphore(value: 0)
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { _ in done.signal() }
        queue.commit([commandBuffer], options: options)
        done.wait()

        let w = size, h = size / 2
        var halfs = [UInt16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes { raw in
            color.getBytes(raw.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let rgba = halfs.map { Float(Float16(bitPattern: $0)) }
        // Brightest red channel anywhere: the "100" glyphs are near 1.
        let peak = stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }.max() ?? 0
        #expect(peak > 0.6)

        if let path = ProcessInfo.processInfo.environment["RAVEHOLO_SNAPSHOT"] {
            var bytes = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) {
                for c in 0..<3 {
                    let linear = max(0, min(1, rgba[i * 4 + c]))
                    let srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
                    bytes[i * 4 + c] = UInt8(srgb * 255)
                }
            }
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            if let image = ctx?.makeImage(),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }
}
