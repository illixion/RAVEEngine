import CoreGraphics
import Foundation
import ImageIO
import Metal
import RAVEInput
import Testing
import simd
@testable import RAVEHolo

/// Targets, widgets, layout and the palm anchor — the interactive half of
/// RAVEHolo. The CPU paths are what a Mac host and the debug servers press
/// through, so they carry the weight; the GPU test pins that the tracking
/// pass writes the render value where the control is and nowhere else.
@Suite struct RAVEHoloInteractionTests {
    static let font = RAVEHoloTests.font

    @Test func roundedTargetExcludesItsCorners() {
        let t = RAVEHoloTarget(id: 7, rect: SIMD4(0, 0, 0.04, 0.02), corner: 0.008)
        #expect(t.contains(SIMD2(0.02, 0.01)))
        #expect(t.contains(SIMD2(0.0005, 0.01)))        // middle of the left edge
        #expect(!t.contains(SIMD2(0.0005, 0.0005)))     // the rounded-off corner
        #expect(!t.contains(SIMD2(0.041, 0.01)))
    }

    @Test func buttonDrawsAndRegistersOneTarget() {
        var p = RAVEHoloPanel(transform: matrix_identity_float4x4)
        p.button(3, label: "lamp", font: Self.font, x: -0.02, y: -0.01, width: 0.04, height: 0.02)
        #expect(p.targets.count == 1)
        #expect(p.targets[0].id == 3)
        #expect(p.targets[0].rect == SIMD4(-0.02, -0.01, 0.04, 0.02))
        #expect(p.quads.contains { $0.kind == .glyph })
        #expect(p.target(at: .zero)?.id == 3)
    }

    @Test func rayPicksTheButtonUnderIt() {
        var p = RAVEHoloPanel(transform: RAVEHoloPanel.facing(position: SIMD3(0, 1.2, -0.4), viewer: SIMD3(0, 1.6, 0)))
        p.button(1, label: "A", font: Self.font, x: -0.045, y: -0.01, width: 0.04, height: 0.02)
        p.button(2, label: "B", font: Self.font, x: 0.005, y: -0.01, width: 0.04, height: 0.02)
        var scene = RAVEHoloScene()
        scene.panels = [p]
        let eye = SIMD3<Float>(0, 1.6, 0)
        func aim(_ local: SIMD2<Float>) -> RAVEHoloHit? {
            let w = p.transform * SIMD4(local.x, local.y, 0, 1)
            return scene.hit(origin: eye, direction: simd_normalize(SIMD3(w.x, w.y, w.z) - eye))
        }
        #expect(aim(SIMD2(-0.025, 0))?.id == 1)
        #expect(aim(SIMD2(0.025, 0))?.id == 2)
        #expect(aim(SIMD2(0, 0)) == nil)                // the gap between them
        #expect(aim(SIMD2(0.025, 0.03)) == nil)         // above both
        let hit = try? #require(aim(SIMD2(0.025, 0)))
        #expect(abs((hit?.distance ?? 0) - simd_length(SIMD3<Float>(0, 0.4, 0.4))) < 0.01)
        // Pointing away never hits.
        #expect(scene.hit(origin: eye, direction: SIMD3(0, 0, 1)) == nil)
    }

    @Test func nearerPanelWinsAndFadedPanelsAreNotSelectable() {
        func panel(z: Float, id: UInt64, opacity: Float = 1) -> RAVEHoloPanel {
            var p = RAVEHoloPanel(transform: RAVEHoloPanel.facing(position: SIMD3(0, 0, z), viewer: .zero),
                                  opacity: opacity)
            p.target(id, x: -0.05, y: -0.05, width: 0.1, height: 0.1)
            return p
        }
        var scene = RAVEHoloScene()
        scene.panels = [panel(z: -1, id: 1), panel(z: -0.5, id: 2)]
        #expect(scene.hit(origin: .zero, direction: SIMD3(0, 0, -1))?.id == 2)
        scene.panels[1].opacity = 0
        #expect(scene.hit(origin: .zero, direction: SIMD3(0, 0, -1))?.id == 1)
        scene.panels.append(panel(z: -0.2, id: 1))
        #expect(scene.targetIDs == [1, 2])   // the repeated 1 is registered once
    }

    @Test func interactionFlashFadesAndCounts() {
        let i = RAVEHoloInteraction(flashDuration: 0.2)
        #expect(i.flash(5, now: 10) == 0)
        i.recordPress(5, at: 10)
        i.recordPress(5, at: 10)
        #expect(i.flash(5, now: 10) == 1)
        #expect(abs(i.flash(5, now: 10.1) - 0.5) < 1e-4)
        #expect(i.flash(5, now: 10.3) == 0)
        #expect(i.pressCounts[5] == 2)
    }

    @Test func sparklineDrawsABarPerNonZeroValueAndWarnsAboveTheLimit() {
        var p = RAVEHoloPanel(transform: matrix_identity_float4x4)
        let theme = RAVEHoloTheme.amber
        p.sparkline([5, 0, 11, 30], maxValue: 22, x: 0, y: 0, width: 0.08, height: 0.01,
                    theme: theme, warnAbove: 11.1, guide: 11.1)
        // Background, three bars (the zero draws nothing), one guide.
        #expect(p.quads.count == 5)
        let bars = p.quads[1..<4]
        let heights: [Float] = bars.map { $0.rect.w }
        let wanted: [Float] = [0.01 * 5 / 22, 0.01 * 11 / 22, 0.01]   // 30 clips to the top
        #expect(zip(heights, wanted).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(bars.last?.color.x == theme.warning.x && bars.last?.color.y == theme.warning.y)
        #expect(bars.first?.color.y == theme.accent.y)
        #expect(abs(p.quads[4].rect.y - (0.01 * 11.1 / 22 - theme.line / 2)) < 1e-6)
    }

    @Test func layoutStacksItemsInsideTheCard() {
        let layout = RAVEHoloLayout(width: 0.09, items: [
            .title("Frame"),
            .row("FPS", "90"),
            .gauge("GPU", value: "7.1", fraction: 0.6),
            .sparkline([8, 9, 12], max: 22, guide: 11.1),
            .buttons([.init(1, "HUD", isOn: true), .init(2, "Aim"), .init(3, "Beam")]),
        ])
        let theme = layout.theme
        let h = layout.height(font: Self.font)
        let gauge: Float = theme.valueCap + theme.spacing + theme.gaugeHeight
        var expected: Float = theme.titleCap + theme.valueCap + gauge
        expected += 0.012 + theme.buttonHeight
        expected += theme.spacing * 4 + theme.padding * 2
        #expect(abs(h - expected) < 1e-6)

        let p = layout.panel(transform: matrix_identity_float4x4, font: Self.font)
        #expect(p.targets.map(\.id) == [1, 2, 3])
        // Every quad and target lies within the card.
        let eps: Float = 0.004   // glyph spread padding past the pen
        for q in p.quads {
            let x0: Float = q.rect.x, x1: Float = q.rect.x + q.rect.z
            let y0: Float = q.rect.y, y1: Float = q.rect.y + q.rect.w
            #expect(x0 >= -0.045 - eps && x1 <= 0.045 + eps)
            #expect(y0 >= -h / 2 - eps && y1 <= h / 2 + eps)
        }
        // Buttons split the inner width evenly, gap included, bottom row.
        let inner: Float = 0.09 - theme.padding * 2
        let w: Float = (inner - theme.spacing * 2) / 3
        for (i, t) in p.targets.enumerated() {
            let x: Float = -0.045 + theme.padding + Float(i) * (w + theme.spacing)
            let y: Float = -h / 2 + theme.padding
            #expect(abs(t.rect.z - w) < 1e-6)
            #expect(abs(t.rect.x - x) < 1e-6)
            #expect(abs(t.rect.y - y) < 1e-6)
        }
    }

    @Test func layoutFlashesPressedButtons() {
        let i = RAVEHoloInteraction()
        i.recordPress(2, at: 1)
        let layout = RAVEHoloLayout(items: [.buttons([.init(1, "A"), .init(2, "B")])])
        let p = layout.panel(transform: matrix_identity_float4x4, font: Self.font, interaction: i, now: 1)
        // Card fill, card frame, then per button: face, rim, glyph(s).
        let faces = p.quads.filter { $0.kind == .fill }.dropFirst()
        #expect(faces.count == 2)
        #expect(faces.last!.color.x > faces.first!.color.x + 0.3)
    }
}

/// The palm anchor, driven the way a host does: a palm pose and a head each
/// frame at 90 Hz.
@Suite struct RAVEHoloPalmAnchorTests {
    static let head = SIMD3<Float>(0, 1.6, 0)
    static let palm = SIMD3<Float>(0, 1.2, -0.35)

    /// A palm at `position` whose normal points at `toward`.
    static func pose(_ position: SIMD3<Float> = palm, toward: SIMD3<Float> = head) -> RAVEPalmPose {
        let n = simd_normalize(toward - position)
        let fingers = simd_normalize(simd_cross(n, SIMD3(1, 0, 0)))
        return RAVEPalmPose(position: position, palmNormalOut: n, fingersDirection: fingers)
    }

    /// Run `seconds` of frames, returning the anchor.
    static func run(_ anchor: inout RAVEHoloPalmAnchor, from t0: TimeInterval, seconds: TimeInterval,
                    pose: RAVEPalmPose?, showAllowed: Bool = true) -> TimeInterval {
        var t = t0
        while t < t0 + seconds {
            anchor.update(pose: pose, head: head, now: t, showAllowed: showAllowed)
            t += 1.0 / 90
        }
        return t
    }

    @Test func showsOverThePalmAfterTheDwell() {
        var a = RAVEHoloPalmAnchor(gate: .panel, tuning: .overPalm)
        a.update(pose: Self.pose(), head: Self.head, now: 0)
        #expect(!a.isVisible)                           // dwell not met
        let t = Self.run(&a, from: 1.0 / 90, seconds: 0.4, pose: Self.pose())
        #expect(a.isVisible && a.opacity == 1)
        let expected = Self.palm + simd_normalize(Self.head - Self.palm) * 0.05
        #expect(simd_distance(a.position!, expected) < 1e-4)
        // Faces the eyes.
        let m = a.transform!
        let n = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        #expect(simd_dot(n, simd_normalize(Self.head - a.position!)) > 0.999)
        _ = t
    }

    @Test func palmTurnedAwayNeverShows() {
        var a = RAVEHoloPalmAnchor(gate: .panel)
        _ = Self.run(&a, from: 0, seconds: 1, pose: Self.pose(toward: SIMD3(0, 1.2, -2)))
        #expect(!a.isVisible)
    }

    @Test func refusedShowStaysHidden() {
        var a = RAVEHoloPalmAnchor(gate: .panel)
        _ = Self.run(&a, from: 0, seconds: 1, pose: Self.pose(), showAllowed: false)
        #expect(!a.isVisible)
    }

    @Test func snapsInPlaceThenEasesAfterTheHand() {
        var a = RAVEHoloPalmAnchor(gate: .panel, tuning: .init(lift: 0.05, smoothing: 0.06))
        var t = Self.run(&a, from: 0, seconds: 0.4, pose: Self.pose())
        #expect(a.isVisible)
        // The hand moves 10 cm right: one frame covers only part of it.
        let moved = Self.palm + SIMD3(0.1, 0, 0)
        let target = moved + simd_normalize(Self.head - moved) * 0.05
        a.update(pose: Self.pose(moved), head: Self.head, now: t)
        t += 1.0 / 90
        let oneFrame = simd_distance(a.position!, target)
        #expect(oneFrame > 0.05 && oneFrame < 0.1)
        _ = Self.run(&a, from: t, seconds: 0.5, pose: Self.pose(moved))
        #expect(simd_distance(a.position!, target) < 0.001)
    }

    @Test func externallyGatedAnchorFollowsTheHostsDecision() {
        var a = RAVEHoloPalmAnchor(tuning: .offPalm)
        // Palm turned away, but the host says shown: placement still works.
        let away = Self.pose(toward: SIMD3(0, 1.2, -2))
        var t: TimeInterval = 0
        while t < 0.3 { a.update(pose: away, head: Self.head, now: t, shown: true); t += 1.0 / 90 }
        #expect(a.opacity == 1)
        let expected = Self.palm + away.palmNormalOut * 0.18
        #expect(simd_distance(a.position!, expected) < 1e-4)
        while t < 0.6 { a.update(pose: away, head: Self.head, now: t, shown: false); t += 1.0 / 90 }
        #expect(!a.isVisible)
    }

    @Test func trackingLossFadesInPlace() {
        var a = RAVEHoloPalmAnchor(gate: .panel, tuning: .overPalm)
        let t = Self.run(&a, from: 0, seconds: 0.4, pose: Self.pose())
        let where_ = a.position!
        a.update(pose: nil, head: Self.head, now: t)
        #expect(a.opacity < 1 && a.opacity > 0)
        #expect(a.position == where_)
        _ = Self.run(&a, from: t + 1.0 / 90, seconds: 0.3, pose: nil)
        #expect(!a.isVisible)
        #expect(a.position == where_)
    }
}

/// The tracking-area pass writes each target's render value where the target
/// is drawn, respecting the rounded corners, and 0 elsewhere.
@Suite struct RAVEHoloTargetRenderTests {
    @Test func targetPassWritesRenderValues() throws {
        guard #available(macOS 26.0, *), let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeMTL4CommandQueue(), let commandBuffer = device.makeCommandBuffer(),
              let allocator = device.makeCommandAllocator() else { return }
        let w = 256, h = 128
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let tracking = try #require(device.makeTexture(descriptor: td))
        let holo = try RAVEHoloRenderer(device: device,
                                        configuration: .init(colorFormat: .rgba16Float, depthFormat: .depth32Float,
                                                             maxViewCount: 1, slots: 1, trackingFormat: .r8Uint),
                                        font: RAVEHoloTests.font)
        #expect(holo.allocations.count == 5)

        var panel = RAVEHoloPanel(transform: matrix_identity_float4x4)
        panel.button(11, label: "A", font: RAVEHoloTests.font, x: -0.04, y: -0.015, width: 0.035, height: 0.03)
        panel.button(12, label: "B", font: RAVEHoloTests.font, x: 0.005, y: -0.015, width: 0.035, height: 0.03)
        panel.target(13, x: -0.04, y: 0.016, width: 0.01, height: 0.004)   // no render value: skipped
        var scene = RAVEHoloScene()
        scene.panels = [panel]
        var vp = matrix_identity_float4x4
        vp.columns.0.x = 2 / 0.084
        vp.columns.1.y = 2 / 0.042
        vp.columns.2.z = 0.5
        vp.columns.3.z = 0.5

        let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        residency.addAllocations(holo.allocations + [tracking])
        residency.commit()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.useResidencySet(residency)
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = tracking
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let enc = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1))
        let drawn = holo.encodeTargets(scene, renderValues: [11: 3, 12: 9], encoder: enc,
                                       viewProjections: [vp], slot: 0)
        enc.endEncoding()
        commandBuffer.endCommandBuffer()
        let done = DispatchSemaphore(value: 0)
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { _ in done.signal() }
        queue.commit([commandBuffer], options: options)
        done.wait()
        #expect(drawn == 2)

        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            tracking.getBytes(raw.baseAddress!, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        func value(x: Float, y: Float) -> UInt8 {
            let px = Int((x / 0.084 + 0.5) * Float(w)), py = Int((0.5 - y / 0.042) * Float(h))
            return bytes[py * w + px]
        }
        #expect(value(x: -0.0225, y: 0) == 3)
        #expect(value(x: 0.0225, y: 0) == 9)
        #expect(value(x: 0, y: 0) == 0)                 // between the buttons
        #expect(value(x: -0.0398, y: 0.0148) == 0)      // A's rounded corner
        #expect(value(x: -0.035, y: 0.018) == 0)        // the unregistered target
    }
}

/// A debug-panel layout through the real shader. `RAVEHOLO_LAYOUT_SNAPSHOT=
/// /path.png` writes it out, to judge sizes and the button look by eye.
@Suite struct RAVEHoloLayoutRenderTests {
    @Test func rendersADebugLayout() throws {
        let layout = RAVEHoloLayout(width: 0.09, items: [
            .title("Frame"),
            .row("FPS", "88.9"),
            .row("GPU MS", "12.4", warn: true),
            .sparkline([8, 9, 10, 9, 12, 14, 9, 8, 8, 9, 10, 11, 9, 8, 13, 9], max: 22, guide: 11.1, warnAbove: 11.1),
            .gauge("Thermal", value: "Fair", fraction: 0.4, segments: 8),
            .buttons([.init(1, "HUD", isOn: true), .init(2, "Aim"), .init(3, "Beam")]),
        ])
        let h = layout.height(font: RAVEHoloTests.font)
        // Scale into the 8.4 × 4.2 cm test window.
        let s = min(0.080 / 0.09, 0.040 / h)
        var m = matrix_identity_float4x4
        m.columns.0.x = s; m.columns.1.y = s; m.columns.2.z = s
        var scene = RAVEHoloScene()
        let interaction = RAVEHoloInteraction()
        interaction.recordPress(2, at: 0.9)
        scene.panels = [layout.panel(transform: m, font: RAVEHoloTests.font, interaction: interaction, now: 1)]
        guard let img = try RAVEHoloRenderTests().renderOnBlack(scene, width: 768) else { return }
        let peak = stride(from: 0, to: img.count, by: 4).map { img[$0] }.max() ?? 0
        #expect(peak > 0.6)
        if let path = ProcessInfo.processInfo.environment["RAVEHOLO_LAYOUT_SNAPSHOT"] {
            let w = 768, hPx = 384
            var bytes = [UInt8](repeating: 255, count: w * hPx * 4)
            for i in 0..<(w * hPx) {
                for c in 0..<3 {
                    let linear = max(0, min(1, img[i * 4 + c]))
                    let srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
                    bytes[i * 4 + c] = UInt8(srgb * 255)
                }
            }
            let ctx = CGContext(data: &bytes, width: w, height: hPx, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            if let image = ctx?.makeImage(),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }
}
