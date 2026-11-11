/*
 RAVE Engine — the guardian's settings: whether it runs, when it shows, the
 safety margins it keeps, which tracked parts it watches, and how it looks.

 Codable and Foundation-only so the apps persist it as one JSON blob and the
 host tests can exercise every combination. On by default: a guardian that
 has to be switched on protects nobody the first time they swing an arm at a
 wall.
 */

import Foundation

public struct RAVEGuardianSettings: Codable, Equatable, Sendable {

    /// When the outline shows.
    public enum Visibility: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Only near a wall, or when a tracked part is heading for one fast.
        case proximity
        /// The nearby walls always show faintly, brightening near them.
        case always
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .proximity: "When close"
            case .always: "Always"
            }
        }
    }

    /// What the outline is drawn with. All of them are tiled in world space,
    /// so the pattern lies flat along each real wall.
    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        case grid
        case lines
        case solid
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .grid: "Grid"
            case .lines: "Lines"
            case .solid: "Solid"
            }
        }
    }

    /// sRGB, 0...1 each.
    public struct Color: Codable, Equatable, Sendable {
        public var red: Float
        public var green: Float
        public var blue: Float
        public init(red: Float, green: Float, blue: Float) {
            self.red = red; self.green = green; self.blue = blue
        }

        public static let cyan = Color(red: 0.20, green: 0.75, blue: 1.00)
        public static let violet = Color(red: 0.62, green: 0.42, blue: 1.00)
        public static let green = Color(red: 0.25, green: 0.95, blue: 0.45)
        public static let amber = Color(red: 1.00, green: 0.70, blue: 0.15)
        public static let red = Color(red: 1.00, green: 0.28, blue: 0.25)
        public static let white = Color(red: 0.95, green: 0.95, blue: 0.95)

        public static let presets: [(name: String, color: Color)] = [
            ("Cyan", .cyan), ("Violet", .violet), ("Green", .green),
            ("Amber", .amber), ("Red", .red), ("White", .white),
        ]
    }

    public struct Appearance: Codable, Equatable, Sendable {
        public var style: Style = .grid
        public var color: Color = .cyan
        /// Metres between grid lines.
        public var spacing: Float = 0.25
        /// Line width in metres.
        public var lineWidth: Float = 0.012
        /// Opacity at full alert, 0...1.
        public var maxOpacity: Float = 0.9
        /// Opacity of the resting outline in `.always`, 0...1.
        public var restingOpacity: Float = 0.2
        public init() {}

        public static let spacingRange: ClosedRange<Float> = 0.1...0.6
        public static let lineWidthRange: ClosedRange<Float> = 0.004...0.03
    }

    /// Master switch. On by default.
    public var isEnabled: Bool = true
    public var visibility: Visibility = .proximity

    /// The safety margin, metres: inside this distance of a wall the outline
    /// starts to show, reaching full strength at a quarter of it.
    public var warningDistance: Float = 0.45
    /// Seconds of travel looked ahead: a part moving toward a wall is judged
    /// by where it will be this long from now, so a fast swing warns earlier
    /// than a slow lean. Zero turns the speed term off.
    public var lookahead: Float = 0.45
    /// Below this approach speed (m/s) the lookahead is ignored, so ordinary
    /// hand jitter near a wall does not pulse the outline.
    public var minimumApproachSpeed: Float = 0.35

    public var watchesHead: Bool = true
    public var watchesHands: Bool = true
    public var watchesControllers: Bool = true
    /// Furniture and other obstacles (tables, shelves, seats) count as well as
    /// walls, doors and windows.
    public var includesFurniture: Bool = false

    public var appearance = Appearance()

    public init() {}

    public static let warningDistanceRange: ClosedRange<Float> = 0.15...1.5
    public static let lookaheadRange: ClosedRange<Float> = 0...1.2

    /// Whether this probe kind is watched under these settings.
    public func watches(_ kind: RAVEGuardianProbe.Kind) -> Bool {
        switch kind {
        case .head: watchesHead
        case .hand: watchesHands
        case .controller: watchesControllers
        }
    }

    /// Clamp everything to the ranges the UI offers. A hand-edited or older
    /// blob can't produce a zero spacing (an infinite texture repeat) or a
    /// negative margin.
    public func sanitized() -> RAVEGuardianSettings {
        var s = self
        s.warningDistance = s.warningDistance.clamped(to: Self.warningDistanceRange)
        s.lookahead = s.lookahead.clamped(to: Self.lookaheadRange)
        s.minimumApproachSpeed = max(0, s.minimumApproachSpeed)
        s.appearance.spacing = s.appearance.spacing.clamped(to: Appearance.spacingRange)
        s.appearance.lineWidth = s.appearance.lineWidth.clamped(to: Appearance.lineWidthRange)
        s.appearance.maxOpacity = s.appearance.maxOpacity.clamped(to: 0.1...1)
        s.appearance.restingOpacity = s.appearance.restingOpacity.clamped(to: 0.02...1)
        for c in [\Color.red, \Color.green, \Color.blue] {
            s.appearance.color[keyPath: c] = s.appearance.color[keyPath: c].clamped(to: 0...1)
        }
        return s
    }

    // Decoding tolerates missing keys, so a blob saved by an older build
    // keeps the user's choices and picks up defaults for anything new.
    private enum CodingKeys: String, CodingKey {
        case isEnabled, visibility, warningDistance, lookahead, minimumApproachSpeed
        case watchesHead, watchesHands, watchesControllers, includesFurniture, appearance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RAVEGuardianSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        visibility = (try? c.decodeIfPresent(Visibility.self, forKey: .visibility)) ?? d.visibility
        warningDistance = try c.decodeIfPresent(Float.self, forKey: .warningDistance) ?? d.warningDistance
        lookahead = try c.decodeIfPresent(Float.self, forKey: .lookahead) ?? d.lookahead
        minimumApproachSpeed = try c.decodeIfPresent(Float.self, forKey: .minimumApproachSpeed) ?? d.minimumApproachSpeed
        watchesHead = try c.decodeIfPresent(Bool.self, forKey: .watchesHead) ?? d.watchesHead
        watchesHands = try c.decodeIfPresent(Bool.self, forKey: .watchesHands) ?? d.watchesHands
        watchesControllers = try c.decodeIfPresent(Bool.self, forKey: .watchesControllers) ?? d.watchesControllers
        includesFurniture = try c.decodeIfPresent(Bool.self, forKey: .includesFurniture) ?? d.includesFurniture
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? d.appearance
    }
}

extension RAVEGuardianSettings.Appearance {
    private enum CodingKeys: String, CodingKey {
        case style, color, spacing, lineWidth, maxOpacity, restingOpacity
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        style = (try? c.decodeIfPresent(RAVEGuardianSettings.Style.self, forKey: .style)) ?? d.style
        color = try c.decodeIfPresent(RAVEGuardianSettings.Color.self, forKey: .color) ?? d.color
        spacing = try c.decodeIfPresent(Float.self, forKey: .spacing) ?? d.spacing
        lineWidth = try c.decodeIfPresent(Float.self, forKey: .lineWidth) ?? d.lineWidth
        maxOpacity = try c.decodeIfPresent(Float.self, forKey: .maxOpacity) ?? d.maxOpacity
        restingOpacity = try c.decodeIfPresent(Float.self, forKey: .restingOpacity) ?? d.restingOpacity
    }
}

/// The settings, persisted to `UserDefaults` as JSON under one key. Each app
/// keeps one store (usually `shared`) and hands it to its guardian, which
/// picks up changes on the next frame.
@MainActor
@Observable
public final class RAVEGuardianSettingsStore {
    public static let shared = RAVEGuardianSettingsStore()

    public var settings: RAVEGuardianSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "RAVEGuardian.settings") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(RAVEGuardianSettings.self, from: data) {
            settings = decoded.sanitized()
        } else {
            settings = RAVEGuardianSettings()
        }
    }

    public func resetToDefaults() { settings = RAVEGuardianSettings() }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
