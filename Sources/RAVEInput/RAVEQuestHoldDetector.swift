/*
 RAVE Engine — is this Quest controller actually in that hand?

 Continuous calibration pairs "the Quest's controller pose" with "the ARKit
 hand on the same side" on the standing assumption that the user is holding
 the controller. The assumption fails in one everyday way: the controller is
 put down. The Quest keeps reporting it tracked (it is — on the desk), the hand
 keeps tracking (it is — waving elsewhere), and every frame now offers a pair
 of two honest poses that describe different objects. Left unguarded those
 pairs poison the transform, and worse, the moved-desk watchdog reads the
 disagreement as a moved headset and resets a calibration that was fine.

 So each hand gets a three-way verdict, from position agreement plus motion:

   held     — calibrated pair error small (they move as one object), or, while
              uncalibrated, no evidence against. Sample it, publish it.
   heldBad  — pair error large but the controller IS moving: either the desk
              headset moved (every pair breaks at once) or the transform went
              stale. This is the watchdog's case — let it count and reset.
   notHeld  — pair error large AND the controller sits still while the hand
              moves. That is a controller on a desk, not a broken transform:
              stop sampling, stop publishing the hand, and keep the watchdog
              away from it. The hand falls back to hand tracking until the
              controller moves again.

 The discriminator is motion, not error size: a desk bump and a put-down
 produce the same pair error, but only one of them leaves the controller
 stationary while the hand is demonstrably alive. Both transitions carry dwell
 times so a single blurred frame flips nothing.

 Ported from the Longwave PCVR host with its constants and tests. Isolation-free
 value type, clocked by the caller in milliseconds.
 */

import simd

/// The hold verdict for one controller.
public enum RAVEQuestHold: Sendable, Equatable {
    case held, heldBad, notHeld
}

public struct RAVEQuestHoldDetector: Sendable {
    /// Pair error below this is agreement ("moving as one object"); above it,
    /// disagreement. Matches the watchdog threshold.
    public static let agreeMeters: Float = 0.25
    /// "Sitting still" / "demonstrably alive", on EMA-smoothed speeds.
    public static let stillMps: Float = 0.05
    public static let movingMps: Float = 0.15
    /// Dwell before declaring a put-down / re-grab. Release is slower than
    /// grab on purpose: a lost sample costs nothing, a hand that flickers
    /// between pose sources costs immersion.
    public static let releaseDwellMs: UInt64 = 400
    public static let grabDwellMs: UInt64 = 250
    /// EMA time constant for the speed estimates.
    public static let speedTauMs: Float = 150

    public struct Observation: Sendable {
        /// The Quest says this controller is tracked.
        public var questTracked = false
        /// CALIBRATED controller position, reference space.
        public var questPosition = SIMD3<Float>.zero
        /// The reference hand was located this frame.
        public var referenceValid = false
        public var referencePosition = SIMD3<Float>.zero
        /// `questPosition` is comparable to `referencePosition` at all.
        public var calibrated = false

        public init(questTracked: Bool = false, questPosition: SIMD3<Float> = .zero,
                    referenceValid: Bool = false, referencePosition: SIMD3<Float> = .zero,
                    calibrated: Bool = false) {
            self.questTracked = questTracked
            self.questPosition = questPosition
            self.referenceValid = referenceValid
            self.referencePosition = referencePosition
            self.calibrated = calibrated
        }
    }

    /// Presumed held: the behaviour before this detector existed.
    public private(set) var state: RAVEQuestHold = .held

    private struct Tracked: Sendable {
        var position = SIMD3<Float>.zero
        var ms: UInt64 = 0
        var have = false
        var speed: Float = 0
    }

    private var quest = Tracked()
    private var reference = Tracked()
    private var releaseSinceMs: UInt64 = 0
    private var grabSinceMs: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func step(_ o: Observation, nowMs: UInt64) -> RAVEQuestHold {
        Self.updateSpeed(o.questTracked, o.questPosition, &quest, nowMs: nowMs)
        Self.updateSpeed(o.referenceValid, o.referencePosition, &reference, nowMs: nowMs)

        guard o.questTracked else {
            // No controller pose, no verdict — hold the current state. The
            // caller already refuses untracked controllers where it matters.
            releaseSinceMs = 0
            grabSinceMs = 0
            return state
        }

        guard o.calibrated else {
            // Bootstrap: no comparable positions yet, so the only usable
            // evidence is motion. A controller that moves is in somebody's
            // hand; the robust solve absorbs the occasional wrong guess.
            if state == .notHeld {
                if Self.dwell(quest.speed > Self.movingMps, &grabSinceMs, Self.grabDwellMs, nowMs) {
                    state = .held
                }
            } else {
                state = .held   // heldBad needs a pair error to mean anything
            }
            return state
        }

        guard o.referenceValid else {
            // A tracked controller with no hand to compare against: keep the
            // verdict. This is the common occluded case — the hand wrapped
            // around the controller — and dropping to notHeld here would starve
            // exactly the situation the controller exists for.
            releaseSinceMs = 0
            grabSinceMs = 0
            return state
        }

        let pairError = simd_distance(o.questPosition, o.referencePosition)
        if pairError <= Self.agreeMeters {
            releaseSinceMs = 0
            if state == .notHeld {
                if Self.dwell(true, &grabSinceMs, Self.grabDwellMs, nowMs) { state = .held }
            } else {
                state = .held
            }
            return state
        }

        grabSinceMs = 0
        let putDownSignature = quest.speed < Self.stillMps && reference.speed > Self.movingMps
        if putDownSignature {
            if Self.dwell(true, &releaseSinceMs, Self.releaseDwellMs, nowMs) {
                state = .notHeld
                return state
            }
        } else {
            releaseSinceMs = 0
        }
        // Disagreeing but not a put-down: the watchdog's case — unless we had
        // already concluded notHeld, in which case a stationary far-away
        // controller stays exactly that.
        if state != .notHeld { state = .heldBad }
        return state
    }

    public mutating func reset() {
        self = RAVEQuestHoldDetector()
    }

    private static func dwell(_ condition: Bool, _ sinceMs: inout UInt64, _ dwellMs: UInt64,
                              _ nowMs: UInt64) -> Bool {
        guard condition else {
            sinceMs = 0
            return false
        }
        if sinceMs == 0 { sinceMs = nowMs }
        return nowMs - sinceMs >= dwellMs
    }

    private static func updateSpeed(_ valid: Bool, _ position: SIMD3<Float>, _ t: inout Tracked,
                                    nowMs: UInt64) {
        guard valid else {
            t.have = false   // don't difference across a gap
            return
        }
        if t.have && nowMs > t.ms {
            let dtMs = Float(nowMs - t.ms)
            let instant = simd_distance(position, t.position) / (dtMs * 0.001)
            let alpha = 1 - exp(-dtMs / speedTauMs)
            t.speed += alpha * (instant - t.speed)
        }
        t.position = position
        t.ms = nowMs
        t.have = true
    }
}
