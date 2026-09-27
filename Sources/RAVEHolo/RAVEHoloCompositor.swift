#if os(visionOS)
import CompositorServices
import Metal

/// The Compositor Services half of interactive panels: asking the layer for
/// a tracking-areas texture and registering a scene's targets on each
/// drawable. Proven on device in Oneiros's wrist-panel probe (2026-09-22):
/// hover shows, a pinch arrives in `onSpatialEvent` with
/// `event.trackingAreaIdentifier.rawValue == target id`, and never reaches
/// the world behind the panel.
///
/// Host checklist (see RAVEEngine's CLAUDE.md, "Interactive panels"):
/// 1. `configureTrackingAreas` in the layer configuration.
/// 2. Per drawable: `registerTargets`, then `RAVEHoloRenderer.encodeTargets`
///    into a pass over `drawable.trackingAreasTextures[0]`.
/// 3. `onSpatialEvent`: route an event whose tracking-area identifier is a
///    target id to the control first, and only the rest to the world.
/// 4. `.persistentSystemOverlays(.hidden)` on the `CompositorLayer` content
///    itself — the scene-level modifier alone lets the Home indicator cover a
///    palm panel from the second palm-up on.
public enum RAVEHoloCompositor {
    /// Request an integer tracking-areas texture (`r8Uint` preferred: 255
    /// targets a frame). Returns the chosen format, `nil` when the device
    /// offers none — the host then has no system hover and should fall back to
    /// `RAVEHoloScene.hit` with the pinch's selection ray.
    @discardableResult
    public static func configureTrackingAreas(capabilities: LayerRenderer.Capabilities,
                                              configuration: inout LayerRenderer.Configuration) -> MTLPixelFormat? {
        let offered = capabilities.supportedTrackingAreasFormats
        guard let format = [MTLPixelFormat.r8Uint, .r16Uint].first(where: offered.contains) ?? offered.first else {
            return nil
        }
        configuration.trackingAreasFormat = format
        configuration.trackingAreasUsage.insert(.renderTarget)
        return format
    }

    /// Register one tracking area per distinct target id (with the system's
    /// automatic hover) and return each one's render value for
    /// `RAVEHoloRenderer.encodeTargets`. Tracking areas live for one drawable:
    /// call this every frame the panel is visible. Ids the system refused are
    /// left out.
    public static func registerTargets(of scene: RAVEHoloScene, on drawable: LayerRenderer.Drawable,
                                       hoverEffect: Bool = true) -> [UInt64: UInt32] {
        var values: [UInt64: UInt32] = [:]
        for id in scene.targetIDs {
            let area = drawable.addTrackingArea(identifier: .init(id))
            guard area.renderValue != .invalid else { continue }
            if hoverEffect { area.addHoverEffect(.automatic) }
            values[id] = UInt32(truncatingIfNeeded: area.renderValue.rawValue)
        }
        return values
    }
}
#endif
