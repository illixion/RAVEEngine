#if os(visionOS)
import Observation
import QuartzCore
@_exported import RAVESleeve
import RealityKit
import SwiftUI

// A sleeve (RAVESleeve) drawn in a RealityKit scene: one flat SwiftUI
// attachment per tile, tangent to the forearm, and one for an open radial
// menu. The rules (where a tile is, whether its face shows, what a press
// does) are RAVESleeve's; this file only shows a snapshot and passes presses
// back.
//
// Gaze and pinch reaches a tile through SwiftUI, as for any attachment. A
// fingertip is RAVESleeve's own (`touch(fingertip:)`), so the same press rule
// holds here and on Metal hosts; if the system also delivers the poke to the
// attachment, the sleeve ignores the second press of a tile already pressed.
//
// How a tile looks is the app's: pass `tile:` to draw them (and `.custom`
// tiles) yourself, falling back to `RAVESleeveTileView` for the rest.

/// What a tile's view reads. Leaves out the transform, so a moving arm does
/// not redraw every tile every frame.
public struct RAVESleeveTileDisplay: Equatable, Sendable {
    public var tile: RAVESleeveTile
    public var state: RAVESleeveTileState
    /// Metres.
    public var size: SIMD2<Float>
    public var isPressed: Bool
    /// 0…1 as a fingertip comes down over it, in steps.
    public var hover: Float
    public var holdProgress: Float?
    /// 1 right after it fired, fading to 0, in steps.
    public var flash: Float

    init(_ placed: RAVESleevePlacedTile) {
        tile = placed.tile
        state = placed.state
        size = placed.size
        isPressed = placed.isPressed
        hover = (placed.hover * 10).rounded() / 10
        holdProgress = placed.holdProgress.map { ($0 * 50).rounded() / 50 }
        flash = (placed.flash * 8).rounded() / 8
    }
}

@MainActor
@Observable
public final class RAVESleeveTileModel {
    public fileprivate(set) var display: RAVESleeveTileDisplay
    @ObservationIgnored fileprivate var began: (String) -> Void = { _ in }
    @ObservationIgnored fileprivate var ended: (String) -> Void = { _ in }
    @ObservationIgnored fileprivate var slid: (String, Float) -> Void = { _, _ in }

    fileprivate init(_ display: RAVESleeveTileDisplay) { self.display = display }

    /// A pinch or click landed on the tile.
    public func pressBegan() { began(display.tile.id) }
    public func pressEnded() { ended(display.tile.id) }
    /// A slider dragged to `fraction` (0…1).
    public func slide(to fraction: Float) { slid(display.tile.id, fraction) }
}

@MainActor
@Observable
public final class RAVESleeveRadialModel {
    public fileprivate(set) var wedges: [RAVESleeveRadialWedge] = []
    public fileprivate(set) var geometry = RAVESleeveRadialGeometry.touch
    public fileprivate(set) var armedLabel: String?
    @ObservationIgnored fileprivate var pressed: ([Int]) -> Void = { _ in }
    @ObservationIgnored fileprivate var released: () -> Void = {}

    fileprivate init() {}

    /// A pinch landed on a wedge (`wedge.path`), or on the centre (`[]`).
    public func press(_ path: [Int]) { pressed(path) }
    public func release() { released() }
}

/// The entities of one sleeve.
@MainActor
public final class RAVESleevePanels {
    /// Points per metre of an attachment at scale 1.
    public static let pointsPerMetre: Float = 1360

    /// Add this to the scene at the origin.
    public let root = Entity()

    /// What the tiles hang off: `root` (snapshots in world space), or the
    /// system's anchor for a forearm's wrist joint (snapshots in that
    /// joint's space). See `anchor(to:)`.
    private var container: Entity
    private var anchors: [RAVESleeveSide: Entity] = [:]
    public private(set) var anchoredSide: RAVESleeveSide?

    /// Hang the tiles off RealityKit's own anchor for that arm's
    /// `forearmWrist` joint, or (nil) off the world again.
    ///
    /// An app that poses tiles from ARKit each frame is always a few frames
    /// behind the arm: worn on a Vision Pro (2026-11-12) the sleeve trailed
    /// far enough for a rising arm to cover it. The system moves an anchored
    /// entity itself, at render time. So each tile is given its place
    /// *relative to the joint as the app last saw it* (`apply`'s
    /// `anchorFrame`), and the system carries it the rest of the way.
    ///
    /// The sleeve itself still runs in the world, from positions. That is
    /// deliberate, twice over. A joint's orientation is noisy, and a tile
    /// fixed in the joint's frame shows that noise at the end of a lever
    /// (tried: it shook on a still arm); placed from world positions, the
    /// noise in the app's reading of the joint and in the system's cancel.
    /// And a sleeve held still in the world while a finger covers the arm
    /// stays still, whatever the hidden joint is reported to be doing.
    /// The simulator has no hands, so a simulated arm stays in the world.
    public func anchor(to side: RAVESleeveSide?) {
        guard side != anchoredSide else { return }
        anchoredSide = side
        if let side {
            let anchor = anchors[side] ?? {
                let entity = AnchorEntity(.hand(side == .left ? .left : .right, location: .joint(for: .forearmWrist)),
                                          trackingMode: .predicted)
                entity.name = "RAVESleeveAnchor.\(side.rawValue)"
                root.addChild(entity)
                anchors[side] = entity
                return entity
            }()
            container = anchor
        } else {
            container = root
        }
        for id in Array(items.keys) {
            guard var item = items[id] else { continue }
            container.addChild(item.holder)
            item.transform = nil
            item.settling = 90
            items[id] = item
        }
        if let radialHolder { container.addChild(radialHolder) }
    }

    public var onPressBegan: ((String) -> Void)?
    public var onPressEnded: ((String) -> Void)?
    public var onSlide: ((String, Float) -> Void)?
    public var onRadialPress: (([Int]) -> Void)?
    public var onRadialRelease: (() -> Void)?

    private struct Item {
        let holder: Entity
        let content: Entity
        let model: RAVESleeveTileModel
        /// What the holder was last given, so an unchanged tile is not sent
        /// to the renderer again every frame.
        var transform: simd_float4x4?
        var opacity: Float = -1
        /// Frames left in which the transform is set regardless: an
        /// attachment is put in a window only by a transform change made
        /// after it is in the scene (see `RAVEPanel.tick`).
        var settling = 90
    }

    private var items: [String: Item] = [:]
    private let makeTile: (RAVESleeveTileModel) -> AnyView
    private let radialModel = RAVESleeveRadialModel()
    private var radialHolder: Entity?
    private let makeRadial: (RAVESleeveRadialModel) -> AnyView

    /// - Parameters:
    ///   - tile: draws a tile; nil for `RAVESleeveTileView`.
    ///   - radial: draws an open radial menu; nil for `RAVESleeveRadialWheel`.
    public init(tile: ((RAVESleeveTileModel) -> AnyView)? = nil,
                radial: ((RAVESleeveRadialModel) -> AnyView)? = nil) {
        container = root
        root.name = "RAVESleeve"
        makeTile = tile ?? { AnyView(RAVESleeveTileView(model: $0)) }
        makeRadial = radial ?? { AnyView(RAVESleeveRadialWheel(model: $0)) }
        radialModel.pressed = { [weak self] in self?.onRadialPress?($0) }
        radialModel.released = { [weak self] in self?.onRadialRelease?() }
    }

    /// Show a snapshot (in world space): once a frame, after
    /// `RAVESleeve.update`. While anchored, `anchorFrame` is the joint's
    /// frame in the world as RealityKit has it, from the same hand sample the
    /// snapshot came from; without one the tiles keep their last place on
    /// the anchor (the hand is lost and they are fading).
    public func apply(_ snapshot: RAVESleeveSnapshot, anchorFrame: simd_float4x4? = nil) {
        let toContainer = anchoredSide == nil ? matrix_identity_float4x4 : anchorFrame?.inverse
        var live = Set<String>()
        for placed in snapshot.tiles {
            let id = placed.tile.id
            live.insert(id)
            let display = RAVESleeveTileDisplay(placed)
            var item = items[id] ?? make(id, display)
            if item.model.display != display { item.model.display = display }
            if !item.holder.isEnabled {
                item.holder.isEnabled = true
                item.settling = 90
            }
            // Anchored to the wrist a tile's transform barely changes, and
            // re-sending five attachments' transforms and opacities every
            // frame is work for a renderer that is already short of time.
            if let toContainer {
                let local = toContainer * placed.transform
                if item.settling > 0 || item.transform.map({ !Self.close($0, local) }) ?? true {
                    item.holder.setTransformMatrix(local, relativeTo: container)
                    item.transform = local
                    item.settling = max(0, item.settling - 1)
                }
            }
            if abs(item.opacity - placed.opacity) > 0.004 {
                // Fully shown, a tile carries no opacity component: one at 1
                // still has the renderer composite the tile through an
                // offscreen pass every frame.
                if placed.opacity >= 0.999 {
                    item.holder.components.remove(OpacityComponent.self)
                } else {
                    item.holder.components.set(OpacityComponent(opacity: placed.opacity))
                }
                item.opacity = placed.opacity
            }
            Self.fit(item.content, width: placed.size.x)
            items[id] = item
        }
        for (id, item) in items where !live.contains(id) && item.holder.isEnabled {
            item.holder.isEnabled = false
        }

        if let view = snapshot.radial {
            let holder = radialHolder ?? makeRadialHolder()
            if radialModel.wedges != view.wedges { radialModel.wedges = view.wedges }
            if radialModel.geometry != view.geometry { radialModel.geometry = view.geometry }
            if radialModel.armedLabel != view.armedLabel { radialModel.armedLabel = view.armedLabel }
            holder.isEnabled = true
            if let toContainer { holder.setTransformMatrix(toContainer * view.transform, relativeTo: container) }
            if let content = holder.children.first { Self.fit(content, width: view.geometry.memberOuter * 2) }
        } else if radialHolder?.isEnabled == true {
            radialHolder?.isEnabled = false
        }
    }

    /// Whether two transforms differ by less than a renderer could show:
    /// a twentieth of a millimetre, a hundredth of a degree or so.
    private static func close(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        simd_distance(a.columns.3, b.columns.3) < 0.00005
            && simd_distance(a.columns.0, b.columns.0) < 0.0003
            && simd_distance(a.columns.1, b.columns.1) < 0.0003
    }

    /// How many of the shown tiles SwiftUI has laid out (an attachment has
    /// no extent until it is in a window). For diagnostics.
    public var laidOutTileCount: Int {
        items.values.filter { $0.holder.isEnabled
            && ($0.content.components[ViewAttachmentComponent.self]?.bounds.extents.x ?? 0) > 0 }.count
    }

    /// Scales an attachment so its laid-out width is `width` metres.
    private static func fit(_ content: Entity, width: Float) {
        let natural = content.components[ViewAttachmentComponent.self]?.bounds.extents.x ?? 0
        let scale = natural > 0 ? width / natural : 1
        if abs(content.scale.x - scale) > 1e-4 { content.scale = SIMD3(repeating: scale) }
    }

    private func make(_ id: String, _ display: RAVESleeveTileDisplay) -> Item {
        let model = RAVESleeveTileModel(display)
        model.began = { [weak self] in self?.onPressBegan?($0) }
        model.ended = { [weak self] in self?.onPressEnded?($0) }
        model.slid = { [weak self] in self?.onSlide?($0, $1) }
        let holder = Entity()
        holder.name = "RAVESleeveTile.\(id)"
        let content = Entity()
        content.components.set(ViewAttachmentComponent(rootView: makeTile(model)))
        holder.addChild(content)
        container.addChild(holder)
        let item = Item(holder: holder, content: content, model: model)
        items[id] = item
        return item
    }

    private func makeRadialHolder() -> Entity {
        let holder = Entity()
        holder.name = "RAVESleeveRadial"
        let content = Entity()
        content.components.set(ViewAttachmentComponent(rootView: makeRadial(radialModel)))
        holder.addChild(content)
        container.addChild(holder)
        radialHolder = holder
        return holder
    }
}

/// A sleeve and its entities, wired together: what a RealityKit app holds.
@MainActor
public final class RAVESleeveHost {
    public var sleeve: RAVESleeve
    public let panels: RAVESleevePanels
    /// The last frame shown, for placing docked panels (`snapshot.docks`).
    public private(set) var snapshot: RAVESleeveSnapshot?

    public var root: Entity { panels.root }

    public init(layout: RAVESleeveLayout, metrics: RAVESleeveMetrics = RAVESleeveMetrics(),
                tuning: RAVESleeve.Tuning = RAVESleeve.Tuning(),
                tile: ((RAVESleeveTileModel) -> AnyView)? = nil,
                radial: ((RAVESleeveRadialModel) -> AnyView)? = nil) {
        sleeve = RAVESleeve(layout: layout, metrics: metrics, tuning: tuning)
        panels = RAVESleevePanels(tile: tile, radial: radial)
        panels.onPressBegan = { [weak self] in self?.sleeve.pressBegan($0, now: CACurrentMediaTime()) }
        panels.onPressEnded = { [weak self] in self?.sleeve.pressEnded($0, now: CACurrentMediaTime()) }
        panels.onSlide = { [weak self] in self?.sleeve.setValue($0, fraction: $1) }
        panels.onRadialPress = { [weak self] in self?.sleeve.radialPress(path: $0, now: CACurrentMediaTime()) }
        panels.onRadialRelease = { [weak self] in self?.sleeve.radialRelease(now: CACurrentMediaTime()) }
    }

    /// One frame, in world space. `arm` is the arm the sleeve is on,
    /// `fingertip` the other hand's index tip, `head` the eye point. Returns
    /// what the wearer did.
    ///
    /// With `anchorFrame` (the worn arm's wrist joint in the world, as
    /// RealityKit frames it), the tiles hang off the system's anchor for
    /// that joint and follow the arm at render time; see
    /// `RAVESleevePanels.anchor(to:)`. Without, they are posed in the world.
    @discardableResult
    public func update(arm: RAVESleeveArm?, head: SIMD3<Float>, fingertip: SIMD3<Float>?,
                       now: TimeInterval = CACurrentMediaTime(), showAllowed: Bool = true,
                       anchorFrame: simd_float4x4? = nil) -> [RAVESleeveEvent] {
        if let arm { panels.anchor(to: anchorFrame == nil ? nil : arm.side) }
        let frame = sleeve.update(arm: arm, head: head, now: now, showAllowed: showAllowed)
        sleeve.touch(fingertip: fingertip, now: now)
        panels.apply(frame, anchorFrame: anchorFrame)
        snapshot = frame
        return sleeve.takeEvents()
    }
}

public extension RAVEPanel {
    /// Stand beside the arm as a sleeve's docked panel; hidden while the
    /// sleeve has no pose for it.
    func follow(_ dock: RAVESleevePlacedDock?) {
        guard let transform = dock?.transform else {
            opacity = 0
            return
        }
        opacity = 1
        root.setTransformMatrix(transform, relativeTo: nil)
    }
}

// MARK: - Default drawing

/// The plain look of a tile. An app that wants its own passes a `tile:`
/// builder and uses this for the controls it does not restyle.
public struct RAVESleeveTileView: View {
    let model: RAVESleeveTileModel

    public init(model: RAVESleeveTileModel) { self.model = model }

    private var tint: Color {
        switch model.display.tile.role {
        case .normal: return .white
        case .primary: return .accentColor
        case .destructive: return .red
        }
    }

    public var body: some View {
        let d = model.display
        let ppm = CGFloat(RAVESleevePanels.pointsPerMetre)
        let width = CGFloat(d.size.x) * ppm, height = CGFloat(d.size.y) * ppm
        let shape = RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        let lit = d.state.isOn || d.isPressed
        ZStack {
            // A plain fill, not a material: a material is a live blur of
            // what is behind each tile, redrawn every frame, and five of them
            // on a moving arm broke up into blocks once the headset was hot
            // and short of frames (worn 2026-11-12).
            shape.fill(Color(white: 0.12).opacity(0.72))
            shape.fill(tint.opacity(lit ? 0.45 : (d.tile.role == .normal ? 0 : 0.18)))
            shape.fill(.white.opacity(Double(d.flash) * 0.45))
            shape.strokeBorder(tint.opacity(0.25 + Double(d.hover) * 0.6), lineWidth: 1 + CGFloat(d.hover) * 2)
            content(d, width: width, height: height)
                .padding(height * 0.1)
            if let progress = d.holdProgress, progress > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(tint, style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(height * 0.08)
            }
        }
        .frame(width: width, height: height)
        .opacity(d.state.disabled ? 0.35 : 1)
        .contentShape(.hoverEffect, shape)
        .hoverEffect(isEnabled: d.tile.control.isInteractive && !d.state.disabled)
        .gesture(press(d, width: width), isEnabled: d.tile.control.isInteractive && !d.state.disabled)
        .accessibilityLabel(d.state.text ?? d.tile.label ?? d.tile.id)
    }

    private func press(_ d: RAVESleeveTileDisplay, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !d.isPressed { model.pressBegan() }
                if case .slider = d.tile.control { model.slide(to: Float(value.location.x / max(width, 1))) }
            }
            .onEnded { _ in model.pressEnded() }
    }

    @ViewBuilder
    private func content(_ d: RAVESleeveTileDisplay, width: CGFloat, height: CGFloat) -> some View {
        let text = d.state.text ?? d.tile.label
        switch d.tile.control {
        case .gauge, .slider:
            VStack(spacing: height * 0.08) {
                if let text {
                    Text(text).font(.system(size: height * 0.24, weight: .semibold)).lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(d.state.warn ? Color.red : tint.opacity(0.9))
                            .frame(width: proxy.size.width * CGFloat(max(0, min(1, d.state.fraction))))
                    }
                }
                .frame(height: height * 0.16)
            }
        default:
            VStack(spacing: height * 0.05) {
                if let icon = d.tile.icon {
                    Image(systemName: icon).font(.system(size: height * (text == nil ? 0.42 : 0.32), weight: .semibold))
                }
                if let text, d.tile.icon == nil || width > height * 1.5 || d.state.text != nil {
                    Text(text).font(.system(size: height * 0.2, weight: .semibold)).lineLimit(2)
                        .multilineTextAlignment(.center).minimumScaleFactor(0.6)
                }
            }
        }
    }
}

/// One wedge of a wheel: turns clockwise from 12 o'clock, radii in points.
private struct RAVESleeveWedgeShape: Shape, InsettableShape {
    var start: CGFloat, end: CGFloat, inner: CGFloat, outer: CGFloat
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> RAVESleeveWedgeShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let r0 = inner + inset, r1 = max(r0, outer - inset)
        // Keep the same gap between wedges at both radii.
        let pad0 = Angle(radians: Double(inset / max(r0, 1))), pad1 = Angle(radians: Double(inset / max(r1, 1)))
        let a0 = Angle(degrees: Double(start) * 360 - 90), a1 = Angle(degrees: Double(end) * 360 - 90)
        var path = Path()
        path.addArc(center: centre, radius: r1, startAngle: a0 + pad1, endAngle: a1 - pad1, clockwise: false)
        path.addArc(center: centre, radius: r0, startAngle: a1 - pad0, endAngle: a0 + pad0, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The plain look of an open radial menu.
public struct RAVESleeveRadialWheel: View {
    let model: RAVESleeveRadialModel

    public init(model: RAVESleeveRadialModel) { self.model = model }

    public var body: some View {
        let ppm = CGFloat(RAVESleevePanels.pointsPerMetre)
        let side = CGFloat(model.geometry.memberOuter) * 2 * ppm
        ZStack {
            ForEach(model.wedges, id: \.path) { wedge in
                let shape = RAVESleeveWedgeShape(
                    start: CGFloat(wedge.startTurns), end: CGFloat(wedge.endTurns),
                    inner: CGFloat(wedge.innerRadius) * ppm, outer: CGFloat(wedge.outerRadius) * ppm, inset: 2)
                let tint: Color = wedge.entry.role == .destructive ? .red : .accentColor
                ZStack {
                    shape.fill(Color(white: 0.12).opacity(0.72))
                    shape.fill(tint.opacity(wedge.isArmed ? 0.5 : 0.08))
                    if let confirm = wedge.confirm {
                        shape.fill(.white.opacity(Double(confirm) * 0.35))
                    }
                    label(wedge.entry, size: CGFloat(wedge.outerRadius - wedge.innerRadius) * ppm)
                        .offset(x: CGFloat(wedge.center.x) * ppm, y: -CGFloat(wedge.center.y) * ppm)
                }
                .contentShape(.interaction, shape)
                .contentShape(.hoverEffect, shape)
                .hoverEffect()
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !wedge.isArmed { model.press(wedge.path) } }
                    .onEnded { _ in model.release() })
                .accessibilityLabel(wedge.entry.label)
            }
            let hub = CGFloat(model.geometry.inner) * 2 * ppm
            ZStack {
                Circle().fill(Color(white: 0.12).opacity(0.72))
                if let label = model.armedLabel {
                    Text(label).font(.system(size: hub * 0.2, weight: .semibold)).lineLimit(2)
                        .multilineTextAlignment(.center).minimumScaleFactor(0.5).padding(hub * 0.1)
                } else {
                    Image(systemName: "xmark").font(.system(size: hub * 0.3, weight: .semibold))
                }
            }
            .frame(width: hub - 4, height: hub - 4)
            .contentShape(.hoverEffect, Circle())
            .hoverEffect()
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.press([]) }
                .onEnded { _ in model.release() })
            .accessibilityLabel("Close")
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private func label(_ entry: RAVESleeveRadialEntry, size: CGFloat) -> some View {
        if let icon = entry.icon {
            Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold))
        } else {
            Text(entry.label).font(.system(size: size * 0.2, weight: .semibold)).lineLimit(2)
                .multilineTextAlignment(.center).frame(width: size * 1.1)
        }
    }
}
#endif
