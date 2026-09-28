#if os(visionOS)
import RAVEInput
import RealityKit
import SwiftUI
import UIKit

/// Any SwiftUI view as a panel in a RealityKit scene: the attachment, its
/// size in metres, optional chrome (grab bar, resize corner, close button),
/// and the moves every host wants. It is placed in the world, held over a
/// palm (`follow(_:)` with a `RAVEPalmAnchor`), or floated ahead of the
/// viewer (`follow(_:)` with a `RAVEPanelHeadFollow`). `visibility` says
/// whether anyone can see it, which is what an app pauses content on.
///
/// Content-agnostic on purpose: it never names a web view. An app puts a
/// browser (RAVESDK's `RAVEWebViewHost`) or anything else inside.
///
/// Call `tick(viewer:)` once a frame from the scene's update. It
/// carries the hosting fix below, keeps the content scaled to the panel's
/// width once SwiftUI has laid it out, and advances `visibility`.
@MainActor
public final class RAVEPanel {
    public struct Chrome: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let grabBar = Chrome(rawValue: 1)
        public static let resizeHandle = Chrome(rawValue: 2)
        public static let closeButton = Chrome(rawValue: 4)
        public static let all: Chrome = [.grabBar, .resizeHandle, .closeButton]
    }

    public enum Part: Sendable { case grabBar, resizeHandle, closeButton }

    /// Move, rotate and parent this. Its origin is the panel's centre, and
    /// the content faces its +Z.
    public let root: Entity
    /// Holds the `ViewAttachmentComponent`, scaled to `size.x`.
    public let content: Entity

    /// Width and height in metres. The content is scaled to the width; the
    /// height places the chrome and sizes the view test, so keep it to the
    /// content's shape (see `fitHeightToContent`).
    public private(set) var size: SIMD2<Float>
    public var widthRange: ClosedRange<Float> = 0.05...6
    public var heightRange: ClosedRange<Float> = 0.05...4
    /// When true, `size.y` follows the content's laid-out aspect, for a
    /// panel whose content decides its own height (a HUD, a chat column).
    public var fitHeightToContent = false

    /// Whether anyone can see the panel; advanced by `tick`.
    public var visibility = RAVEPanelVisibility()
    /// Whether its content should be running this frame: `visibility`'s
    /// verdict as of the last `tick`.
    public var isRunning: Bool { visibility.isRunning }

    /// Whether the content has been put in a window yet, when the host can
    /// tell (a `UIView` inside it: `view.window != nil`). Without it the
    /// hosting fix runs for a fixed number of frames after each show.
    public var isHosted: (() -> Bool)?

    private var handles: [Part: ModelEntity] = [:]
    private var laidOutNaturalSize: SIMD2<Float> = .zero
    private var rehostFrames = 0
    private var dragStart: (position: SIMD3<Float>, size: SIMD2<Float>)?
    private var available = true

    public init(name: String = "RAVEPanel", size: SIMD2<Float>, chrome: Chrome = [],
                @ViewBuilder content view: () -> some View) {
        root = Entity()
        root.name = name
        content = Entity()
        content.components.set(ViewAttachmentComponent(rootView: view()))
        root.addChild(content)
        self.size = size
        if chrome.contains(.grabBar) {
            handles[.grabBar] = Self.handle(
                mesh: .generateBox(width: 0.16, height: 0.016, depth: 0.006, cornerRadius: 0.008),
                hitSize: [0.26, 0.06, 0.04], color: .init(white: 0.92, alpha: 1))
        }
        if chrome.contains(.resizeHandle) {
            handles[.resizeHandle] = Self.handle(
                mesh: .generateSphere(radius: 0.012), hitSize: [0.06, 0.06, 0.04], color: .init(white: 0.92, alpha: 1))
        }
        if chrome.contains(.closeButton) {
            handles[.closeButton] = Self.handle(
                mesh: .generateSphere(radius: 0.012), hitSize: [0.05, 0.05, 0.04], color: .init(white: 0.55, alpha: 1))
        }
        for handle in handles.values { root.addChild(handle) }
        layout()
    }

    // MARK: - In the scene

    public var isShown: Bool { root.parent != nil }

    public func add(to parent: Entity) {
        guard root.parent !== parent else { return }
        parent.addChild(root)
        startRehosting()
    }

    public func remove() {
        root.removeFromParent()
    }

    public var isEnabled: Bool {
        get { root.isEnabled }
        set {
            guard root.isEnabled != newValue else { return }
            root.isEnabled = newValue
            if newValue { startRehosting() }
        }
    }

    /// Set by the app for anything else that makes the panel unseeable, such
    /// as its immersive space going to the background (a call).
    public var isAvailable: Bool {
        get { available }
        set { available = newValue }
    }

    /// 0…1 through an `OpacityComponent`. At 0 the panel is disabled, so a
    /// faded-out panel costs nothing and takes no input.
    public var opacity: Float = 1 {
        didSet {
            root.components.set(OpacityComponent(opacity: opacity))
            isEnabled = opacity > 0
        }
    }

    /// Once a frame.
    public func tick(viewer: RAVEPanelViewer?, now: TimeInterval = CACurrentMediaTime()) {
        let showing = available && isShown && root.isEnabled
        visibility.update(available: showing, center: root.position(relativeTo: nil),
                          size: size, viewer: viewer, now: now)
        guard showing else { return }
        // RealityKit puts an attachment's view into a window only when the
        // entity's transform changes while it is already in the scene. A
        // placement in the same turn as the add leaves a UIViewRepresentable
        // inside at 0×0 in no window: blank until something moves it
        // (measured on the AVP, 2026-09-28). Re-setting the same transform in
        // a later frame counts, so nothing visibly moves.
        if rehostFrames > 0 {
            if isHosted?() == true {
                rehostFrames = 0
            } else {
                rehostFrames -= 1
                root.setTransformMatrix(root.transformMatrix(relativeTo: nil), relativeTo: nil)
            }
        }
        if naturalSize != laidOutNaturalSize { layout() }
    }

    private func startRehosting() {
        // With a probe, until it says so (bounded, in case it never does);
        // without one, a second's worth of frames.
        rehostFrames = isHosted == nil ? 90 : 180
    }

    // MARK: - Size

    /// The attachment's own extent, before scaling; zero until laid out.
    public var naturalSize: SIMD2<Float> {
        let extents = content.components[ViewAttachmentComponent.self]?.bounds.extents ?? .zero
        return SIMD2(extents.x, extents.y)
    }

    public func setSize(_ newSize: SIMD2<Float>) {
        size = SIMD2(min(max(newSize.x, widthRange.lowerBound), widthRange.upperBound),
                     min(max(newSize.y, heightRange.lowerBound), heightRange.upperBound))
        layout()
    }

    /// Scales the content to the width and puts the chrome round its edge.
    private func layout() {
        let natural = naturalSize
        laidOutNaturalSize = natural
        if natural.x > 0 {
            content.scale = SIMD3(repeating: size.x / natural.x)
            if fitHeightToContent, natural.y > 0 {
                size.y = min(max(size.x * natural.y / natural.x, heightRange.lowerBound), heightRange.upperBound)
            }
        }
        let halfW = size.x / 2, halfH = size.y / 2
        handles[.grabBar]?.position = [0, -halfH - 0.035, 0]
        handles[.resizeHandle]?.position = [halfW + 0.02, -halfH - 0.02, 0]
        handles[.closeButton]?.position = [-0.13, -halfH - 0.035, 0]
    }

    // MARK: - Placing

    /// Centre at `position`, turned about the vertical to face `viewer`.
    public func move(to position: SIMD3<Float>, facing viewer: SIMD3<Float>?) {
        root.setPosition(position, relativeTo: nil)
        if let viewer, simd_distance(SIMD2(viewer.x, viewer.z), SIMD2(position.x, position.z)) > 1e-3 {
            root.setOrientation(RAVEPanelOrientation.turned(from: position, toward: viewer), relativeTo: nil)
        }
    }

    public func setPose(position: SIMD3<Float>, orientation: simd_quatf) {
        root.setPosition(position, relativeTo: nil)
        root.setOrientation(orientation, relativeTo: nil)
    }

    /// Over a palm: pose and fade from the anchor, advanced by the caller.
    public func follow(_ anchor: RAVEPalmAnchor) {
        opacity = anchor.isVisible ? anchor.opacity : 0
        guard anchor.isVisible, let transform = anchor.transform else { return }
        root.setTransformMatrix(transform, relativeTo: nil)
    }

    /// Ahead of the viewer: the pose the follow worked out, if it has one.
    public func follow(_ pose: (position: SIMD3<Float>, orientation: simd_quatf)?) {
        guard let pose else { return }
        setPose(position: pose.position, orientation: pose.orientation)
    }

    // MARK: - Chrome

    public func part(of entity: Entity) -> Part? {
        handles.first { $0.value === entity }?.key
    }

    /// One step of a drag on the grab bar or the resize corner, with the
    /// hand's travel since the drag began in scene metres.
    public func drag(_ part: Part, translation: SIMD3<Float>, viewer: SIMD3<Float>?) {
        if dragStart == nil { dragStart = (root.position(relativeTo: nil), size) }
        guard let start = dragStart else { return }
        let gain = viewer.map { RAVEPanelDrag.gain(distance: simd_distance(start.position, $0)) } ?? 1
        switch part {
        case .grabBar:
            move(to: start.position + translation * gain, facing: viewer)
        case .resizeHandle:
            // Keep the top-left corner where it is and grow toward the hand,
            // each way on its own, so any shape can be dragged out.
            let right = root.orientation(relativeTo: nil).act([1, 0, 0])
            let across = simd_dot(translation, right), down = -translation.y
            setSize(start.size + gain * SIMD2(across, down))
            let grew = size - start.size
            root.setPosition(start.position + right * (grew.x / 2) - [0, grew.y / 2, 0], relativeTo: nil)
        case .closeButton:
            break
        }
    }

    public func endDrag() { dragStart = nil }

    private static func handle(mesh: MeshResource, hitSize: SIMD3<Float>, color: UIColor) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: hitSize)]))
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        return entity
    }
}
#endif
