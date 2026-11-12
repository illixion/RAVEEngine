/*
 RAVE Engine — a radial menu every input can drive.

 `RAVERadialMenu` (RAVEInput) holds the sector maths and two drivers that each
 own one way in: a four-finger pinch and travel, or a button and a stick. This
 is the menu built over the same maths with the way in taken out, so one open
 menu answers to all of them at once:

 - **travel**: a hand (or a held pinch) moves from the centre toward a wedge
   and a release picks it: `point(world:)` each frame, then `release`;
 - **a stick**: `stick(_:)`, then `release`;
 - **gaze and pinch**: the wedges are targets; a pinch on one is
   `press(path:)` then `release`;
 - **direct touch**: a fingertip on a wedge is `point(local:)` while it
   touches (sliding re-arms) and `release` when it lifts.

 Entries are data (`RAVESleeveRadialMenu`), so a menu can come from a sleeve
 layout or be built by a game each time it opens. What opens it is the
 caller's: a sleeve tile, a gesture, a button.

 The menu is flat: `transform` puts its centre and plane in the world (x
 right, y up, +z toward the reader), and `view` lists the wedges to draw and to
 register as targets. Value type, time passed in, so it runs on a render thread.

 **Picking rules** are RAVERadial's: a wedge stays armed until the pointer is
 clearly inside a neighbour; an entry with `confirmSeconds` must stay armed
 that long before a release picks it; an entry with several members opens into
 an outer arc when the pointer pushes past the rim (or when it is pressed),
 and a release then picks the armed member. A release at the centre, or with
 nothing armed, closes the menu without a pick.
 */

import Foundation
import RAVEInput
import simd

/// Radii of the wheel, metres.
public struct RAVESleeveRadialGeometry: Sendable, Equatable {
    /// Inside this nothing is armed.
    public var inner: Float
    /// The rim of the wedges.
    public var outer: Float
    /// The rim of an opened entry's arc of members.
    public var memberOuter: Float
    /// Back inside this an opened arc folds.
    public var collapse: Float

    public init(inner: Float, outer: Float, memberOuter: Float, collapse: Float? = nil) {
        self.inner = inner
        self.outer = outer
        self.memberOuter = memberOuter
        self.collapse = collapse ?? outer * 0.82
    }

    /// Sized to be touched or looked at: a 12 cm wheel.
    public static let touch = RAVESleeveRadialGeometry(inner: 0.02, outer: 0.06, memberOuter: 0.094)
    /// Sized for a hand travelling from where it opened: LambdaVision's
    /// thresholds (4 cm before a wedge arms, 11.8 cm to open an entry).
    public static let travel = RAVESleeveRadialGeometry(inner: 0.04, outer: 0.118, memberOuter: 0.17,
                                                        collapse: 0.095)
}

/// What a release picked.
public struct RAVESleeveRadialPick: Sendable, Equatable {
    public var entry: RAVESleeveRadialEntry
    /// The entry's index, then its member's when it came from an opened arc.
    public var path: [Int]
}

/// One wedge to draw and to register as a target.
public struct RAVESleeveRadialWedge: Sendable, Equatable {
    public var entry: RAVESleeveRadialEntry
    public var path: [Int]
    /// Clockwise turns from 12 o'clock.
    public var startTurns: Float
    public var endTurns: Float
    public var innerRadius: Float
    public var outerRadius: Float
    public var isArmed: Bool
    /// The confirm hold of an armed wedge, 0…1; nil when it needs none.
    public var confirm: Float?
    /// For a tracking area: the wedge's index in `view.wedges`, from 1.
    public var target: UInt64

    /// The middle of the wedge, menu metres (x right, y up).
    public var center: SIMD2<Float> {
        let turns = (startTurns + endTurns) / 2 * 2 * .pi
        let r = (innerRadius + outerRadius) / 2
        return SIMD2(sin(turns) * r, cos(turns) * r)
    }
}

public struct RAVESleeveRadialView: Sendable, Equatable {
    public var transform: simd_float4x4
    public var geometry: RAVESleeveRadialGeometry
    public var wedges: [RAVESleeveRadialWedge]
    /// The armed entry's label, for the centre.
    public var armedLabel: String?
}

public struct RAVESleeveRadial: Sendable {
    public var menu: RAVESleeveRadialMenu
    public var geometry: RAVESleeveRadialGeometry
    /// Centre and plane of the wheel in the world.
    public var transform: simd_float4x4
    /// Sectors of overshoot before the armed wedge changes.
    public var stickiness: Float = 0.15
    /// Stick deflection before a wedge arms.
    public var stickDeadzone: Float = 0.5

    /// The armed entry, or -1.
    public private(set) var armed = -1
    /// The armed entry is opened into its members, and which one is armed.
    public private(set) var expanded = false
    public private(set) var member = -1
    private var armedAt: TimeInterval = 0

    public init(menu: RAVESleeveRadialMenu, geometry: RAVESleeveRadialGeometry = .touch,
                transform: simd_float4x4 = matrix_identity_float4x4) {
        self.menu = menu
        self.geometry = geometry
        self.transform = transform
    }

    private var count: Int { menu.entries.count }

    private mutating func arm(_ index: Int, now: TimeInterval) {
        if index != armed {
            armed = index
            armedAt = now
            expanded = false
            member = -1
        }
    }

    // MARK: Pointing

    /// A pointer at `local` (menu metres, x right, y up): a hand's travel, a
    /// fingertip on the wheel. Nil leaves what is armed alone.
    public mutating func point(local: SIMD2<Float>?, now: TimeInterval) {
        guard let local, count > 0 else { return }
        let radius = simd_length(local)
        if expanded, armed >= 0 {
            if radius >= geometry.collapse {
                member = RAVERadial.member(dx: local.x, dy: local.y, entry: armed, count: count,
                                           items: menu.entries[armed].members.count)
                return
            }
            expanded = false
            member = -1
        }
        arm(RAVERadial.sector(dx: local.x, dy: local.y, count: count, deadzone: geometry.inner,
                              current: armed, stickiness: stickiness), now: now)
        if armed >= 0, menu.entries[armed].members.count > 1, radius > geometry.outer {
            expanded = true
            member = RAVERadial.member(dx: local.x, dy: local.y, entry: armed, count: count,
                                       items: menu.entries[armed].members.count)
        }
    }

    /// The same from a world point, dropped onto the wheel's plane. Returns
    /// the point's height off the plane (metres toward the reader).
    @discardableResult
    public mutating func point(world: SIMD3<Float>, now: TimeInterval) -> Float {
        let local = transform.inverse * SIMD4(world, 1)
        point(local: SIMD2(local.x, local.y), now: now)
        return local.z
    }

    /// A stick (x right, y up, ±1). A wedge stays armed when the stick
    /// springs back, so flick and release works. A stick never opens an arc.
    public mutating func stick(_ stick: SIMD2<Float>, now: TimeInterval) {
        guard count > 0, simd_length(stick) > stickDeadzone else { return }
        arm(RAVERadial.sector(dx: stick.x, dy: stick.y, count: count, deadzone: stickDeadzone,
                              current: armed, stickiness: stickiness), now: now)
    }

    /// A pinch or a touch landed on a wedge (`path` from `hit` or a wedge).
    /// An entry with several members opens; an empty path is the centre and
    /// disarms, so the release that follows closes the menu.
    public mutating func press(path: [Int], now: TimeInterval) {
        guard let first = path.first, first >= 0, first < count else {
            armed = -1
            expanded = false
            member = -1
            return
        }
        arm(first, now: now)
        let members = menu.entries[first].members
        if path.count > 1, path[1] >= 0, path[1] < members.count {
            expanded = true
            member = path[1]
        } else if members.count > 1 {
            expanded = true
            member = -1
        }
    }

    // MARK: Releasing

    /// What a release would do now.
    public enum Outcome: Sendable, Equatable {
        /// Nothing armed: the menu closes.
        case close
        /// An entry was opened by a press and no member is armed, or a confirm
        /// hold has not run out: the menu stays.
        case stay
        case pick(RAVESleeveRadialPick)
    }

    public func outcome(now: TimeInterval) -> Outcome {
        guard armed >= 0, armed < count else { return .close }
        let entry = menu.entries[armed]
        if expanded {
            guard member >= 0, member < entry.members.count else { return .stay }
            let picked = entry.members[member]
            return now - armedAt >= max(entry.confirmSeconds, picked.confirmSeconds)
                ? .pick(RAVESleeveRadialPick(entry: picked, path: [armed, member])) : .stay
        }
        return now - armedAt >= entry.confirmSeconds
            ? .pick(RAVESleeveRadialPick(entry: entry, path: [armed])) : .stay
    }

    /// The pinch, button or fingertip let go. Returns the outcome; on `.stay`
    /// the menu keeps its state for the next press.
    @discardableResult
    public mutating func release(now: TimeInterval) -> Outcome {
        let result = outcome(now: now)
        if case .stay = result, !expanded {
            // A confirm hold let go early: start it over.
            armed = -1
        }
        return result
    }

    // MARK: Drawing and targets

    /// The path of the wedge under a menu point: `[]` at the centre, nil
    /// outside the wheel.
    public func hit(local: SIMD2<Float>) -> [Int]? {
        let radius = simd_length(local)
        if radius < geometry.inner { return [] }
        guard count > 0 else { return nil }
        if radius <= geometry.outer {
            return [RAVERadial.sector(dx: local.x, dy: local.y, count: count, deadzone: geometry.inner)]
        }
        guard expanded, armed >= 0, radius <= geometry.memberOuter else { return nil }
        let items = menu.entries[armed].members.count
        let arc = RAVERadial.memberArc(entry: armed, count: count, items: items)
        var rel = RAVERadial.turns(dx: local.x, dy: local.y) - arc.start
        while rel < 0 { rel += 1 }
        while rel >= 1 { rel -= 1 }
        guard rel < arc.item * Float(items) else { return nil }
        return [armed, min(items - 1, Int(rel / arc.item))]
    }

    public func view(now: TimeInterval) -> RAVESleeveRadialView {
        var wedges: [RAVESleeveRadialWedge] = []
        for (i, entry) in menu.entries.enumerated() {
            let isArmed = i == armed
            let confirm: Float? = isArmed && entry.confirmSeconds > 0
                ? Float(min(1, max(0, (now - armedAt) / entry.confirmSeconds))) : nil
            wedges.append(RAVESleeveRadialWedge(
                entry: entry, path: [i], startTurns: Float(i) / Float(count),
                endTurns: Float(i + 1) / Float(count), innerRadius: geometry.inner,
                outerRadius: geometry.outer, isArmed: isArmed && !expanded, confirm: confirm, target: 0))
        }
        if expanded, armed >= 0, armed < count {
            let members = menu.entries[armed].members
            let arc = RAVERadial.memberArc(entry: armed, count: count, items: members.count)
            for (j, entry) in members.enumerated() {
                wedges.append(RAVESleeveRadialWedge(
                    entry: entry, path: [armed, j], startTurns: arc.start + arc.item * Float(j),
                    endTurns: arc.start + arc.item * Float(j + 1), innerRadius: geometry.outer,
                    outerRadius: geometry.memberOuter, isArmed: j == member, confirm: nil, target: 0))
            }
        }
        for i in wedges.indices { wedges[i].target = UInt64(i + 1) }
        let label: String?
        if armed >= 0, armed < count {
            let entry = menu.entries[armed]
            label = expanded && member >= 0 && member < entry.members.count ? entry.members[member].label : entry.label
        } else {
            label = nil
        }
        return RAVESleeveRadialView(transform: transform, geometry: geometry, wedges: wedges, armedLabel: label)
    }
}
