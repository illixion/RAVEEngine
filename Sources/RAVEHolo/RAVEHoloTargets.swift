import Foundation
import simd

/// A pinchable region of a panel: a rounded rectangle in panel metres that
/// carries the host's identifier for the control under it.
///
/// Targets reach the user two ways, and the scene is the one source for both:
///
/// - **Compositor Services tracking areas** (visionOS 26): the host registers
///   one tracking area per distinct `id` on the drawable
///   (`RAVEHoloCompositor.registerTargets`), and `RAVEHoloRenderer.encodeTargets`
///   writes each target's render value into the drawable's tracking-areas
///   texture. The system then draws gaze hover itself and delivers a pinch
///   aimed at the control with `trackingAreaIdentifier == id` — without the
///   app ever seeing gaze.
/// - **A ray** (`RAVEHoloScene.hit`): a mouse click on a Mac host, a
///   debug-server "press", or a pinch that arrived without a tracking area
///   but with a selection ray.
///
/// `id` 0 is reserved (the tracking-areas texture's "nothing here").
public struct RAVEHoloTarget: Sendable, Equatable {
    public var id: UInt64
    /// Centre-origin panel metres: (min x, min y, width, height).
    public var rect: SIMD4<Float>
    public var corner: Float

    public init(id: UInt64, rect: SIMD4<Float>, corner: Float = 0) {
        precondition(id != 0, "RAVEHoloTarget id 0 is reserved")
        self.id = id
        self.rect = rect
        self.corner = corner
    }

    /// Whether a panel-local point (metres) is inside the rounded rectangle.
    public func contains(_ p: SIMD2<Float>) -> Bool {
        let half = SIMD2(rect.z, rect.w) * 0.5
        let q = abs(p - (SIMD2(rect.x, rect.y) + half)) - half + corner
        let d = simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - corner
        return d <= 0
    }
}

public extension RAVEHoloPanel {
    /// Register a pinchable region. Draw what it looks like separately (or use
    /// `button`, which does both).
    mutating func target(_ id: UInt64, x: Float, y: Float, width: Float, height: Float, corner: Float = 0) {
        targets.append(RAVEHoloTarget(id: id, rect: SIMD4(x, y, width, height), corner: corner))
    }

    /// The target under a panel-local point, the last-added winning where
    /// targets overlap (the one drawn on top).
    func target(at local: SIMD2<Float>) -> RAVEHoloTarget? {
        targets.last { $0.contains(local) }
    }
}

public struct RAVEHoloHit: Sendable, Equatable {
    public var id: UInt64
    public var panel: Int
    /// World-space distance from the ray origin.
    public var distance: Float
    /// Where on the panel, in panel metres.
    public var local: SIMD2<Float>
}

public extension RAVEHoloScene {
    /// Every distinct target id in the scene, in first-seen order — what the
    /// host registers as tracking areas.
    var targetIDs: [UInt64] {
        var seen = Set<UInt64>()
        var ids: [UInt64] = []
        for panel in panels {
            for t in panel.targets where seen.insert(t.id).inserted { ids.append(t.id) }
        }
        return ids
    }

    /// The nearest target a world-space ray passes through, `nil` when it
    /// misses every one. Panels are two-sided (like the renderer's), and fully
    /// faded panels are not selectable. Occlusion by the host's own geometry
    /// is the host's concern: a tracking area gets it from the depth test.
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> RAVEHoloHit? {
        var best: RAVEHoloHit?
        for (index, panel) in panels.enumerated() where panel.opacity > 0.01 && !panel.targets.isEmpty {
            let inverse = panel.transform.inverse
            let o = inverse * SIMD4(origin, 1)
            let d = inverse * SIMD4(direction, 0)
            guard abs(d.z) > 1e-7 else { continue }
            let t = -o.z / d.z
            guard t > 0 else { continue }
            let local = SIMD2(o.x + d.x * t, o.y + d.y * t)
            guard let target = panel.target(at: local) else { continue }
            let world = panel.transform * SIMD4(local.x, local.y, 0, 1)
            let distance = simd_length(SIMD3(world.x, world.y, world.z) - origin)
            if best.map({ distance < $0.distance }) ?? true {
                best = RAVEHoloHit(id: target.id, panel: index, distance: distance, local: local)
            }
        }
        return best
    }
}

/// Press bookkeeping shared between the thread that receives pinches (the
/// main actor, from `onSpatialEvent`) and the thread that builds the scene
/// (often the render thread): when each control was last pressed, so a
/// widget can flash, and how often, for diagnostics.
///
/// Lock-guarded rather than an actor for the Engine's isolation rule — a
/// render thread cannot await.
public final class RAVEHoloInteraction: @unchecked Sendable {
    /// How long a press flash takes to fade.
    public let flashDuration: TimeInterval
    private let lock = NSLock()
    private var pressedAt: [UInt64: TimeInterval] = [:]
    private var counts: [UInt64: Int] = [:]

    public init(flashDuration: TimeInterval = 0.25) {
        self.flashDuration = flashDuration
    }

    public func recordPress(_ id: UInt64, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        pressedAt[id] = now
        counts[id, default: 0] += 1
    }

    /// 1 right after a press of `id`, fading to 0 over `flashDuration`.
    public func flash(_ id: UInt64, now: TimeInterval) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let t = pressedAt[id], flashDuration > 0 else { return 0 }
        return Float(max(0, min(1, 1 - (now - t) / flashDuration)))
    }

    /// Presses per id since creation.
    public var pressCounts: [UInt64: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }
}
