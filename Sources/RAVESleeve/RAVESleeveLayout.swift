/*
 RAVE Engine — what is on a sleeve, as data.

 A layout says which controls sit on which face of the forearm, in pages of
 rows. It is `Codable` and names no framework and no app: the same layout is
 drawn by RAVEPanel (flat SwiftUI tiles in a RealityKit scene) and RAVEHolo
 (Metal hosts), and a user-made one (a deck of keys) is a JSON file. How a tile
 looks is the renderer's and the app's: a layout carries labels, icon keys and
 a role, not colours.

 What changes while the sleeve is worn (a toggle's state, a gauge's value) is
 not in the layout. The app keeps it in `RAVESleeveTileState` by tile id, so
 the layout stays a constant.

 What a press *does* is the app's too: a control carries a `RAVESleeveAction`
 (an id and an optional argument), and the sleeve reports it in an event.
 */

import Foundation

/// What a press means to the app: an id it maps to behaviour, and one
/// argument (a URL, a key chord, a number of seconds).
public struct RAVESleeveAction: Codable, Sendable, Hashable {
    public var id: String
    public var argument: String?

    public init(_ id: String, argument: String? = nil) {
        self.id = id
        self.argument = argument
    }
}

/// A hint for the drawer.
public enum RAVESleeveRole: String, Codable, Sendable {
    case normal
    /// The control the page is mostly for.
    case primary
    /// Costs something: a stop, a delete, a panic.
    case destructive
}

/// What a tile is.
public enum RAVESleeveControl: Codable, Sendable, Equatable {
    /// Text only.
    case label
    /// A label, a value and a bar. The value and fraction are tile state.
    case gauge(segments: Int = 0)
    /// Fires on the press.
    case button(RAVESleeveAction)
    /// Fires on the press; the event carries the state it should become.
    case toggle(RAVESleeveAction)
    /// Fires once the press has been held for `seconds`.
    case hold(RAVESleeveAction, seconds: Double)
    /// A value 0…1, set by where it is touched or dragged.
    case slider(RAVESleeveAction)
    /// Shows another page on this face.
    case page(String)
    /// Opens a radial menu from `RAVESleeveLayout.radials`.
    case radial(String)
    /// Opens or closes a docked panel from `RAVESleeveLayout.docks`.
    case dock(String)
    /// Drawn by the app: the key says what. Not pressable through the sleeve.
    case custom(String)

    /// Whether a press on it does anything.
    public var isInteractive: Bool {
        switch self {
        case .label, .gauge, .custom: return false
        default: return true
        }
    }
}

public struct RAVESleeveTile: Codable, Sendable, Equatable, Identifiable {
    /// Unique in the layout: tile state and events are keyed by it.
    public var id: String
    public var control: RAVESleeveControl
    public var label: String?
    /// An icon key for the drawer (the apps use SF Symbol names).
    public var icon: String?
    public var role: RAVESleeveRole
    /// Cells along the row.
    public var span: Int

    public init(_ id: String, _ control: RAVESleeveControl, label: String? = nil, icon: String? = nil,
                role: RAVESleeveRole = .normal, span: Int = 1) {
        self.id = id
        self.control = control
        self.label = label
        self.icon = icon
        self.role = role
        self.span = max(1, span)
    }
}

/// One page of a face: rows of tiles. A row runs the way its text reads; rows
/// stack round the arm, the first at the reader's top.
public struct RAVESleevePage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var rows: [[RAVESleeveTile]]

    public init(_ id: String, title: String? = nil, rows: [[RAVESleeveTile]]) {
        self.id = id
        self.title = title
        self.rows = rows
    }

    /// The widest row, in cells.
    public var columns: Int { rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 0 }
}

/// One entry of a radial menu. Entries with `members` open into an outer arc.
public struct RAVESleeveRadialEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String?
    public var action: RAVESleeveAction?
    public var role: RAVESleeveRole
    /// The entry must stay armed this long before it can be picked.
    public var confirmSeconds: Double
    public var members: [RAVESleeveRadialEntry]

    public init(_ id: String, label: String, icon: String? = nil, action: RAVESleeveAction? = nil,
                role: RAVESleeveRole = .normal, confirmSeconds: Double = 0,
                members: [RAVESleeveRadialEntry] = []) {
        self.id = id
        self.label = label
        self.icon = icon
        self.action = action
        self.role = role
        self.confirmSeconds = confirmSeconds
        self.members = members
    }
}

public struct RAVESleeveRadialMenu: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var entries: [RAVESleeveRadialEntry]

    public init(_ id: String, entries: [RAVESleeveRadialEntry]) {
        self.id = id
        self.entries = entries
    }
}

/// A panel too big for the arm (a web page, a set of stream controls) that a
/// tile opens beside it.
public struct RAVESleeveDock: Codable, Sendable, Equatable, Identifiable {
    public enum Mount: String, Codable, Sendable {
        /// Stands off the arm and moves with it.
        case arm
        /// Stays in the lower part of the view.
        case view
        /// Stays where it was opened.
        case world
    }

    public var id: String
    public var title: String?
    /// What the app puts in it: "web", "stream", its own.
    public var kind: String
    /// For the app: a URL for a web panel.
    public var argument: String?
    /// Metres wide; the height follows from `aspect` (width / height).
    public var width: Float
    public var aspect: Float
    public var mount: Mount

    public init(_ id: String, kind: String, argument: String? = nil, title: String? = nil,
                width: Float = 0.24, aspect: Float = 4.0 / 3.0, mount: Mount = .arm) {
        self.id = id
        self.kind = kind
        self.argument = argument
        self.title = title
        self.width = width
        self.aspect = aspect
        self.mount = mount
    }

    public var height: Float { width / max(aspect, 0.1) }
}

/// Everything on one sleeve.
public struct RAVESleeveLayout: Codable, Sendable, Equatable {
    /// Pages of the back of the forearm; the first is shown first.
    public var outer: [RAVESleevePage]
    /// Pages of the palm side.
    public var inner: [RAVESleevePage]
    public var radials: [RAVESleeveRadialMenu]
    public var docks: [RAVESleeveDock]
    public var reading: RAVESleeveReading

    public init(outer: [RAVESleevePage] = [], inner: [RAVESleevePage] = [],
                radials: [RAVESleeveRadialMenu] = [], docks: [RAVESleeveDock] = [],
                reading: RAVESleeveReading = .watch) {
        self.outer = outer
        self.inner = inner
        self.radials = radials
        self.docks = docks
        self.reading = reading
    }

    public func pages(_ face: RAVESleeveFace) -> [RAVESleevePage] { face == .outer ? outer : inner }

    public func radial(_ id: String) -> RAVESleeveRadialMenu? { radials.first { $0.id == id } }
    public func dock(_ id: String) -> RAVESleeveDock? { docks.first { $0.id == id } }

    /// Every tile, with the face and page it is on.
    public var allTiles: [(face: RAVESleeveFace, page: String, tile: RAVESleeveTile)] {
        RAVESleeveFace.allCases.flatMap { face in
            pages(face).flatMap { page in page.rows.joined().map { (face, page.id, $0) } }
        }
    }

    /// What is wrong with a layout made by hand: ids used twice, and tiles
    /// that point at a page, menu or dock that is not there. Empty when sound.
    public func problems() -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for (face, page, tile) in allTiles {
            if !seen.insert(tile.id).inserted { found.append("tile id \"\(tile.id)\" is used more than once") }
            switch tile.control {
            case let .page(target) where !pages(face).contains(where: { $0.id == target }):
                found.append("tile \"\(tile.id)\" on page \"\(page)\" opens page \"\(target)\", which is not on its face")
            case let .radial(target) where radial(target) == nil:
                found.append("tile \"\(tile.id)\" opens radial menu \"\(target)\", which is not in the layout")
            case let .dock(target) where dock(target) == nil:
                found.append("tile \"\(tile.id)\" opens dock \"\(target)\", which is not in the layout")
            default:
                break
            }
        }
        return found
    }
}

/// What changes about a tile while the sleeve is worn. The app owns it.
public struct RAVESleeveTileState: Sendable, Equatable {
    /// A toggle's state; lights a button too.
    public var isOn: Bool
    /// A gauge's or slider's value, 0…1.
    public var fraction: Float
    /// Replaces the tile's label (a gauge's value, a now-playing title).
    public var text: String?
    /// A gauge in its warning colour.
    public var warn: Bool
    /// Drawn faint and not pressable.
    public var disabled: Bool
    /// Not drawn; its cell stays empty.
    public var hidden: Bool

    public init(isOn: Bool = false, fraction: Float = 0, text: String? = nil, warn: Bool = false,
                disabled: Bool = false, hidden: Bool = false) {
        self.isOn = isOn
        self.fraction = fraction
        self.text = text
        self.warn = warn
        self.disabled = disabled
        self.hidden = hidden
    }
}

/// Sizes, in metres.
public struct RAVESleeveMetrics: Sendable, Equatable {
    /// One cell, square. 3.4 cm is a little over a Stream Deck key's pitch
    /// and wide enough for a fingertip or a gaze target at arm's length.
    public var cell: Float
    public var gap: Float
    /// From the wrist to the nearest edge of the tiles.
    public var start: Float
    /// The arm's radius where the tiles sit.
    public var armRadius: Float
    /// How far off the skin the tiles float.
    public var lift: Float

    public init(cell: Float = 0.034, gap: Float = 0.004, start: Float = 0.025,
                armRadius: Float = 0.036, lift: Float = 0.012) {
        self.cell = cell
        self.gap = gap
        self.start = start
        self.armRadius = armRadius
        self.lift = lift
    }

    /// The tiles' distance from the arm's axis.
    public var radius: Float { armRadius + lift }
}
