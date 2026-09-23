import simd

/// One frame's worth of holographic panels, built on the CPU each frame and
/// drawn by `RAVEHoloRenderer`. Pure data: no Metal, so layout is testable on
/// the host.
///
/// A panel is a flat card in the world: `transform` maps panel-local metres
/// (x right, y up, origin at the panel centre, +z toward the viewer) into
/// world space. Everything on it is a quad in those local metres.
public struct RAVEHoloScene: Sendable {
    public var panels: [RAVEHoloPanel] = []
    public init() {}

    public var quadCount: Int { panels.reduce(0) { $0 + $1.quads.count } }
}

public struct RAVEHoloQuad: Sendable, Equatable {
    public enum Kind: UInt32, Sendable {
        /// Rounded rectangle; `params.x` = corner radius (m).
        case fill = 0
        /// Rounded rectangle outline; `params.x` = corner radius, `params.y` = line width (m).
        case frame = 1
        /// Segmented gauge; `params.x` = fill fraction 0…1, `params.y` = segment count
        /// (0 = continuous), `params.z` = gap between segments (m), `params.w` =
        /// corner radius (m) of the gauge, or of each segment when segmented.
        case bar = 2
        /// SDF glyph; `params` = atlas rectangle (u0, v0, u1, v1).
        case glyph = 3
    }
    public var kind: Kind
    /// Centre-origin panel metres: (min x, min y, width, height).
    public var rect: SIMD4<Float>
    public var params: SIMD4<Float>
    /// Linear RGB and opacity.
    public var color: SIMD4<Float>
}

public struct RAVEHoloPanel: Sendable {
    public enum Alignment: Sendable { case leading, center, trailing }

    public var transform: simd_float4x4
    /// Multiplies every quad's opacity (fade in/out).
    public var opacity: Float
    /// Multiplies the light the panel emits, not its backing's darkening:
    /// dims a hologram for a dark room without making it more see-through.
    public var brightness: Float = 1
    /// Per-panel phase for the flicker, so panels don't pulse in lockstep.
    public var seed: Float
    public var quads: [RAVEHoloQuad] = []

    public init(transform: simd_float4x4, opacity: Float = 1, seed: Float = 0) {
        self.transform = transform
        self.opacity = opacity
        self.seed = seed
    }

    public mutating func fill(x: Float, y: Float, width: Float, height: Float,
                              corner: Float = 0, color: SIMD4<Float>) {
        quads.append(RAVEHoloQuad(kind: .fill, rect: SIMD4(x, y, width, height),
                                  params: SIMD4(corner, 0, 0, 0), color: color))
    }

    public mutating func frame(x: Float, y: Float, width: Float, height: Float,
                               corner: Float = 0, line: Float, color: SIMD4<Float>) {
        quads.append(RAVEHoloQuad(kind: .frame, rect: SIMD4(x, y, width, height),
                                  params: SIMD4(corner, line, 0, 0), color: color))
    }

    public mutating func bar(x: Float, y: Float, width: Float, height: Float,
                             fraction: Float, segments: Int = 0, gap: Float = 0,
                             corner: Float = 0, color: SIMD4<Float>) {
        quads.append(RAVEHoloQuad(kind: .bar, rect: SIMD4(x, y, width, height),
                                  params: SIMD4(max(0, min(1, fraction)), Float(segments), gap, max(0, corner)),
                                  color: color))
    }

    /// Lay out `text` on the baseline at `y`, capitals `capHeight` metres
    /// tall, anchored at `x` by `alignment`. Returns the laid-out width (m).
    @discardableResult
    public mutating func text(_ text: String, font: RAVEHoloFont, x: Float, y: Float,
                              capHeight: Float, alignment: Alignment = .leading,
                              tracking: Float = 0, color: SIMD4<Float>) -> Float {
        let em = capHeight / max(font.capHeight, 0.01)
        let trackingEm = tracking / em
        let width = (font.advance(of: text) + trackingEm * Float(max(0, text.count - 1))) * em
        var pen: Float
        switch alignment {
        case .leading: pen = x
        case .center: pen = x - width / 2
        case .trailing: pen = x - width
        }
        for character in text {
            guard let g = font.glyphs[character] else { pen += 0.25 * em; continue }
            if g.size.x > 0 {
                quads.append(RAVEHoloQuad(kind: .glyph,
                                          rect: SIMD4(pen + g.origin.x * em, y + g.origin.y * em,
                                                      g.size.x * em, g.size.y * em),
                                          params: g.uv, color: color))
            }
            pen += (g.advance + trackingEm) * em
        }
        return width
    }
}

public extension RAVEHoloPanel {
    /// A card at `position` whose face turns toward `viewer`, kept upright
    /// against world +y (a billboard that does not roll).
    static func facing(position: SIMD3<Float>, viewer: SIMD3<Float>,
                       up worldUp: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
        var n = viewer - position
        n = simd_length(n) > 1e-5 ? simd_normalize(n) : SIMD3(0, 0, 1)
        var right = simd_cross(worldUp, n)
        right = simd_length(right) > 1e-4 ? simd_normalize(right) : SIMD3(1, 0, 0)
        let up = simd_cross(n, right)
        return simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(n, 0), SIMD4(position, 1))
    }
}
