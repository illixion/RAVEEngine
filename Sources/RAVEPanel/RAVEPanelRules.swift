import Foundation
import simd

// The per-frame rules of a panel in the room, with no framework in them:
// who is looking, whether they can see it, where a head-following panel
// goes and how hard a drag pulls. `RAVEPanel` applies them to RealityKit
// entities on visionOS; here they are plain values, so `swift test` runs
// them on the Mac.

/// Where the viewer is: the eye point and the way they look.
public struct RAVEPanelViewer: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// Unit length. May tilt; `flatForward` is the horizontal part.
    public var forward: SIMD3<Float>

    public init(position: SIMD3<Float>, forward: SIMD3<Float>) {
        self.position = position
        let length = simd_length(forward)
        self.forward = length > 1e-5 ? forward / length : SIMD3(0, 0, -1)
    }

    /// From a device (head) transform, which looks along its -Z.
    public init(transform: simd_float4x4) {
        self.init(position: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                  forward: -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
    }

    /// The gaze on the floor plane, or nil looking straight up or down. A
    /// panel placed along a downward gaze would end up at the viewer's feet.
    public var flatForward: SIMD3<Float>? {
        let flat = SIMD3<Float>(forward.x, 0, forward.z)
        let length = simd_length(flat)
        return length > 1e-4 ? flat / length : nil
    }
}

public enum RAVEPanelOrientation {
    /// Upright, with +Z (the way a SwiftUI attachment faces) toward
    /// `viewer`: the card turns to the eyes however it got where it is,
    /// rather than tumbling with a hand.
    public static func facing(from position: SIMD3<Float>, toward viewer: SIMD3<Float>) -> simd_quatf {
        var z = viewer - position
        z = simd_length(z) > 1e-5 ? simd_normalize(z) : SIMD3(0, 0, 1)
        var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
        guard simd_length(x) > 1e-4 else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        x = simd_normalize(x)
        return simd_quatf(simd_float3x3(x, simd_cross(z, x), z))
    }

    /// Turned about the vertical only toward `viewer`, so the panel never
    /// tilts back: a screen stood in the room, not a card held up.
    public static func turned(from position: SIMD3<Float>, toward viewer: SIMD3<Float>) -> simd_quatf {
        facing(from: position, toward: SIMD3(viewer.x, position.y, viewer.z))
    }
}

/// Whether anyone can see a panel, for pausing what it holds.
///
/// A panel counts as seen while it is available (in the scene, enabled, its
/// space in the foreground) and some part of it is inside a cone around the
/// gaze. Losing sight pauses only after `hideDelay`; a glance away is not a
/// reason to stop a page. Becoming unavailable pauses at once, since that is
/// certain. Seeing it again resumes at once.
///
/// This exists because nothing tells a web page in a RealityKit attachment
/// that it is out of view: behind the user, disabled or removed it runs at
/// full rate (measured on the AVP, 2026-09-28; see RAVESDK `RAVEWebViewHost`).
public struct RAVEPanelVisibility: Sendable, Equatable {
    /// Half the cone that counts as seen. Vision Pro's field of view is
    /// about 100° across; 60° adds a margin for a glance.
    public var halfAngle: Float
    public var hideDelay: TimeInterval

    public private(set) var isRunning = true
    private var lastSeen: TimeInterval?
    private var awakeUntil: TimeInterval = -.infinity

    public init(halfAngle: Float = 60 * .pi / 180, hideDelay: TimeInterval = 1.5) {
        self.halfAngle = halfAngle
        self.hideDelay = hideDelay
    }

    /// Whether any of a panel `size` wide and high, centred at `center`, is
    /// within `halfAngle` of the viewer's gaze.
    public static func isInView(center: SIMD3<Float>, size: SIMD2<Float>,
                                of viewer: RAVEPanelViewer, halfAngle: Float) -> Bool {
        let offset = center - viewer.position
        let distance = simd_length(offset)
        guard distance > 1e-3 else { return true }
        let angle = acos(min(max(simd_dot(viewer.forward, offset / distance), -1), 1))
        let radius = atan(max(size.x, size.y) / 2 / distance)
        return angle - radius < halfAngle
    }

    /// One frame. `viewer` nil (no tracking yet) counts as in view.
    /// Returns whether the content should be running.
    @discardableResult
    public mutating func update(available: Bool, center: SIMD3<Float>, size: SIMD2<Float>,
                                viewer: RAVEPanelViewer?, now: TimeInterval) -> Bool {
        guard available else {
            isRunning = false
            lastSeen = nil
            return false
        }
        // Just became available (shown, enabled, back in the foreground):
        // it runs, and the delay starts from here if nobody is looking.
        if lastSeen == nil {
            lastSeen = now
            isRunning = true
        }
        let seen = viewer.map { Self.isInView(center: center, size: size, of: $0, halfAngle: halfAngle) } ?? true
        if seen || now < awakeUntil {
            lastSeen = now
            isRunning = true
        } else if isRunning, let lastSeen, now - lastSeen > hideDelay {
            isRunning = false
        }
        return isRunning
    }

    /// Keeps the content running until `time`, seen or not: for a tool that
    /// reads a page nobody is looking at. Takes effect on the next update.
    public mutating func keepAwake(until time: TimeInterval) {
        awakeUntil = max(awakeUntil, time)
    }
}

/// A panel that floats ahead of the viewer and trails their turns slowly:
/// readable while they get on with something else, never dragged about by
/// every head movement. Longwave's immersive banner is the shape.
public struct RAVEPanelHeadFollow: Sendable, Equatable {
    /// How far ahead along the flattened gaze.
    public var distance: Float
    /// How far below the eyes.
    public var drop: Float
    /// Time constant of the follow (s). 0 = locked to the head.
    public var smoothing: TimeInterval

    /// Nil until the first update with a viewer, so a panel appears where
    /// the viewer is looking rather than sliding in from where it last was.
    public private(set) var position: SIMD3<Float>?
    public private(set) var orientation = simd_quatf(angle: 0, axis: [0, 1, 0])

    public init(distance: Float = 1.5, drop: Float = 0.28, smoothing: TimeInterval = 1.2) {
        self.distance = distance
        self.drop = drop
        self.smoothing = smoothing
    }

    /// The pose to show at, or nil before there has ever been a viewer.
    /// A frame with no viewer (or a gaze straight down) keeps the last pose.
    public mutating func update(viewer: RAVEPanelViewer?, deltaTime: TimeInterval)
        -> (position: SIMD3<Float>, orientation: simd_quatf)? {
        if let viewer, let forward = viewer.flatForward {
            let target = SIMD3<Float>(viewer.position.x + forward.x * distance,
                                      viewer.position.y - drop,
                                      viewer.position.z + forward.z * distance)
            let facing = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: -forward)
            if let current = position, smoothing > 0 {
                let k = Float(1 - exp(-deltaTime / smoothing))
                position = current + (target - current) * k
                orientation = simd_slerp(orientation, facing, k)
            } else {
                position = target
                orientation = facing
            }
        }
        return position.map { ($0, orientation) }
    }

    /// Forgets the pose, so the next show starts in front of the viewer.
    public mutating func reset() { position = nil }
}

public enum RAVEPanelDrag {
    /// A hand moves a few tens of centimetres; a panel can sit metres away.
    /// The hand's travel is scaled by the panel's distance, as system
    /// windows do: 1× within half a metre, up to 4×.
    public static func gain(distance: Float) -> Float {
        min(max(distance / 0.5, 1), 4)
    }
}

/// A panel worn on the back of the wrist, like a watch face that floats: an
/// offset in the hand's own frame, so it rides the forearm wherever the arm
/// goes, turned to the viewer with its long edge along the arm. It fades out
/// while the palm faces the viewer, since the back of the wrist (and the
/// panel) then faces away, and turning the palm up is a palm HUD's gesture.
/// Tracking loss fades it where it was.
///
/// OVR Toolkit's wrist windows are the model: always there, readable at a
/// glance, never summoned.
public struct RAVEPanelHandMount: Sendable, Equatable {
    /// Metres in the hand frame: x across the hand (thumb side of a right
    /// hand), y out of the back of the hand, z along the fingers (negative is
    /// back toward the forearm).
    public var offset: SIMD3<Float>
    /// Time constant of the follow (s).
    public var smoothing: TimeInterval
    public var fadeIn: TimeInterval
    public var fadeOut: TimeInterval
    /// Palm facing (`RAVEPalmGeometry.facing`'s dot product) at or above
    /// which the panel hides: the palm is turned toward the viewer.
    public var hideWhenPalmFacing: Float

    public private(set) var opacity: Float = 0
    public private(set) var position: SIMD3<Float>?
    public private(set) var orientation = simd_quatf(angle: 0, axis: [0, 1, 0])

    /// Just past the wrist on the forearm, a few centimetres above it.
    public static let backOfWrist = SIMD3<Float>(0, 0.05, -0.13)

    public init(offset: SIMD3<Float> = RAVEPanelHandMount.backOfWrist, smoothing: TimeInterval = 0.06,
                fadeIn: TimeInterval = 0.15, fadeOut: TimeInterval = 0.2, hideWhenPalmFacing: Float = 0.35) {
        self.offset = offset
        self.smoothing = smoothing
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.hideWhenPalmFacing = hideWhenPalmFacing
    }

    /// The hand frame: across, out of the back, along the fingers. Nil for a
    /// degenerate pose.
    public static func frame(of palm: RAVEPanelPalm) -> (across: SIMD3<Float>, back: SIMD3<Float>, along: SIMD3<Float>)? {
        let back = -palm.normalOut
        var along = palm.fingers - simd_dot(palm.fingers, back) * back
        guard simd_length(along) > 1e-4, simd_length(back) > 1e-4 else { return nil }
        along = simd_normalize(along)
        let across = simd_normalize(simd_cross(back, along))
        return (across, simd_normalize(back), along)
    }

    /// Where `offset` puts the panel for this palm.
    public func target(for palm: RAVEPanelPalm) -> SIMD3<Float>? {
        guard let f = Self.frame(of: palm) else { return nil }
        return palm.position + f.across * offset.x + f.back * offset.y + f.along * offset.z
    }

    /// The offset that would put the panel at `world` for this palm: for
    /// moving it by hand in an edit mode.
    public static func offset(placing world: SIMD3<Float>, on palm: RAVEPanelPalm) -> SIMD3<Float>? {
        guard let f = frame(of: palm) else { return nil }
        let d = world - palm.position
        return SIMD3(simd_dot(d, f.across), simd_dot(d, f.back), simd_dot(d, f.along))
    }

    /// One frame. `palm` nil when the hand is not tracked, `viewer` the eye
    /// point. Returns the pose to show at, or nil while it has none.
    public mutating func update(palm: RAVEPanelPalm?, viewer: SIMD3<Float>?, deltaTime: TimeInterval)
        -> (position: SIMD3<Float>, orientation: simd_quatf)? {
        var shown = false
        if let palm, let viewer, let target = target(for: palm), let f = Self.frame(of: palm) {
            let toViewer = viewer - palm.position
            let facing = simd_length(toViewer) > 1e-4 ? simd_dot(palm.normalOut, simd_normalize(toViewer)) : 0
            shown = facing < hideWhenPalmFacing
            let facingViewer = Self.alongArm(at: target, arm: f.along, viewer: viewer)
            if let current = position, opacity > 0, smoothing > 0 {
                let k = Float(1 - exp(-deltaTime / smoothing))
                position = current + (target - current) * k
                orientation = simd_slerp(orientation, facingViewer, k)
            } else {
                // Appear in place rather than swooping in from a stale pose.
                position = target
                orientation = facingViewer
            }
        }
        if shown {
            opacity = fadeIn > 0 ? min(1, opacity + Float(deltaTime / fadeIn)) : 1
            if opacity == 0 { opacity = .ulpOfOne }
        } else {
            opacity = fadeOut > 0 ? max(0, opacity - Float(deltaTime / fadeOut)) : 0
        }
        return position.map { ($0, orientation) }
    }

    public mutating func reset() {
        opacity = 0
        position = nil
    }

    /// +Z toward the viewer, the long (x) edge along the arm as the viewer
    /// sees it, kept the right way up. With the arm pointing at or away from
    /// the viewer there is no "along" to see, so it stands upright instead.
    static func alongArm(at position: SIMD3<Float>, arm: SIMD3<Float>, viewer: SIMD3<Float>) -> simd_quatf {
        var z = viewer - position
        guard simd_length(z) > 1e-5 else { return RAVEPanelOrientation.facing(from: position, toward: viewer) }
        z = simd_normalize(z)
        var x = arm - simd_dot(arm, z) * z
        guard simd_length(x) > 0.3 else { return RAVEPanelOrientation.facing(from: position, toward: viewer) }
        x = simd_normalize(x)
        var y = simd_cross(z, x)
        // Text upside down on the other arm: flip so up is up.
        if y.y < 0 { x = -x; y = -y }
        return simd_quatf(simd_float3x3(x, y, z))
    }
}

/// A palm for the hand mount: RAVEInput's `RAVEPalmPose` without making the
/// rules depend on it (`init(_:)` in `RAVEPanel.swift` converts).
public struct RAVEPanelPalm: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// Out of the palm, toward the face when looking at it.
    public var normalOut: SIMD3<Float>
    /// Up the hand, toward the fingertips.
    public var fingers: SIMD3<Float>

    public init(position: SIMD3<Float>, normalOut: SIMD3<Float>, fingers: SIMD3<Float>) {
        self.position = position
        self.normalOut = normalOut
        self.fingers = fingers
    }
}

/// A panel pinned to the view: a fixed offset in the head's frame, so it
/// stays in the same spot of the field of view (OVR Toolkit's "attach to
/// head"). A light follow takes the jitter out of head tracking without it
/// feeling like it lags.
public struct RAVEPanelHeadLock: Sendable, Equatable {
    /// Metres in the head frame: x right, y up, z backward (so ahead is -z).
    public var offset: SIMD3<Float>
    public var smoothing: TimeInterval

    public private(set) var position: SIMD3<Float>?
    public private(set) var orientation = simd_quatf(angle: 0, axis: [0, 1, 0])

    /// Low and to the right, out of the centre of view.
    public static let lowerRight = SIMD3<Float>(0.28, -0.18, -0.9)

    public init(offset: SIMD3<Float> = RAVEPanelHeadLock.lowerRight, smoothing: TimeInterval = 0.04) {
        self.offset = offset
        self.smoothing = smoothing
    }

    public mutating func update(head: simd_float4x4?, deltaTime: TimeInterval)
        -> (position: SIMD3<Float>, orientation: simd_quatf)? {
        if let head {
            let target4 = head * SIMD4(offset, 1)
            let target = SIMD3(target4.x, target4.y, target4.z)
            // Facing the eye rather than parallel to the face, so a panel
            // off to the side is not seen edge-on.
            let eye = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let up = simd_normalize(SIMD3(head.columns.1.x, head.columns.1.y, head.columns.1.z))
            let facing = Self.facing(from: target, toward: eye, up: up)
            if let current = position, smoothing > 0 {
                let k = Float(1 - exp(-deltaTime / smoothing))
                position = current + (target - current) * k
                orientation = simd_slerp(orientation, facing, k)
            } else {
                position = target
                orientation = facing
            }
        }
        return position.map { ($0, orientation) }
    }

    /// The offset that would put the panel at `world` for this head.
    public static func offset(placing world: SIMD3<Float>, head: simd_float4x4) -> SIMD3<Float> {
        let local = head.inverse * SIMD4(world, 1)
        return SIMD3(local.x, local.y, local.z)
    }

    public mutating func reset() { position = nil }

    static func facing(from position: SIMD3<Float>, toward eye: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        var z = eye - position
        z = simd_length(z) > 1e-5 ? simd_normalize(z) : SIMD3(0, 0, 1)
        var x = simd_cross(up, z)
        guard simd_length(x) > 1e-4 else { return RAVEPanelOrientation.facing(from: position, toward: eye) }
        x = simd_normalize(x)
        return simd_quatf(simd_float3x3(x, simd_cross(z, x), z))
    }
}
