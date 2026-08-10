/*
 RAVE Engine — the per-frame hand input seam.

 Holding this as an optional, and degrading to "no hand input" when it is nil,
 is what lets a platform without hand tracking (macOS, the simulator) drop
 hands entirely without any gamepad or keyboard path branching on it. Hands
 were always just one additive source.

 The protocol is `@MainActor` because that is where both SwiftUI-shaped
 consumers drive their frame loop. A render-thread consumer should skip the
 protocol and use `RAVEPinchDetector` / `RAVEHandJoystick` directly — they carry
 no isolation, which is the whole reason the sensing math lives in value types.
 */

import simd

/// Per-frame source of hand input.
@MainActor
public protocol RAVEHandInputProvider: AnyObject {
    /// Start the backing session. Non-fatal on failure — the caller falls back
    /// to whatever other input sources it has.
    func start() async

    /// Process the latest hand data. `worldForward` / `worldRight` are the
    /// player's head-relative basis vectors in world space, used to project a
    /// wrist delta into movement.
    func tick(worldForward: SIMD3<Float>, worldRight: SIMD3<Float>) -> RAVEHandInputFrame

    /// Pose of the named palm, or `nil` when that hand isn't tracked.
    func palmPose(_ chirality: RAVEHandChirality) -> RAVEPalmPose?
}

public extension RAVEHandInputProvider {
    /// How directly a palm faces `target` — plain dot product, so the palm must
    /// actually point at it. See `RAVEPalmGeometry` on choosing between this and
    /// the pitch-invariant variant.
    func palmFacing(_ chirality: RAVEHandChirality, towards target: SIMD3<Float>) -> Float? {
        palmPose(chirality).flatMap { RAVEPalmGeometry.facing($0, towards: target) }
    }

    /// `palmFacing`, with hand pitch factored out — a forgiving cone that
    /// tightens against a sideways swing without punishing tilt.
    func palmFacingPitchInvariant(
        _ chirality: RAVEHandChirality,
        towards target: SIMD3<Float>
    ) -> Float? {
        palmPose(chirality).flatMap { RAVEPalmGeometry.pitchInvariantFacing($0, towards: target) }
    }
}

/// Explicit "hands are off" provider.
///
/// `nil` means *this platform has none*; this type means *a caller chose to
/// disable them* — a test, or a gamepad-only mode — without disturbing platform
/// wiring.
public final class RAVENoHandInput: RAVEHandInputProvider {
    public init() {}
    public func start() async {}
    public func tick(worldForward: SIMD3<Float>, worldRight: SIMD3<Float>) -> RAVEHandInputFrame {
        RAVEHandInputFrame()
    }
    public func palmPose(_ chirality: RAVEHandChirality) -> RAVEPalmPose? { nil }
}
