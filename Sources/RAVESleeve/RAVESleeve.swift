/*
 RAVE Engine — a sleeve: the HUD worn on a forearm.

 One value type that every host runs the same way. Per frame:

   1. `update(arm:head:now:)` with the tracked arm. It follows the arm, decides
      which face is turned to the eyes, places the current pages' tiles and
      returns a snapshot to draw.
   2. `touch(fingertip:now:)` with the other hand's index fingertip, for
      direct touch.
   3. `takeEvents()` for what the wearer did.

 Gaze and pinch does not go through here as geometry: the system (a SwiftUI
 attachment's button, or a Compositor Services tracking area carrying a tile's
 `target`) tells the host a tile was pinched, and the host calls
 `pressBegan` / `pressEnded` (or `tap`).

 **Faces replace summon gestures.** The outer face shows while the back of
 the forearm is turned to the eyes and the inner face while the palm side is,
 each with a dwell and a linger, so nothing is summoned and nothing hides the
 other. `showAllowed` is the host's veto (the hand is on a joystick, a menu is
 up).

 **Direct touch.** A tile is pressed when the fingertip comes down through it
 from above: it must first be seen hovering over that tile, then cross
 `pressHeight`. A finger that arrives from the side or from behind the arm
 presses nothing. The press lasts until the fingertip rises past
 `releaseHeight` or slides off. Tiles float `metrics.lift` off the skin and
 the fingertip joint sits inside the finger, so the press lands about when the
 finger meets the arm: the arm is the key's travel stop.

 Not thread-safe: a host that updates on a render thread and receives pinches
 on the main actor guards it with its own lock.
 */

import Foundation
import RAVEInput
import simd

public enum RAVESleeveInputSource: String, Sendable {
    /// Gaze and pinch, a pointer, a click.
    case indirect
    /// A fingertip on the tile.
    case touch
    /// The debug server, a script, another device.
    case remote
}

public struct RAVESleeveEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A button was pressed, or a hold ran out.
        case fired
        /// A toggle was pressed; the value is what it should become.
        case toggled(Bool)
        /// A slider moved.
        case value(Float)
        /// The face now shows this page.
        case page(String)
        case dock(String, open: Bool)
        case radialOpened(String)
        case radialPicked(RAVESleeveRadialEntry)
        case radialClosed
    }

    /// The tile pressed; nil for a radial pick.
    public var tile: String?
    public var action: RAVESleeveAction?
    public var kind: Kind
    public var source: RAVESleeveInputSource
}

/// A tile where it is this frame.
public struct RAVESleevePlacedTile: Sendable, Equatable {
    public var tile: RAVESleeveTile
    public var face: RAVESleeveFace
    public var state: RAVESleeveTileState
    /// Tile metres (x right, y up, +z out of the arm) to world.
    public var transform: simd_float4x4
    /// Width and height, metres.
    public var size: SIMD2<Float>
    /// For a tracking area: the tile's place in `layout.allTiles`, from 1.
    public var target: UInt64
    public var opacity: Float
    public var isPressed: Bool
    /// 0…1 as a fingertip comes down over it; 0 with none.
    public var hover: Float
    /// A hold's charge, 0…1; nil for other controls.
    public var holdProgress: Float?
    /// 1 right after it fired, fading to 0.
    public var flash: Float
}

/// An open docked panel and, for an arm mount, where it stands.
public struct RAVESleevePlacedDock: Sendable, Equatable {
    public var dock: RAVESleeveDock
    /// Panel metres (x right, y up, +z toward the reader) to world. Nil for
    /// view and world mounts, which the host places.
    public var transform: simd_float4x4?
}

public struct RAVESleeveSnapshot: Sendable {
    /// The arm's frame; nil until the arm has been seen.
    public var frame: RAVESleeveFrame?
    public var isTracked: Bool
    public var outerOpacity: Float
    public var innerOpacity: Float
    public var tiles: [RAVESleevePlacedTile]
    public var radial: RAVESleeveRadialView?
    public var docks: [RAVESleevePlacedDock]

    public var isVisible: Bool { outerOpacity > 0 || innerOpacity > 0 }
}

public struct RAVESleeve: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Facing (1 = square to the eyes) at which a face shows, and below
        /// which it hides.
        public var show: Float = 0.35
        public var hide: Float = 0.15
        public var dwell: TimeInterval = 0.08
        public var linger: TimeInterval = 0.3
        public var fadeIn: TimeInterval = 0.12
        public var fadeOut: TimeInterval = 0.18

        /// Fingertip height over a tile (m) from which it counts as hovering.
        public var hoverHeight: Float = 0.035
        /// Coming down through this presses.
        public var pressHeight: Float = 0.004
        /// Rising past this releases.
        public var releaseHeight: Float = 0.014
        /// Further behind the tile than this is not a press (a hand passing
        /// behind the arm).
        public var maxDepth: Float = 0.03
        /// How far past a pressed tile's edge the fingertip may slide.
        public var slop: Float = 0.008
        /// A press survives the fingertip going untracked this long: one
        /// hand over the other arm is where tracking drops.
        public var touchDropout: TimeInterval = 0.15
        /// After a release, the tile ignores presses this long.
        public var lockout: TimeInterval = 0.12
        public var flash: TimeInterval = 0.25
        /// A hold's charge survives a lapse this long.
        public var holdGrace: TimeInterval = 0.15

        /// How far off the tiles a radial menu floats.
        public var radialLift: Float = 0.03
        /// The gap between the arm's tiles and a docked panel's lower edge.
        public var dockStandoff: Float = 0.05

        public init() {}
    }

    public var layout: RAVESleeveLayout {
        didSet { settlePages() }
    }
    public var metrics: RAVESleeveMetrics
    public var tuning: Tuning {
        didSet { rebuildGates() }
    }
    /// What the app says about each tile now, by tile id.
    public var states: [String: RAVESleeveTileState] = [:]
    public var follower = RAVESleeveFollower()

    /// The open radial menu.
    public private(set) var radial: RAVESleeveRadial?
    public private(set) var radialID: String?
    /// Open docks, oldest first.
    public private(set) var openDocks: [String] = []

    private var page: [RAVESleeveFace: String] = [:]
    private var gates: [RAVESleeveFace: RAVEGestureGate] = [:]
    private var opacity: [RAVESleeveFace: Float] = [.outer: 0, .inner: 0]
    private var placed: [RAVESleevePlacedTile] = []
    private var lastHead = SIMD3<Float>(0, 0, 0)
    private var lastUpdate: TimeInterval?

    private struct Press { var source: RAVESleeveInputSource; var began: TimeInterval }
    private var presses: [String: Press] = [:]
    private var holds: [String: RAVEGestureGate] = [:]
    private var holdProgress: [String: Float] = [:]
    private var releasedAt: [String: TimeInterval] = [:]
    private var firedAt: [String: TimeInterval] = [:]

    /// The tile the fingertip is hovering over and may press.
    private var hovering: String?
    private var hoverAmount: Float = 0
    private var touchSeen: TimeInterval = -.infinity
    private var radialTouching = false
    private var radialFace: RAVESleeveFace = .outer

    private var events: [RAVESleeveEvent] = []

    public init(layout: RAVESleeveLayout, metrics: RAVESleeveMetrics = RAVESleeveMetrics(),
                tuning: Tuning = Tuning()) {
        self.layout = layout
        self.metrics = metrics
        self.tuning = tuning
        rebuildGates()
        settlePages()
    }

    // MARK: State

    /// The page a face shows.
    public func currentPage(_ face: RAVESleeveFace) -> RAVESleevePage? {
        let pages = layout.pages(face)
        return pages.first { $0.id == page[face] } ?? pages.first
    }

    public mutating func showPage(_ id: String, on face: RAVESleeveFace) {
        guard layout.pages(face).contains(where: { $0.id == id }) else { return }
        page[face] = id
    }

    /// What happened since the last call, oldest first.
    public mutating func takeEvents() -> [RAVESleeveEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    public mutating func setDock(_ id: String, open: Bool, source: RAVESleeveInputSource = .remote) {
        guard layout.dock(id) != nil, openDocks.contains(id) != open else { return }
        if open { openDocks.append(id) } else { openDocks.removeAll { $0 == id } }
        events.append(RAVESleeveEvent(tile: nil, action: nil, kind: .dock(id, open: open), source: source))
    }

    public mutating func closeRadial() {
        guard radial != nil else { return }
        radial = nil
        radialID = nil
        radialTouching = false
        events.append(RAVESleeveEvent(tile: nil, action: nil, kind: .radialClosed, source: .remote))
    }

    private mutating func settlePages() {
        for face in RAVESleeveFace.allCases {
            let pages = layout.pages(face)
            if !pages.contains(where: { $0.id == page[face] }) { page[face] = pages.first?.id }
        }
        let docks = Set(layout.docks.map(\.id))
        openDocks.removeAll { !docks.contains($0) }
        if let radialID, layout.radial(radialID) == nil { radial = nil; self.radialID = nil }
    }

    private mutating func rebuildGates() {
        for face in RAVESleeveFace.allCases {
            gates[face] = RAVEGestureGate(tuning: RAVEGestureGateTuning(
                sense: .rising, enter: tuning.show, exit: tuning.hide,
                holdToEngage: tuning.dwell, releaseGrace: tuning.linger))
        }
    }

    // MARK: Placing

    /// Where a page's tiles sit on a face, with no opacity or press state.
    public static func place(page: RAVESleevePage, face: RAVESleeveFace, frame: RAVESleeveFrame,
                             metrics: RAVESleeveMetrics, reading: RAVESleeveReading)
        -> [(tile: RAVESleeveTile, transform: simd_float4x4, size: SIMD2<Float>)] {
        let columns = page.columns
        guard columns > 0 else { return [] }
        let pitch = metrics.cell + metrics.gap
        let width = Float(columns) * pitch - metrics.gap
        let height = Float(page.rows.count) * pitch - metrics.gap
        let extent = reading == .watch ? width : height
        let centre = metrics.start + extent / 2
        let base = frame.tile(distance: centre, angle: face.angle, radius: metrics.radius, reading: reading)
        let right = SIMD3(base.columns.0.x, base.columns.0.y, base.columns.0.z)
        let up = SIMD3(base.columns.1.x, base.columns.1.y, base.columns.1.z)
        let tangent = frame.tangent(angle: face.angle, distance: centre)

        var result: [(RAVESleeveTile, simd_float4x4, SIMD2<Float>)] = []
        for (r, row) in page.rows.enumerated() {
            let y = height / 2 - metrics.cell / 2 - Float(r) * pitch
            var column = 0
            for tile in row {
                let w = Float(tile.span) * pitch - metrics.gap
                let x = -width / 2 + Float(column) * pitch + w / 2
                column += tile.span
                let along = x * simd_dot(right, frame.along) + y * simd_dot(up, frame.along)
                let arc = x * simd_dot(right, tangent) + y * simd_dot(up, tangent)
                let transform = frame.tile(distance: centre + along, angle: face.angle + arc / metrics.radius,
                                           radius: metrics.radius, reading: reading)
                result.append((tile, transform, SIMD2(w, metrics.cell)))
            }
        }
        return result
    }

    /// The middle of a face's current page, metres from the wrist.
    private func centreDistance(_ face: RAVESleeveFace) -> Float {
        guard let page = currentPage(face) else { return metrics.start }
        let pitch = metrics.cell + metrics.gap
        let cells = layout.reading == .watch ? page.columns : page.rows.count
        return metrics.start + (Float(cells) * pitch - metrics.gap) / 2
    }

    // MARK: Per frame

    /// One frame: follow the arm, decide the faces, place the tiles.
    /// `arm` is nil while the hand is untracked; `head` is the eye point.
    @discardableResult
    public mutating func update(arm: RAVESleeveArm?, head: SIMD3<Float>, now: TimeInterval,
                                showAllowed: Bool = true) -> RAVESleeveSnapshot {
        let dt = lastUpdate.map { max(0, min(0.1, now - $0)) } ?? 0
        lastUpdate = now
        lastHead = head
        let frame = follower.update(arm: arm, now: now)

        for face in RAVESleeveFace.allCases {
            var value: Float?
            if follower.isTracked, let frame, currentPage(face) != nil {
                value = frame.facing(angle: face.angle, distance: centreDistance(face),
                                     radius: metrics.radius, toward: head)
            }
            let shown = gates[face]?.update(value: value, now: now, engageAllowed: showAllowed,
                                            holdAllowed: showAllowed).engaged ?? false
            var o = opacity[face] ?? 0
            if shown, frame != nil {
                o = tuning.fadeIn > 0 ? min(1, o + Float(dt / tuning.fadeIn)) : 1
                if o == 0 { o = .ulpOfOne }
            } else {
                o = tuning.fadeOut > 0 ? max(0, o - Float(dt / tuning.fadeOut)) : 0
            }
            opacity[face] = o
        }

        advanceHolds(now: now)

        placed.removeAll(keepingCapacity: true)
        if let frame {
            var target: UInt64 = 0
            var targets: [String: UInt64] = [:]
            for (_, _, tile) in layout.allTiles {
                target += 1
                targets[tile.id] = target
            }
            for face in RAVESleeveFace.allCases {
                guard let o = opacity[face], o > 0, let page = currentPage(face) else { continue }
                for item in Self.place(page: page, face: face, frame: frame, metrics: metrics,
                                       reading: layout.reading) {
                    let state = states[item.tile.id] ?? RAVESleeveTileState()
                    guard !state.hidden else { continue }
                    let id = item.tile.id
                    let flash = firedAt[id].map { Float(max(0, min(1, 1 - (now - $0) / max(tuning.flash, 1e-3)))) } ?? 0
                    placed.append(RAVESleevePlacedTile(
                        tile: item.tile, face: face, state: state, transform: item.transform, size: item.size,
                        target: targets[id] ?? 0, opacity: o, isPressed: presses[id] != nil,
                        hover: hovering == id ? hoverAmount : 0, holdProgress: holdProgress[id], flash: flash))
                }
            }
            if radial != nil {
                let wheel = frame.tile(distance: centreDistance(radialFace), angle: radialFace.angle,
                                       radius: metrics.radius + tuning.radialLift, reading: layout.reading)
                radial?.transform = wheel
                if (opacity[radialFace] ?? 0) == 0 { closeRadial() }
            }
        }

        return RAVESleeveSnapshot(
            frame: frame, isTracked: follower.isTracked, outerOpacity: opacity[.outer] ?? 0,
            innerOpacity: opacity[.inner] ?? 0, tiles: placed, radial: radial?.view(now: now),
            docks: placedDocks(frame: frame, head: head))
    }

    private func placedDocks(frame: RAVESleeveFrame?, head: SIMD3<Float>) -> [RAVESleevePlacedDock] {
        var stacked: Float = 0
        return openDocks.compactMap { id in
            guard let dock = layout.dock(id) else { return nil }
            guard dock.mount == .arm, let frame else { return RAVESleevePlacedDock(dock: dock, transform: nil) }
            // Standing off the arm's edge that is uppermost to the reader,
            // its long edge along the arm, turned to the eyes.
            let right = frame.side == .left ? -frame.along : frame.along
            let middle = frame.origin + frame.along * (metrics.start + dock.width / 2)
            let normal = RAVESleeveFrame.perpendicular(head - middle, to: right) ?? frame.back
            let up = simd_cross(normal, right)
            let centre = middle + up * (metrics.radius + tuning.dockStandoff + dock.height / 2 + stacked)
            stacked += dock.height + 0.01
            return RAVESleevePlacedDock(dock: dock, transform: simd_float4x4(
                SIMD4(right, 0), SIMD4(up, 0), SIMD4(normal, 0), SIMD4(centre, 1)))
        }
    }

    // MARK: Presses

    private func tile(_ id: String) -> (face: RAVESleeveFace, tile: RAVESleeveTile)? {
        for (face, _, tile) in layout.allTiles where tile.id == id { return (face, tile) }
        return nil
    }

    private func isPressable(_ tile: RAVESleeveTile, now: TimeInterval) -> Bool {
        guard tile.control.isInteractive, radial == nil else { return false }
        let state = states[tile.id] ?? RAVESleeveTileState()
        guard !state.disabled, !state.hidden else { return false }
        if let released = releasedAt[tile.id], now - released < tuning.lockout { return false }
        return true
    }

    /// A press landed on a tile: a pinch on its target, a fingertip, a click.
    public mutating func pressBegan(_ id: String, now: TimeInterval, source: RAVESleeveInputSource = .indirect) {
        guard presses[id] == nil, let (face, tile) = tile(id), isPressable(tile, now: now) else { return }
        presses[id] = Press(source: source, began: now)
        func emit(_ kind: RAVESleeveEvent.Kind, _ action: RAVESleeveAction? = nil) {
            events.append(RAVESleeveEvent(tile: id, action: action, kind: kind, source: source))
            firedAt[id] = now
        }
        switch tile.control {
        case let .button(action):
            emit(.fired, action)
        case let .toggle(action):
            emit(.toggled(!(states[id]?.isOn ?? false)), action)
        case let .hold(_, seconds):
            holds[id] = RAVEGestureGate(tuning: .hold(seconds, chargeGrace: tuning.holdGrace))
            holdProgress[id] = 0
        case let .page(target):
            showPage(target, on: face)
            emit(.page(target))
        case let .dock(target):
            let open = !openDocks.contains(target)
            setDock(target, open: open, source: source)
            firedAt[id] = now
        case let .radial(target):
            guard let menu = layout.radial(target) else { break }
            radial = RAVESleeveRadial(menu: menu)
            radialID = target
            radialFace = face
            radialTouching = false
            presses[id] = nil
            hovering = nil
            emit(.radialOpened(target))
        case .slider, .label, .gauge, .custom:
            break
        }
    }

    public mutating func pressEnded(_ id: String, now: TimeInterval) {
        guard presses.removeValue(forKey: id) != nil else { return }
        releasedAt[id] = now
    }

    /// A press and its release at once: a pinch, a click.
    public mutating func tap(_ id: String, now: TimeInterval, source: RAVESleeveInputSource = .indirect) {
        pressBegan(id, now: now, source: source)
        pressEnded(id, now: now)
    }

    /// Move a slider to `fraction` (0…1).
    public mutating func setValue(_ id: String, fraction: Float, source: RAVESleeveInputSource = .indirect) {
        guard let (_, tile) = tile(id), case let .slider(action) = tile.control,
              !(states[id]?.disabled ?? false) else { return }
        events.append(RAVESleeveEvent(tile: id, action: action, kind: .value(max(0, min(1, fraction))),
                                      source: source))
    }

    private mutating func advanceHolds(now: TimeInterval) {
        for id in Array(holds.keys) {
            guard var gate = holds[id] else { continue }
            let out = gate.update(active: presses[id] != nil, now: now)
            holds[id] = gate
            holdProgress[id] = out.progress
            if out.began, let (_, tile) = tile(id), case let .hold(action, _) = tile.control {
                events.append(RAVESleeveEvent(tile: id, action: action, kind: .fired,
                                              source: presses[id]?.source ?? .indirect))
                firedAt[id] = now
            }
            if out.phase == .idle, presses[id] == nil {
                holds[id] = nil
                holdProgress[id] = nil
            }
        }
    }

    // MARK: Radial, indirect

    /// A pinch landed on a wedge of the open radial menu (`path` from the
    /// wedge), or on its centre (an empty path).
    public mutating func radialPress(path: [Int], now: TimeInterval) {
        radial?.press(path: path, now: now)
    }

    /// The pinch on the radial menu let go.
    public mutating func radialRelease(now: TimeInterval, source: RAVESleeveInputSource = .indirect) {
        guard let outcome = radial?.release(now: now) else { return }
        switch outcome {
        case .stay:
            break
        case .close:
            closeRadial()
        case let .pick(pick):
            radial = nil
            radialID = nil
            radialTouching = false
            events.append(RAVESleeveEvent(tile: nil, action: pick.entry.action, kind: .radialPicked(pick.entry),
                                          source: source))
        }
    }

    // MARK: Direct touch

    /// The other hand's index fingertip, after `update`. Nil when untracked.
    public mutating func touch(fingertip: SIMD3<Float>?, now: TimeInterval) {
        guard let tip = fingertip else {
            if now - touchSeen > tuning.touchDropout { liftTouch(now: now) }
            return
        }
        touchSeen = now

        if radial != nil {
            touchRadial(tip, now: now)
            return
        }

        // A tile already pressed by touch stays pressed until the fingertip
        // rises or slides off it.
        if let (id, _) = presses.first(where: { $0.value.source == .touch }) {
            guard let item = placed.first(where: { $0.tile.id == id }) else {
                pressEnded(id, now: now)
                return
            }
            let p = item.transform.inverse * SIMD4(tip, 1)
            let half = item.size / 2 + tuning.slop
            if p.z > tuning.releaseHeight || abs(p.x) > half.x || abs(p.y) > half.y {
                pressEnded(id, now: now)
            } else if case .slider = item.tile.control {
                setValue(id, fraction: p.x / item.size.x + 0.5, source: .touch)
            }
            return
        }

        // The tile under the fingertip, nearest centre first.
        var best: (item: RAVESleevePlacedTile, local: SIMD4<Float>, distance: Float)?
        for item in placed where item.opacity > 0.5 && isPressable(item.tile, now: now) {
            let p = item.transform.inverse * SIMD4(tip, 1)
            guard abs(p.x) <= item.size.x / 2, abs(p.y) <= item.size.y / 2,
                  p.z <= tuning.hoverHeight, p.z > -tuning.maxDepth else { continue }
            let d = simd_length(SIMD2(p.x, p.y))
            if best.map({ d < $0.distance }) ?? true { best = (item, p, d) }
        }
        guard let best else {
            hovering = nil
            hoverAmount = 0
            return
        }
        let id = best.item.tile.id
        if best.local.z > tuning.pressHeight {
            hovering = id
            hoverAmount = 1 - (best.local.z - tuning.pressHeight) / max(tuning.hoverHeight - tuning.pressHeight, 1e-4)
        } else if hovering == id {
            // Came down through the tile it was hovering over.
            hovering = nil
            hoverAmount = 0
            pressBegan(id, now: now, source: .touch)
            if case .slider = best.item.tile.control {
                setValue(id, fraction: best.local.x / best.item.size.x + 0.5, source: .touch)
            }
        }
    }

    private mutating func touchRadial(_ tip: SIMD3<Float>, now: TimeInterval) {
        guard var menu = radial else { return }
        let p = menu.transform.inverse * SIMD4(tip, 1)
        let local = SIMD2(p.x, p.y)
        let reach = menu.expanded ? menu.geometry.memberOuter : menu.geometry.outer
        let over = simd_length(local) <= reach + tuning.slop && p.z > -tuning.maxDepth
        if radialTouching {
            if !over || p.z > tuning.releaseHeight {
                radialTouching = false
                radialRelease(now: now, source: .touch)
            } else {
                menu.point(local: local, now: now)
                radial = menu
            }
        } else if over, p.z <= tuning.pressHeight, hovering == Self.radialHover {
            hovering = nil
            radialTouching = true
            menu.press(path: menu.hit(local: local) ?? [], now: now)
            radial = menu
        } else if over, p.z > tuning.pressHeight, p.z <= tuning.hoverHeight {
            hovering = Self.radialHover
        } else if !over {
            hovering = nil
        }
    }

    private static let radialHover = "\u{0}radial"

    /// The fingertip is gone: end what it was pressing.
    private mutating func liftTouch(now: TimeInterval) {
        hovering = nil
        hoverAmount = 0
        for (id, press) in presses where press.source == .touch { pressEnded(id, now: now) }
        if radialTouching {
            radialTouching = false
            radialRelease(now: now, source: .touch)
        }
    }
}
