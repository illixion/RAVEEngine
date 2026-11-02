/*
 RAVE Engine — a radial menu a hand or a gamepad stick can drive.

 Generic over what a pick *means*: an entry carries the app's own `Action`
 value and some text; the menu knows only about sectors, arming and committing.
 What goes on the wheel, and what a pick does, is the game's.

 **Layout.** Entries run clockwise from 12 o'clock, one equal sector each. A
 sector is armed by moving toward it past a deadzone and **stays armed until the
 hand is clearly inside a neighbour** (`stickiness`, a fraction of a sector), so
 a boundary does not flicker. Releasing commits the armed entry; releasing in
 the deadzone, losing the hand or the gesture going off cancels.

 **Confirm holds.** An entry with `confirmSeconds` commits on release only after
 it has stayed armed that long, for picks where a stray release costs something
 (overwriting a save, throwing progress away). `RAVERadial.confirmProgress` is
 the 0…1 ring to draw while it fills.

 **Nested picks.** An entry with `members` opens, when the hand pushes on past
 the wheel's rim, into an outer arc of its own members centred on it. Sliding
 along the arc picks one; releasing selects exactly that member. Coming back
 inside the rim folds the arc and the wheel works as before. An entry with a
 single member (or none) never opens.

 **Two drivers over the same entries:**
 - `RAVERadialHandMenu`: pinch all four fingertips to the thumb to open (a
   clenched fist is kept out by a gate on the middle finger), move the hand
   toward a sector, release the pinch to pick. Anchored where it opened.
 - `RAVERadialStickMenu`: hold a button to open, point a stick at a sector,
   release the button to pick. The sector stays armed when the stick springs
   back to the middle, so flick-and-release works.

 Both give the drawer a `RAVERadialView`: where to centre it and which way is
 up and right, so the same panel code draws either.

 Value types, no isolation, time passed in, so they run from a render thread.
 The thresholds are LambdaVision's, tuned live there and unverified elsewhere.
 */

import Foundation
import simd

/// One entry on a radial menu. `Action` is the app's own pick value.
public struct RAVERadialEntry<Action: Sendable & Equatable>: Sendable, Equatable {
    public var action: Action
    /// Text for the drawer: shown when there is no icon, and under entries that
    /// are not icons.
    public var label: String
    /// An icon key for the drawer; the menu never reads it.
    public var iconKey: String?
    /// Drawn faint but still pickable. A hint for the drawer.
    public var dim: Bool
    /// Dots under the icon when the entry stands for several things, and which
    /// of them this pick selects. Hints for the drawer.
    public var pips: Int
    public var pip: Int
    /// How long the sector must stay armed before a release commits.
    public var confirmSeconds: Double
    /// Nested picks, opened by pushing past the rim. Each is a plain entry.
    public var members: [RAVERadialEntry<Action>]
    /// Marks the current choice in the opened arc. A hint for the drawer.
    public var inHand: Bool

    public init(action: Action, label: String, iconKey: String? = nil, dim: Bool = false,
                pips: Int = 0, pip: Int = 0, confirmSeconds: Double = 0,
                members: [RAVERadialEntry<Action>] = [], inHand: Bool = false) {
        self.action = action
        self.label = label
        self.iconKey = iconKey
        self.dim = dim
        self.pips = pips
        self.pip = pip
        self.confirmSeconds = confirmSeconds
        self.members = members
        self.inHand = inHand
    }
}

/// What an open menu draws, whichever input drives it.
public struct RAVERadialView<Action: Sendable & Equatable>: Sendable {
    /// An opened entry (an index into `entries`) and the member armed on its arc.
    public struct Expansion: Sendable, Equatable {
        public var entry: Int
        public var selected: Int
    }

    public var center: SIMD3<Float>
    public var right: SIMD3<Float>
    public var up: SIMD3<Float>
    public var entries: [RAVERadialEntry<Action>]
    /// The armed entry, or -1.
    public var selected: Int
    /// The armed entry's confirm hold, 0…1, or nil when it needs none.
    public var confirm: Float?
    /// The opened entry, or nil while folded.
    public var expansion: Expansion?
}

/// The sector geometry and commit rules, shared by both drivers.
public enum RAVERadial {
    /// Narrowest an opened entry's member may be, in turns: room for its icon
    /// on the outer arc.
    public static let minMemberTurns: Float = 0.06

    /// Clockwise turns from 12 o'clock to (dx right, dy up), in [0, 1).
    public static func turns(dx: Float, dy: Float) -> Float {
        var a = atan2f(dx, dy) / (2 * .pi)
        if a < 0 { a += 1 }
        return a >= 1 ? 0 : a
    }

    /// The sector under an offset (dx right, dy up) on a wheel of `count`
    /// sectors, or -1 inside the deadzone. `current` stays armed until the
    /// offset is `stickiness` (a fraction of a sector) past its edge.
    public static func sector(dx: Float, dy: Float, count: Int, deadzone: Float,
                              current: Int = -1, stickiness: Float = 0.15) -> Int {
        guard count > 0, (dx * dx + dy * dy).squareRoot() > deadzone else { return -1 }
        let t = turns(dx: dx, dy: dy) * Float(count)
        if current >= 0, current < count {
            // Distance in sectors from the current sector's span, wrapping.
            var d = t - Float(current)            // 0…1 inside
            if d < -Float(count) / 2 { d += Float(count) }
            if d > Float(count) / 2 { d -= Float(count) }
            if d >= -stickiness, d <= 1 + stickiness { return current }
        }
        return min(count - 1, Int(t))
    }

    /// The angle, in turns clockwise from 12 o'clock, at a sector's middle.
    public static func sectorCenterTurns(_ index: Int, count: Int) -> Float {
        (Float(index) + 0.5) / Float(max(count, 1))
    }

    /// An opened entry's arc of `items` members around sector `entry` of
    /// `count`: where the first member starts and how wide each is, in turns
    /// clockwise from 12 o'clock. Each member gets the entry's share of the
    /// wheel, or `minMemberTurns` if that is wider, so the arc may overhang the
    /// neighbours.
    public static func memberArc(entry: Int, count: Int, items: Int) -> (start: Float, item: Float) {
        let n = max(items, 1)
        let item = max(1 / Float(max(count, 1)) / Float(n), minMemberTurns)
        return (sectorCenterTurns(entry, count: count) - item * Float(n) / 2, item)
    }

    /// The member under an offset on an opened entry's arc, clamped to the
    /// arc's ends (so overshooting sideways keeps the end member).
    public static func member(dx: Float, dy: Float, entry: Int, count: Int, items: Int) -> Int {
        guard items > 0 else { return -1 }
        let arc = memberArc(entry: entry, count: count, items: items)
        let half = arc.item * Float(items) / 2
        // Offset from the arc's middle, wrapped to (-0.5, 0.5].
        var rel = turns(dx: dx, dy: dy) - (arc.start + half)
        while rel > 0.5 { rel -= 1 }
        while rel <= -0.5 { rel += 1 }
        return min(items - 1, max(0, Int(((rel + half) / arc.item).rounded(.down))))
    }

    /// The armed entry's confirm hold (0…1), or nil when it needs none.
    public static func confirmProgress<Action>(
        _ entries: [RAVERadialEntry<Action>], selected: Int, armedAt: Double, now: Double
    ) -> Float? {
        guard selected >= 0, selected < entries.count else { return nil }
        let need = entries[selected].confirmSeconds
        guard need > 0 else { return nil }
        return Float(min(1, max(0, (now - armedAt) / need)))
    }

    /// The entry a release commits now, or nil: nothing armed, or its confirm
    /// hold has not run out.
    public static func commits<Action>(
        _ entries: [RAVERadialEntry<Action>], selected: Int, armedAt: Double, now: Double
    ) -> RAVERadialEntry<Action>? {
        guard selected >= 0, selected < entries.count else { return nil }
        let entry = entries[selected]
        return entry.confirmSeconds <= 0 || now - armedAt >= entry.confirmSeconds ? entry : nil
    }
}

/// The hand-driven menu: pinch to open, move, release to pick. Run once per
/// frame, on any thread.
public struct RAVERadialHandMenu<Action: Sendable & Equatable>: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Largest fingertip ↔ thumb-tip distance (m) that opens the menu.
        public var pinchEnter: Float = 0.055
        /// A spread past this (m) releases.
        public var pinchExit: Float = 0.085
        /// The middle tip ↔ metacarpal distance (m) must exceed this to open,
        /// which keeps a clenched fist out.
        public var fistGate: Float = 0.05
        /// Hand travel (m) before a sector arms.
        public var deadzone: Float = 0.04
        /// Sectors of overshoot before the armed one changes.
        public var stickiness: Float = 0.15
        /// Pushing past the rim opens an entry with several members.
        public var expand = true
        /// Past this radius (m), just outside the armed wedge, it opens.
        public var expandRadius: Float = 0.118
        /// Back inside this radius (m) it folds.
        public var collapseRadius: Float = 0.095

        public init() {}
    }

    /// Where the menu opened (the hand's position); nil while closed.
    public private(set) var anchor: SIMD3<Float>?
    public private(set) var entries: [RAVERadialEntry<Action>] = []
    public private(set) var selected = -1
    /// The armed entry is opened into its members (only ever the armed one),
    /// and which member is armed.
    public private(set) var expanded = false
    public private(set) var memberSelected = -1
    private var armedAt: Double = 0

    public init() {}

    public var isOpen: Bool { anchor != nil }

    /// How far the armed sector's confirm hold has run (0…1), or nil.
    public func confirmProgress(now: Double) -> Float? {
        RAVERadial.confirmProgress(entries, selected: selected, armedAt: armedAt, now: now)
    }

    /// What to draw, facing along the head's `right` and `up`; nil while closed.
    public func view(right: SIMD3<Float>, up: SIMD3<Float>, now: Double) -> RAVERadialView<Action>? {
        guard let anchor else { return nil }
        return RAVERadialView(
            center: anchor, right: right, up: up, entries: entries, selected: selected,
            confirm: confirmProgress(now: now),
            expansion: expanded ? .init(entry: selected, selected: memberSelected) : nil)
    }

    /// Close without picking.
    public mutating func cancel() {
        anchor = nil
        entries = []
        selected = -1
        expanded = false
        memberSelected = -1
    }

    /// Advance one frame with a tracked hand.
    ///
    /// - Parameters:
    ///   - sample: the hand, or nil when it is lost (which cancels).
    ///   - live: the gesture may run (gestures on, not swinging, no other menu).
    ///   - blocked: a competing gesture holds the hand (a trigger pull), so the
    ///     menu will not open; an open menu is not affected.
    ///   - grip: the hand's position, in the same space as `right` and `up`.
    ///   - right, up: the head's axes in that space.
    ///   - makeEntries: asked once, as the menu opens; an empty list keeps it closed.
    /// - Returns: the entry a release committed.
    @discardableResult
    public mutating func update(
        sample: RAVEHandSample?, live: Bool, blocked: Bool,
        grip: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
        now: Double, tuning: Tuning = Tuning(),
        makeEntries: () -> [RAVERadialEntry<Action>]
    ) -> RAVERadialEntry<Action>? {
        guard let sample else {
            if isOpen { cancel() }
            return nil
        }
        return update(live: live, spread: sample.fingertipSpreadToThumb,
                      middleCurl: simd_distance(sample.middle.tip, sample.middle.metacarpal),
                      blocked: blocked, grip: grip, right: right, up: up,
                      now: now, tuning: tuning, makeEntries: makeEntries)
    }

    /// The same, from measurements: `spread` is the largest fingertip ↔
    /// thumb-tip distance, `middleCurl` the middle tip ↔ metacarpal distance.
    @discardableResult
    public mutating func update(
        live: Bool, spread: Float, middleCurl: Float, blocked: Bool,
        grip: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
        now: Double, tuning: Tuning = Tuning(),
        makeEntries: () -> [RAVERadialEntry<Action>]
    ) -> RAVERadialEntry<Action>? {
        guard live else {
            if isOpen { cancel() }
            return nil
        }
        guard let anchor else {
            if spread < tuning.pinchEnter, middleCurl > tuning.fistGate, !blocked {
                let opened = makeEntries()
                if !opened.isEmpty {
                    self.anchor = grip
                    entries = opened
                    selected = -1
                }
            }
            return nil
        }
        if spread > tuning.pinchExit {
            var picked = RAVERadial.commits(entries, selected: selected, armedAt: armedAt, now: now)
            if expanded, let entry = picked, memberSelected >= 0, memberSelected < entry.members.count {
                picked = entry.members[memberSelected]
            }
            cancel()
            return picked
        }
        let offset = grip - anchor
        let dx = simd_dot(offset, right), dy = simd_dot(offset, up)
        let radius = (dx * dx + dy * dy).squareRoot()
        // Opened: the angle picks along the entry's arc until the hand comes
        // back inside the rim; the armed entry cannot change meanwhile.
        if expanded {
            if tuning.expand, radius >= tuning.collapseRadius {
                memberSelected = RAVERadial.member(dx: dx, dy: dy, entry: selected, count: entries.count,
                                                   items: entries[selected].members.count)
                return nil
            }
            expanded = false
            memberSelected = -1
        }
        let sector = RAVERadial.sector(dx: dx, dy: dy, count: entries.count, deadzone: tuning.deadzone,
                                       current: selected, stickiness: tuning.stickiness)
        if sector != selected {
            selected = sector
            armedAt = now
        }
        if tuning.expand, sector >= 0, entries[sector].members.count > 1, radius > tuning.expandRadius {
            expanded = true
            memberSelected = RAVERadial.member(dx: dx, dy: dy, entry: sector, count: entries.count,
                                               items: entries[sector].members.count)
        }
        return nil
    }
}

/// The stick-driven menu: hold a button to open, point a stick, release to pick.
/// Run once per poll, on any thread.
public struct RAVERadialStickMenu<Action: Sendable & Equatable>: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Stick deflection before a sector arms.
        public var deadzone: Float = 0.5
        public var stickiness: Float = 0.15

        public init() {}
    }

    public private(set) var isOpen = false
    public private(set) var entries: [RAVERadialEntry<Action>] = []
    public private(set) var selected = -1
    private var armedAt: Double = 0
    private var held = false

    public init() {}

    public func confirmProgress(now: Double) -> Float? {
        RAVERadial.confirmProgress(entries, selected: selected, armedAt: armedAt, now: now)
    }

    /// What to draw. A stick has no hand to anchor to, so the drawer places it
    /// at `center`, usually pinned in front of the view.
    public func view(center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                     now: Double) -> RAVERadialView<Action>? {
        guard isOpen else { return nil }
        return RAVERadialView(center: center, right: right, up: up, entries: entries, selected: selected,
                              confirm: confirmProgress(now: now), expansion: nil)
    }

    /// Close without picking. A button still held stays closed until it is
    /// pressed again.
    public mutating func cancel() {
        isOpen = false
        entries = []
        selected = -1
    }

    /// Advance one poll. `held` is the menu button (false while another menu or
    /// a console is up), `stick` the stick (x right, y up, ±1). `makeEntries`
    /// is asked once per press. Returns the entry a release committed.
    @discardableResult
    public mutating func update(
        held: Bool, stick: SIMD2<Float>, now: Double, tuning: Tuning = Tuning(),
        makeEntries: () -> [RAVERadialEntry<Action>]
    ) -> RAVERadialEntry<Action>? {
        let wasHeld = self.held
        self.held = held
        if held, !wasHeld {
            let opened = makeEntries()
            if !opened.isEmpty {
                isOpen = true
                entries = opened
                selected = -1
                armedAt = now
            }
            return nil
        }
        guard isOpen else { return nil }
        if !held {
            let picked = RAVERadial.commits(entries, selected: selected, armedAt: armedAt, now: now)
            cancel()
            return picked
        }
        if simd_length(stick) > tuning.deadzone {
            let sector = RAVERadial.sector(dx: stick.x, dy: stick.y, count: entries.count,
                                           deadzone: tuning.deadzone, current: selected,
                                           stickiness: tuning.stickiness)
            if sector != selected {
                selected = sector
                armedAt = now
            }
        }
        return nil
    }
}
