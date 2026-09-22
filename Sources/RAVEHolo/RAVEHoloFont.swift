import CoreGraphics
import CoreText
import Foundation

/// A signed-distance-field glyph atlas for in-world holographic text.
///
/// Built once on the CPU from a CoreText font: each glyph is rasterised at
/// `emPixels`, thresholded, and turned into a signed distance by an exact
/// Euclidean distance transform, so text stays sharp at any size and angle
/// the headset views it from. The atlas is one channel, 0.5 on the outline,
/// above inside, below outside, `spread` pixels either way.
///
/// Font choice is a preference list of PostScript names with a system
/// fallback, so no font file ships with the package.
public final class RAVEHoloFont: @unchecked Sendable {
    public struct Glyph: Sendable, Equatable {
        /// Advance, in em.
        public var advance: Float
        /// Quad placement relative to the pen at the baseline, in em
        /// (x right, y up), spread padding included.
        public var origin: SIMD2<Float>
        public var size: SIMD2<Float>
        /// Normalised atlas rectangle (u0, v0, u1, v1), v down.
        public var uv: SIMD4<Float>
    }

    public let width: Int
    public let height: Int
    /// Row-major R8 distance values, `width × height`.
    public let pixels: [UInt8]
    public let glyphs: [Character: Glyph]
    /// Cap height, in em — what a caller sizing "a line of capitals" wants.
    public let capHeight: Float
    public let fontName: String
    public let emPixels: Int
    public let spread: Int

    /// The characters a HUD needs: digits, capitals and a little punctuation.
    public static let defaultCharacters = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ%/:.-+·|<> "

    /// Condensed, square-shouldered faces first; the first one installed wins.
    public static let defaultFontNames = ["DINCondensed-Bold", "DINAlternate-Bold"]

    public convenience init(characters: String = RAVEHoloFont.defaultCharacters,
                            fontNames: [String] = RAVEHoloFont.defaultFontNames,
                            emPixels: Int = 64, spread: Int = 8) {
        self.init(font: Self.resolveFont(names: fontNames, size: CGFloat(emPixels)),
                  characters: characters, emPixels: emPixels, spread: spread)
    }

    public init(font: CTFont, characters: String, emPixels: Int, spread: Int) {
        self.emPixels = emPixels
        self.spread = spread
        fontName = CTFontCopyPostScriptName(font) as String
        let em = Float(emPixels)
        capHeight = Float(CTFontGetCapHeight(font)) / em

        // Rasterise every glyph first, then shelf-pack them.
        struct Raster { var character: Character; var w: Int; var h: Int; var field: [UInt8]; var glyph: Glyph }
        var rasters: [Raster] = []
        for character in characters {
            var chars = Array(String(character).utf16)
            var cg = [CGGlyph](repeating: 0, count: chars.count)
            guard CTFontGetGlyphsForCharacters(font, &chars, &cg, chars.count), let g = cg.first else { continue }
            var glyph = g
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
            if bounds.isEmpty || character == " " {
                rasters.append(Raster(character: character, w: 0, h: 0, field: [],
                                      glyph: Glyph(advance: Float(advance.width) / em, origin: .zero,
                                                   size: .zero, uv: .zero)))
                continue
            }
            let x0 = Int(floor(bounds.minX)) - spread, y0 = Int(floor(bounds.minY)) - spread
            let w = Int(ceil(bounds.maxX)) + spread - x0, h = Int(ceil(bounds.maxY)) + spread - y0
            let coverage = Self.rasterise(font: font, glyph: glyph, originX: x0, originY: y0, width: w, height: h)
            let field = Self.signedDistanceField(coverage: coverage, width: w, height: h, spread: Float(spread))
            rasters.append(Raster(character: character, w: w, h: h, field: field,
                                  glyph: Glyph(advance: Float(advance.width) / em,
                                               origin: SIMD2(Float(x0), Float(y0)) / em,
                                               size: SIMD2(Float(w), Float(h)) / em, uv: .zero)))
        }

        // Shelf packing, tallest first, into a power-of-two-wide atlas.
        let atlasWidth = 1024
        let order = rasters.indices.sorted { rasters[$0].h > rasters[$1].h }
        var placements = [Int: (Int, Int)]()
        var x = 1, y = 1, shelf = 0
        for i in order where rasters[i].w > 0 {
            let r = rasters[i]
            if x + r.w + 1 > atlasWidth { x = 1; y += shelf + 1; shelf = 0 }
            placements[i] = (x, y)
            x += r.w + 1
            shelf = max(shelf, r.h)
        }
        var atlasHeight = 64
        while atlasHeight < y + shelf + 1 { atlasHeight *= 2 }
        var atlas = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        var table: [Character: Glyph] = [:]
        for (i, r) in rasters.enumerated() {
            var glyph = r.glyph
            if let (px, py) = placements[i] {
                for row in 0..<r.h {
                    // The raster is bottom-up (CoreGraphics); the atlas is top-down.
                    let src = (r.h - 1 - row) * r.w
                    let dst = (py + row) * atlasWidth + px
                    atlas.replaceSubrange(dst..<(dst + r.w), with: r.field[src..<(src + r.w)])
                }
                glyph.uv = SIMD4(Float(px) / Float(atlasWidth), Float(py) / Float(atlasHeight),
                                 Float(px + r.w) / Float(atlasWidth), Float(py + r.h) / Float(atlasHeight))
            }
            table[r.character] = glyph
        }
        width = atlasWidth
        height = atlasHeight
        pixels = atlas
        glyphs = table
    }

    /// Width of `text` in em.
    public func advance(of text: String) -> Float {
        text.reduce(0) { $0 + (glyphs[$1]?.advance ?? glyphs[" "]?.advance ?? 0.25) }
    }

    // MARK: Building

    static func resolveFont(names: [String], size: CGFloat) -> CTFont {
        for name in names {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CTFontCreateWithName silently substitutes a default when the
            // name is not installed; only a matching PostScript name counts.
            if (CTFontCopyPostScriptName(font) as String) == name { return font }
        }
        let traits: [CFString: Any] = [kCTFontWeightTrait: 0.4, kCTFontWidthTrait: -0.3]
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// 8-bit coverage, bottom-up rows.
    private static func rasterise(font: CTFont, glyph: CGGlyph, originX: Int, originY: Int,
                                  width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            var g = glyph
            var position = CGPoint(x: -originX, y: -originY)
            CTFontDrawGlyphs(font, &g, &position, 1, ctx)
        }
        // CGContext rows run top-down in memory; flip to bottom-up so row 0
        // is the glyph's lowest row, matching the y-up glyph metrics.
        var flipped = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let src = row * width, dst = (height - 1 - row) * width
            flipped.replaceSubrange(dst..<(dst + width), with: buffer[src..<(src + width)])
        }
        return flipped
    }

    /// Signed distance from exact Euclidean transforms of the inside and the
    /// outside (Felzenszwalb & Huttenlocher), mapped so the outline is 0.5
    /// and ±`spread` pixels reach 1 and 0.
    static func signedDistanceField(coverage: [UInt8], width: Int, height: Int, spread: Float) -> [UInt8] {
        let inside = coverage.map { $0 >= 128 }
        let toInside = distanceTransform(width: width, height: height) { inside[$0] }
        let toOutside = distanceTransform(width: width, height: height) { !inside[$0] }
        return (0..<(width * height)).map { i in
            // Half a pixel either side puts the outline between the two runs.
            let d = inside[i] ? (toOutside[i].squareRoot() - 0.5) : -(toInside[i].squareRoot() - 0.5)
            let v = 0.5 + 0.5 * max(-1, min(1, d / spread))
            return UInt8((v * 255).rounded())
        }
    }

    /// Squared distance from every pixel to the nearest pixel where `isSource`.
    private static func distanceTransform(width: Int, height: Int, isSource: (Int) -> Bool) -> [Float] {
        let inf: Float = 1e20
        var grid = (0..<(width * height)).map { isSource($0) ? 0 : inf }
        var f = [Float](repeating: 0, count: max(width, height))
        var d = f
        func pass(count n: Int) {
            var v = [Int](repeating: 0, count: n)
            var z = [Float](repeating: 0, count: n + 1)
            var k = 0
            v[0] = 0; z[0] = -inf; z[1] = inf
            if n > 1 {
                for q in 1..<n {
                    var s: Float
                    repeat {
                        let p = v[k]
                        s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * (q - p))
                        if s <= z[k] { k -= 1 } else { break }
                    } while k >= 0
                    k += 1
                    v[k] = q; z[k] = s; z[k + 1] = inf
                }
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Float(q) { k += 1 }
                let p = v[k]
                d[q] = Float((q - p) * (q - p)) + f[p]
            }
        }
        for x in 0..<width {
            for y in 0..<height { f[y] = grid[y * width + x] }
            pass(count: height)
            for y in 0..<height { grid[y * width + x] = d[y] }
        }
        for y in 0..<height {
            for x in 0..<width { f[x] = grid[y * width + x] }
            pass(count: width)
            for x in 0..<width { grid[y * width + x] = d[x] }
        }
        return grid
    }
}
