import Foundation
import simd

/// Colours and sizes shared by the widgets and `RAVEHoloLayout`. Metres, on
/// a panel viewed from roughly arm's length.
///
/// Sizes are chosen for reading and pinching at 35–50 cm: text caps of
/// 3.4–5 mm are what LambdaVision's HEV readouts use, and a button is at least
/// 2.2 cm tall because gaze targeting needs about 2.5° to land reliably.
public struct RAVEHoloTheme: Sendable, Equatable {
    public var accent = SIMD3<Float>(1.0, 0.56, 0.12)
    public var warning = SIMD3<Float>(1.0, 0.20, 0.10)
    /// The dark card behind everything (real alpha: it darkens what is behind).
    public var backing = SIMD4<Float>(0.015, 0.010, 0.006, 0.42)
    /// An unlit button's face.
    public var buttonFill = SIMD3<Float>(0.08, 0.085, 0.10)
    /// A lit (on) button's label.
    public var onLabel = SIMD3<Float>(1.0, 0.92, 0.75)
    public var corner: Float = 0.004
    public var line: Float = 0.0006
    public var padding: Float = 0.005
    public var spacing: Float = 0.003
    public var titleCap: Float = 0.0042
    public var labelCap: Float = 0.0034
    public var valueCap: Float = 0.0050
    public var buttonCap: Float = 0.0045
    public var buttonHeight: Float = 0.022
    public var gaugeHeight: Float = 0.0028
    /// Letter spacing for labels and titles.
    public var tracking: Float = 0.0006

    public init() {}

    /// The HEV amber look.
    public static let amber = RAVEHoloTheme()
}

public extension RAVEHoloPanel {
    /// A pinchable button: a face, a rim, a centred label and a target over
    /// the whole rectangle. `isOn` lights it (for toggles and the selected
    /// segment of a picker); `flash` (0…1, usually
    /// `RAVEHoloInteraction.flash`) blends it toward white after a press.
    mutating func button(_ id: UInt64, label: String, font: RAVEHoloFont,
                         x: Float, y: Float, width: Float, height: Float,
                         theme: RAVEHoloTheme = .amber, isOn: Bool = false, flash: Float = 0) {
        let corner = min(theme.corner, min(width, height) * 0.5)
        var face = isOn ? theme.accent * 0.55 : theme.buttonFill
        face = simd_mix(face, SIMD3(repeating: 1), SIMD3(repeating: max(0, min(1, flash)) * 0.6))
        fill(x: x, y: y, width: width, height: height, corner: corner, color: SIMD4(face, 0.9))
        frame(x: x, y: y, width: width, height: height, corner: corner, line: theme.line * 1.5,
              color: SIMD4(theme.accent, isOn ? 0.95 : 0.7))
        let cap = min(theme.buttonCap, height * 0.36)
        text(label.uppercased(), font: font, x: x + width / 2, y: y + (height - cap) / 2, capHeight: cap,
             alignment: .center, tracking: theme.tracking, color: SIMD4(isOn ? theme.onLabel : theme.accent, 1))
        target(id, x: x, y: y, width: width, height: height, corner: corner)
    }

    /// Bottom-aligned bars, one per value, scaled so `maxValue` fills the
    /// height (values above it clip). Bars above `warnAbove` take the warning
    /// colour; `guide` draws a faint horizontal line at that value — a frame
    /// budget, say. Oldest value leftmost.
    mutating func sparkline(_ values: [Float], maxValue: Float,
                            x: Float, y: Float, width: Float, height: Float,
                            theme: RAVEHoloTheme = .amber,
                            warnAbove: Float? = nil, guide: Float? = nil) {
        fill(x: x, y: y, width: width, height: height, color: SIMD4(theme.buttonFill, 0.35))
        guard !values.isEmpty, maxValue > 0 else { return }
        let cell = width / Float(values.count)
        let barWidth = max(cell * 0.7, 0.0002)
        for (i, value) in values.enumerated() {
            let h = max(0, min(1, value / maxValue)) * height
            guard h > 0 else { continue }
            let warn = warnAbove.map { value > $0 } ?? false
            fill(x: x + Float(i) * cell + (cell - barWidth) / 2, y: y, width: barWidth, height: h,
                 color: SIMD4(warn ? theme.warning : theme.accent, 0.9))
        }
        if let guide, guide > 0, guide < maxValue {
            fill(x: x, y: y + guide / maxValue * height - theme.line / 2, width: width, height: theme.line,
                 color: SIMD4(theme.accent * 0.6, 0.8))
        }
    }
}

/// A vertical stack of rows on one card — enough for a debug readout or a
/// small control panel without placing every quad by hand.
///
/// The panel's origin is the card's centre (as for any `RAVEHoloPanel`);
/// `height(font:)` tells the host how tall it will be, e.g. to rest its
/// bottom edge on an anchor. Labels are upper-cased: the default glyph atlas
/// carries capitals only.
public struct RAVEHoloLayout: Sendable {
    public struct Button: Sendable, Equatable {
        public var id: UInt64
        public var label: String
        public var isOn: Bool
        public init(_ id: UInt64, _ label: String, isOn: Bool = false) {
            self.id = id; self.label = label; self.isOn = isOn
        }
    }

    public enum Item: Sendable {
        case title(String)
        /// Label left, value right.
        case row(String, String, warn: Bool = false)
        /// Label and value on one line, a gauge under them.
        case gauge(String, value: String, fraction: Float, segments: Int = 0, warn: Bool = false)
        case sparkline([Float], max: Float, guide: Float? = nil, warnAbove: Float? = nil, height: Float = 0.012)
        /// Equal-width buttons side by side (`nil` height = the theme's).
        case buttons([Button], height: Float? = nil)
        case spacer(Float)
    }

    public var width: Float
    public var theme: RAVEHoloTheme
    public var items: [Item]

    public init(width: Float = 0.09, theme: RAVEHoloTheme = .amber, items: [Item] = []) {
        self.width = width
        self.theme = theme
        self.items = items
    }

    private func height(of item: Item) -> Float {
        switch item {
        case .title: return theme.titleCap
        case .row: return max(theme.labelCap, theme.valueCap)
        case .gauge: return theme.valueCap + theme.spacing + theme.gaugeHeight
        case let .sparkline(_, _, _, _, height): return height
        case let .buttons(_, height): return height ?? theme.buttonHeight
        case let .spacer(height): return height
        }
    }

    /// Total card height: padding, items and the spacing between them.
    public func height(font: RAVEHoloFont) -> Float {
        guard !items.isEmpty else { return theme.padding * 2 }
        return items.reduce(0) { $0 + height(of: $1) } + theme.spacing * Float(items.count - 1) + theme.padding * 2
    }

    /// Build the card. Pass `interaction` + `now` to flash pressed buttons.
    public func panel(transform: simd_float4x4, font: RAVEHoloFont, opacity: Float = 1, seed: Float = 0,
                      interaction: RAVEHoloInteraction? = nil, now: TimeInterval = 0) -> RAVEHoloPanel {
        var p = RAVEHoloPanel(transform: transform, opacity: opacity, seed: seed)
        let total = height(font: font)
        let left = -width / 2, right = width / 2
        let inner = width - theme.padding * 2
        p.fill(x: left, y: -total / 2, width: width, height: total, corner: theme.corner, color: theme.backing)
        p.frame(x: left, y: -total / 2, width: width, height: total, corner: theme.corner, line: theme.line,
                color: SIMD4(theme.accent, 0.85))
        let label = SIMD4(theme.accent * 0.8, 0.9)
        var top = total / 2 - theme.padding
        for item in items {
            let h = height(of: item)
            let bottom = top - h
            let x0 = left + theme.padding, x1 = right - theme.padding
            switch item {
            case let .title(text):
                p.text(text.uppercased(), font: font, x: x0, y: bottom, capHeight: theme.titleCap,
                       tracking: theme.tracking, color: SIMD4(theme.accent, 1))
            case let .row(name, value, warn):
                p.text(name.uppercased(), font: font, x: x0, y: bottom, capHeight: theme.labelCap,
                       tracking: theme.tracking, color: label)
                p.text(value.uppercased(), font: font, x: x1, y: bottom, capHeight: theme.valueCap,
                       alignment: .trailing, color: SIMD4(warn ? theme.warning : theme.accent, 1))
            case let .gauge(name, value, fraction, segments, warn):
                let lineY = bottom + theme.gaugeHeight + theme.spacing
                let colour = warn ? theme.warning : theme.accent
                p.text(name.uppercased(), font: font, x: x0, y: lineY, capHeight: theme.labelCap,
                       tracking: theme.tracking, color: label)
                p.text(value.uppercased(), font: font, x: x1, y: lineY, capHeight: theme.valueCap,
                       alignment: .trailing, color: SIMD4(colour, 1))
                p.bar(x: x0, y: bottom, width: inner, height: theme.gaugeHeight, fraction: fraction,
                      segments: segments, gap: segments > 0 ? 0.0007 : 0, corner: theme.gaugeHeight / 2,
                      color: SIMD4(colour, 0.95))
            case let .sparkline(values, maxValue, guide, warnAbove, _):
                p.sparkline(values, maxValue: maxValue, x: x0, y: bottom, width: inner, height: h,
                            theme: theme, warnAbove: warnAbove, guide: guide)
            case let .buttons(buttons, _):
                guard !buttons.isEmpty else { break }
                let gap = theme.spacing
                let w = (inner - gap * Float(buttons.count - 1)) / Float(buttons.count)
                for (i, b) in buttons.enumerated() {
                    p.button(b.id, label: b.label, font: font, x: x0 + Float(i) * (w + gap), y: bottom,
                             width: w, height: h, theme: theme, isOn: b.isOn,
                             flash: interaction?.flash(b.id, now: now) ?? 0)
                }
            case .spacer:
                break
            }
            top = bottom - theme.spacing
        }
        return p
    }
}
