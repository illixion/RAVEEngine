/*
 RAVE Engine — the wrist-delta locomotion joystick.

 A sustained pinch anchors the wrist; while it is held, the wrist's displacement
 from that anchor is projected onto the player's head-relative horizontal basis
 and scaled to a unit vector. Releasing drops the anchor, so the next engage
 re-centres wherever the hand happens to be.

 All three apps implemented this identically apart from Lambda's deadzone (which
 stops a perfectly still pinch from creeping) and Lambda's use of the raw vertical
 delta for jump/duck. The deadzone is now the shared default: ARKit wrist jitter is
 input noise, not a product choice.

 Head-relative rather than world-relative is the load-bearing detail: it means the
 joystick survives snap turns and a rotating vehicle, because "forward" is
 re-read from the head basis every frame instead of being baked into the anchor.

 The control point and basis MUST be expressed in the same coordinate space.
 `RAVEPlanarBasis` makes that contract explicit and repairs skewed or degenerate
 axes before projection. The output also carries renderer-neutral visualization
 geometry, so RealityKit, Metal and remote-controller consumers can each draw the
 same stick without the input package depending on any renderer.
 */

import Foundation
import simd

/// A validated horizontal basis in a caller-defined tracking coordinate space.
///
/// `forward` and `right` are always finite, unit length and orthogonal. The
/// initializer treats Y as up and derives the canonical right axis from
/// forward. The supplied right axis is only a fallback when forward has no
/// usable horizontal component.
public struct RAVEPlanarBasis: Sendable, Equatable {
    public var forward: SIMD3<Float>
    public var right: SIMD3<Float>

    public init(
        forward: SIMD3<Float>,
        right: SIMD3<Float>,
        fallbackForward: SIMD3<Float> = SIMD3(0, 0, -1)
    ) {
        if let unitForward = Self.horizontalUnit(forward) {
            self.forward = unitForward
            self.right = Self.rightAxis(for: unitForward)
        } else if let unitRight = Self.horizontalUnit(right) {
            self.right = unitRight
            self.forward = SIMD3(unitRight.z, 0, -unitRight.x)
        } else if let fallback = Self.horizontalUnit(fallbackForward) {
            self.forward = fallback
            self.right = Self.rightAxis(for: fallback)
        } else {
            self.forward = SIMD3(0, 0, -1)
            self.right = SIMD3(1, 0, 0)
        }
    }

    private static func horizontalUnit(_ value: SIMD3<Float>) -> SIMD3<Float>? {
        guard value.x.isFinite, value.z.isFinite else { return nil }
        let horizontal = SIMD3<Float>(value.x, 0, value.z)
        let length = simd_length(horizontal)
        guard length > 1e-5, length.isFinite else { return nil }
        return horizontal / length
    }

    private static func rightAxis(for forward: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-forward.z, 0, forward.x)
    }
}

/// Renderer-neutral geometry for drawing a virtual joystick.
///
/// Every position and axis uses the same tracking space as the control point
/// passed to `RAVEHandJoystick.update(controlPoint:engaged:basis:)`.
public struct RAVEJoystickVisualization: Sendable, Equatable {
    /// Center of the joystick ring.
    public var center: SIMD3<Float>
    /// Handle position projected onto the joystick plane and clamped to the
    /// full-scale ring.
    public var handle: SIMD3<Float>
    public var basis: RAVEPlanarBasis
    public var deadzoneMeters: Float
    public var fullScaleMeters: Float
    /// The actual movement value after deadzone removal and response scaling.
    public var value: SIMD2<Float>

    public init(
        center: SIMD3<Float>,
        handle: SIMD3<Float>,
        basis: RAVEPlanarBasis,
        deadzoneMeters: Float,
        fullScaleMeters: Float,
        value: SIMD2<Float>
    ) {
        self.center = center
        self.handle = handle
        self.basis = basis
        self.deadzoneMeters = deadzoneMeters
        self.fullScaleMeters = fullScaleMeters
        self.value = value
    }
}

/// The joystick's reading for one frame.
public struct RAVEJoystickOutput: Sendable, Equatable {
    /// Head-relative (x = strafe, y = forward), magnitude clamped to 1.
    public var vector: SIMD2<Float>
    /// Tracking-space control-point displacement from the anchor (low-passed
    /// when the joystick's `smoothingTime` is in use). Vertical gestures
    /// (jump / duck) read `delta.y`; the horizontal part is already folded
    /// into `vector`.
    public var delta: SIMD3<Float>
    /// True while an anchor is held.
    public var isEngaged: Bool
    /// Geometry an app can use to draw the stick. `nil` while disengaged.
    public var visualization: RAVEJoystickVisualization?

    public init(
        vector: SIMD2<Float> = .zero,
        delta: SIMD3<Float> = .zero,
        isEngaged: Bool = false,
        visualization: RAVEJoystickVisualization? = nil
    ) {
        self.vector = vector
        self.delta = delta
        self.isEngaged = isEngaged
        self.visualization = visualization
    }
}

/// Wrist-delta joystick. One per hand that can drive locomotion; stored by
/// value alongside the pinch detector that gates it.
public struct RAVEHandJoystick: Sendable {
    /// Wrist displacement, in meters, that reads as full deflection.
    public var fullScaleMeters: Float
    /// Horizontal displacement below which the stick reads zero. Zero disables
    /// the deadzone entirely (the hysteresis on the engaging pinch is then the
    /// only thing stopping drift).
    public var deadzoneMeters: Float

    /// Optional per-axis deadzone, as a fraction of full deflection, applied
    /// after the radial one: a forward push that wanders a little sideways
    /// then does not strafe. Zero (the default) disables it.
    public var axialDeadzone: Float
    /// Time constant, in seconds, of a low-pass filter on the wrist offset.
    /// Takes effect only through `update(controlPoint:engaged:basis:now:)`,
    /// which knows the frame time. Zero (the default) disables it, which is
    /// the original behaviour. ~0.05 s takes the edge off ARKit wrist jitter
    /// without the stick feeling late.
    public var smoothingTime: TimeInterval

    /// Where the wrist was when the current hold began, in the caller's
    /// tracking space. `nil` when disengaged.
    public private(set) var anchor: SIMD3<Float>?
    private var smoothedDelta: SIMD3<Float>?
    private var lastTime: TimeInterval?

    /// Compatibility spelling from the original world-space-only API.
    @available(*, deprecated, renamed: "anchor")
    public var anchorWorld: SIMD3<Float>? { anchor }

    public init(fullScaleMeters: Float = 0.18, deadzoneMeters: Float = 0.03) {
        self.init(fullScaleMeters: fullScaleMeters, deadzoneMeters: deadzoneMeters,
                  axialDeadzone: 0, smoothingTime: 0)
    }

    public init(
        fullScaleMeters: Float = 0.18,
        deadzoneMeters: Float = 0.03,
        axialDeadzone: Float,
        smoothingTime: TimeInterval
    ) {
        self.fullScaleMeters = fullScaleMeters
        self.deadzoneMeters = deadzoneMeters
        self.axialDeadzone = axialDeadzone
        self.smoothingTime = smoothingTime
    }

    /// Drop the anchor without producing a reading.
    public mutating func release() {
        anchor = nil
        smoothedDelta = nil
        lastTime = nil
    }

    /// Advance one frame with the frame time, which enables `smoothingTime`.
    /// Otherwise identical to `update(controlPoint:engaged:basis:)`.
    @discardableResult
    public mutating func update(
        controlPoint: SIMD3<Float>?,
        engaged: Bool,
        basis: RAVEPlanarBasis,
        now: TimeInterval
    ) -> RAVEJoystickOutput {
        let dt = lastTime.map { max(0, now - $0) }
        lastTime = now
        return step(controlPoint: controlPoint, engaged: engaged, basis: basis, dt: dt)
    }

    /// Advance one frame.
    ///
    /// - Parameters:
    ///   - controlPoint: current wrist position in the caller's tracking space.
    ///   - engaged: whether the gating pinch is held this frame. `false` drops
    ///     the anchor and returns a zero reading.
    ///   - basis: the player's head-relative axes in the SAME tracking space as
    ///     `controlPoint`.
    @discardableResult
    public mutating func update(
        controlPoint: SIMD3<Float>?,
        engaged: Bool,
        basis: RAVEPlanarBasis
    ) -> RAVEJoystickOutput {
        step(controlPoint: controlPoint, engaged: engaged, basis: basis, dt: nil)
    }

    private mutating func step(
        controlPoint: SIMD3<Float>?,
        engaged: Bool,
        basis: RAVEPlanarBasis,
        dt: TimeInterval?
    ) -> RAVEJoystickOutput {
        guard engaged,
              let controlPoint,
              controlPoint.x.isFinite,
              controlPoint.y.isFinite,
              controlPoint.z.isFinite
        else {
            anchor = nil
            smoothedDelta = nil
            return RAVEJoystickOutput()
        }

        if anchor == nil { anchor = controlPoint }
        let center = anchor ?? controlPoint
        var delta = controlPoint - center
        // Low-pass the offset (not the position), so the anchor frame still
        // reads exactly zero and the filter state starts from rest.
        if smoothingTime > 0, let dt {
            let previous = smoothedDelta ?? .zero
            let alpha = Float(1 - exp(-min(dt, 0.25) / smoothingTime))
            delta = previous + (delta - previous) * alpha
        }
        smoothedDelta = delta
        let strafe = simd_dot(delta, basis.right)
        let advance = simd_dot(delta, basis.forward)
        let planar = SIMD2(strafe, advance)
        let distance = simd_length(planar)
        let fullScale = max(fullScaleMeters.isFinite ? fullScaleMeters : 0, 1e-4)
        let deadzone = min(max(deadzoneMeters.isFinite ? deadzoneMeters : 0, 0), fullScale)

        let handleDistance = min(distance, fullScale)
        let handleOffset = distance > 1e-6 ? planar * (handleDistance / distance) : .zero
        let vector: SIMD2<Float>
        if distance > deadzone {
            let activeRange = max(fullScale - deadzone, 1e-4)
            let outputMagnitude = min(1, (distance - deadzone) / activeRange)
            let radial = planar / distance * outputMagnitude
            vector = axialDeadzone > 0
                ? RAVEStickShaping.axialDeadzone(radial, deadzone: axialDeadzone)
                : radial
        } else {
            vector = .zero
        }

        let visualization = RAVEJoystickVisualization(
            center: center,
            handle: center + basis.right * handleOffset.x + basis.forward * handleOffset.y,
            basis: basis,
            deadzoneMeters: deadzone,
            fullScaleMeters: fullScale,
            value: vector
        )
        return RAVEJoystickOutput(
            vector: vector,
            delta: delta,
            isEngaged: true,
            visualization: visualization
        )
    }

    /// Compatibility overload. Prefer the basis-taking form because its labels
    /// make the same-coordinate-space requirement visible at the call site.
    @discardableResult
    public mutating func update(
        wristWorld: SIMD3<Float>?,
        engaged: Bool,
        worldForward: SIMD3<Float>,
        worldRight: SIMD3<Float>
    ) -> RAVEJoystickOutput {
        update(
            controlPoint: wristWorld,
            engaged: engaged,
            basis: RAVEPlanarBasis(forward: worldForward, right: worldRight)
        )
    }
}
