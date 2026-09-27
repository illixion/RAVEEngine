import Foundation
import RAVEInput
import simd

/// Places a panel over a palm while the palm faces the head: the show/hide
/// rule, where the panel sits, how it follows the hand and how it fades.
///
/// It is the part of Oneiros's wrist HUD every host had to redo — the gate
/// (`RAVEPalmFacingGate`), a point lifted off the palm along its outward
/// normal, an upright card turned toward the eyes, a snap into place on
/// appearing and an exponential ease after that (so hand tremor does not make
/// the panel a moving gaze target), and a fade. Pure value type: advance it
/// from wherever the host has the hand — the game tick, or the render thread
/// with a pose predicted for the drawable's presentation time, which removes
/// the tick of lag a tick-driven pose trails the frame by.
public struct RAVEHoloPalmAnchor: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Metres off the palm centre along its outward normal (toward the
        /// eyes while the gate is open).
        public var lift: Float
        /// Time constant of the position ease (s). 0 = follow exactly.
        public var smoothing: TimeInterval
        public var fadeIn: TimeInterval
        public var fadeOut: TimeInterval

        public init(lift: Float, smoothing: TimeInterval = 0.06,
                    fadeIn: TimeInterval = 0.12, fadeOut: TimeInterval = 0.18) {
            self.lift = lift; self.smoothing = smoothing
            self.fadeIn = fadeIn; self.fadeOut = fadeOut
        }

        /// Just in front of the palm — the panel reads as held in the hand.
        public static let overPalm = Tuning(lift: 0.05)
        /// Oneiros's wrist HUD: a projection floating 18 cm off the palm.
        public static let offPalm = Tuning(lift: 0.18)
    }

    public var gate: RAVEPalmFacingGate
    public var tuning: Tuning

    /// 0…1; the panel is drawn while this is above zero.
    public private(set) var opacity: Float = 0
    /// Smoothed panel centre, world metres. `nil` until a pose has been seen.
    public private(set) var position: SIMD3<Float>?
    /// The head the card last turned toward.
    public private(set) var viewer = SIMD3<Float>(0, 0, 0)
    private var lastUpdate: TimeInterval?

    public init(gate: RAVEPalmFacingGate = .panel, tuning: Tuning = .overPalm) {
        self.gate = gate
        self.tuning = tuning
    }

    /// Whether the panel should be drawn (and its targets registered).
    public var isVisible: Bool { opacity > 0 && position != nil }
    /// Whether the gate is open — the panel is showing or fading in.
    public var isShown: Bool { gate.isShown }

    /// Panel-local → world: centre at `position`, facing `viewer`, upright.
    public var transform: simd_float4x4? {
        position.map { RAVEHoloPanel.facing(position: $0, viewer: viewer) }
    }

    /// Advance one frame. `pose` is the palm (nil when untracked), `head` the
    /// eye point in the same space. `showAllowed` / `keepAllowed` feed the
    /// gate — e.g. refuse showing while that hand drives a joystick.
    @discardableResult
    public mutating func update(pose: RAVEPalmPose?, head: SIMD3<Float>, now: TimeInterval,
                                showAllowed: Bool = true, keepAllowed: Bool = true) -> RAVEGestureGateOutput {
        let out = gate.update(pose: pose, head: head, now: now,
                              showAllowed: showAllowed, keepAllowed: keepAllowed)
        let dt = lastUpdate.map { max(0, min(0.1, now - $0)) } ?? 0
        lastUpdate = now
        viewer = head

        if let pose {
            let target = pose.position + pose.palmNormalOut * tuning.lift
            if position == nil || opacity == 0 || tuning.smoothing <= 0 {
                position = target   // appear in place, don't swoop from a stale pose
            } else if let current = position {
                let k = Float(1 - exp(-dt / tuning.smoothing))
                position = current + (target - current) * k
            }
        }
        // Untracked: stay where it was and fade there.

        if out.engaged, position != nil {
            opacity = tuning.fadeIn > 0 ? min(1, opacity + Float(dt / tuning.fadeIn)) : 1
            if opacity == 0 { opacity = Float.ulpOfOne }   // first frame counts as shown
        } else {
            opacity = tuning.fadeOut > 0 ? max(0, opacity - Float(dt / tuning.fadeOut)) : 0
        }
        return out
    }

    public mutating func reset() {
        gate.reset()
        opacity = 0
        position = nil
        lastUpdate = nil
    }
}
