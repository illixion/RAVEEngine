/*
 RAVE Engine — the "turn your palm toward your face" show/hide rule.

 Two apps each wrote their own:

 - Longwave's wrist panel: plain `facing`, show at 0.95, hide below 0.70,
   no dwell and no linger.
 - Oneiros's wrist HUD: `pitchInvariantFacing`, show at 0.88, hide below 0.70,
   and a 0.4 s linger so a palm dipping for a moment does not flash the panel.

 The metric difference is a product decision (see `RAVEPalmGeometry`) and both
 presets survive. What was missing from both was a *dwell*: a hand swinging
 past the face while doing something else crossed the show threshold for a
 frame or two and flashed the panel. The presets here add a short one.

 A thin layer over `RAVEGestureGate` + `RAVEPalmGeometry`: the palm-facing
 value is the gate's signal, an untracked hand is a lapse (so the linger also
 covers tracking dropouts). Pure value type, no isolation.
 */

import Foundation
import simd

/// Which palm-facing metric a gate reads. See `RAVEPalmGeometry`.
public enum RAVEPalmFacingMetric: String, Sendable, Equatable {
    /// `RAVEPalmGeometry.facing` — the palm must actually point at the head.
    case plain
    /// `RAVEPalmGeometry.pitchInvariantFacing` — tilting the hand up or down
    /// does not change the reading. Thresholds do not transfer between the two.
    case pitchInvariant
}

/// Show/hide gate for a palm-anchored panel.
public struct RAVEPalmFacingGate: Sendable, Equatable {
    public var metric: RAVEPalmFacingMetric
    public var gate: RAVEGestureGate

    /// The last facing value read, `nil` when the hand or pose was unavailable.
    /// For diagnostics.
    public private(set) var lastFacing: Float?

    /// - Parameters:
    ///   - show: facing at or above which the panel starts to show.
    ///   - hide: facing below which a shown panel starts to hide.
    ///   - dwell: how long the palm must face before the panel shows.
    ///   - linger: how long a shown panel survives a lapse (or tracking loss).
    public init(
        metric: RAVEPalmFacingMetric,
        show: Float,
        hide: Float,
        dwell: TimeInterval,
        linger: TimeInterval
    ) {
        self.metric = metric
        self.gate = RAVEGestureGate(tuning: RAVEGestureGateTuning(
            sense: .rising, enter: show, exit: hide,
            holdToEngage: dwell, releaseGrace: linger
        ))
    }

    /// Longwave's wrist-panel thresholds (plain facing, 0.95 / 0.70), plus a
    /// 0.12 s dwell so a hand passing the face does not flash the panel.
    public static let panel = RAVEPalmFacingGate(
        metric: .plain, show: 0.95, hide: 0.70, dwell: 0.12, linger: 0
    )

    /// Oneiros's wrist-HUD thresholds (pitch-invariant, 0.88 / 0.70, 0.4 s
    /// linger), plus the same 0.12 s dwell.
    public static let forgiving = RAVEPalmFacingGate(
        metric: .pitchInvariant, show: 0.88, hide: 0.70, dwell: 0.12, linger: 0.4
    )

    public var isShown: Bool { gate.isEngaged }

    public mutating func reset() {
        gate.reset()
        lastFacing = nil
    }

    /// Facing of `pose` toward `head` under this gate's metric.
    public func facing(_ pose: RAVEPalmPose, towards head: SIMD3<Float>) -> Float? {
        switch metric {
        case .plain: return RAVEPalmGeometry.facing(pose, towards: head)
        case .pitchInvariant: return RAVEPalmGeometry.pitchInvariantFacing(pose, towards: head)
        }
    }

    /// Advance from a palm pose (`nil` when the hand is untracked or the pose
    /// is unresolvable). `showAllowed` gates showing (e.g. "no pinch held",
    /// "not in a menu"); `keepAllowed` gates staying shown.
    @discardableResult
    public mutating func update(pose: RAVEPalmPose?, head: SIMD3<Float>, now: TimeInterval,
                                showAllowed: Bool = true,
                                keepAllowed: Bool = true) -> RAVEGestureGateOutput {
        let value = pose.flatMap { facing($0, towards: head) }
        lastFacing = value
        return gate.update(value: value, now: now,
                           engageAllowed: showAllowed, holdAllowed: keepAllowed)
    }

    /// Advance from a raw hand sample.
    @discardableResult
    public mutating func update(sample: RAVEHandSample?, head: SIMD3<Float>, now: TimeInterval,
                                showAllowed: Bool = true,
                                keepAllowed: Bool = true) -> RAVEGestureGateOutput {
        update(pose: sample.flatMap(RAVEPalmGeometry.palmPose(from:)), head: head, now: now,
               showAllowed: showAllowed, keepAllowed: keepAllowed)
    }

    /// Advance from an already-computed facing value.
    @discardableResult
    public mutating func update(facing value: Float?, now: TimeInterval,
                                showAllowed: Bool = true,
                                keepAllowed: Bool = true) -> RAVEGestureGateOutput {
        lastFacing = value
        return gate.update(value: value, now: now,
                           engageAllowed: showAllowed, holdAllowed: keepAllowed)
    }
}
