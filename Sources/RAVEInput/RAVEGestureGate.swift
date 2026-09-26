/*
 RAVE Engine — a generic engage/release gate for continuous gesture signals.

 Every app built this state machine by hand, several times over: Longwave's
 1.5 s hold-to-open menu, Lambda's thumb-curl reload (hysteresis on the thumb
 metric, a 750 ms charge with a progress ring, latched until the thumb
 re-extends), Lambda's finger-gun trigger, Oneiros's palm-up wrist HUD with its
 0.4 s linger, Longwave's palm-facing panel. They are all the same shape:

   idle ──(value past `enter`, allowed)──▶ charging ──(held `holdToEngage`)──▶ engaged
     ▲                                        │                                  │
     └────────────(lapsed / disallowed)───────┘        (past `exit`, or disallowed)
                                                                                 ▼
     idle ◀──────────(still lapsed after `releaseGrace`)────────────────── releasing

 - **Hysteresis** — engage at `enter`, release only past `exit`. The band
   between them is what stops a signal resting on the threshold from flapping.
 - **Hold to engage** — the signal must stay in (inside the `exit` band) for
   `holdToEngage` before it engages; `progress` runs 0…1 across that window for
   a charge ring. Zero engages on the first qualifying frame.
 - **Release grace** — once engaged, a lapse must last `releaseGrace` before it
   releases. A lapse that recovers inside it never happened. This is the
   "linger" of a palm-up panel, and it also absorbs tracking dropouts.
 - **Re-arm delay** — after a release, the gate will not start charging again
   for `rearmDelay`, so one long gesture cannot chain-fire.
 - **Conditions** — the caller evaluates its own predicates (hand in view, no
   pinch held, index extended…) and passes them as `engageAllowed` (needed to
   start and to finish charging) and `holdAllowed` (needed to stay engaged).
   Passing `false` for `holdAllowed` counts as a lapse, subject to the grace.

 A nil value (no reading this frame, e.g. an untracked hand) counts as a lapse.
 Pure value type, no isolation, timestamps passed in: it runs on Lambda's
 render thread and Longwave's datagram loop as well as the main actor.
 */

import Foundation

/// Which side of the thresholds is "in".
public enum RAVEGateSense: String, Sendable, Equatable {
    /// In when the value is high: engage at `value >= enter`, release at
    /// `value < exit`, with `exit <= enter`. E.g. palm facing.
    case rising
    /// In when the value is low: engage at `value <= enter`, release at
    /// `value > exit`, with `exit >= enter`. E.g. a curl ratio or a distance.
    case falling
}

/// Thresholds and timing for a `RAVEGestureGate`.
public struct RAVEGestureGateTuning: Sendable, Equatable {
    public var sense: RAVEGateSense
    /// Threshold the value must reach to start engaging.
    public var enter: Float
    /// Threshold past which an engaged (or charging) gate lapses.
    public var exit: Float
    /// How long the signal must stay in before the gate engages.
    public var holdToEngage: TimeInterval
    /// How long a lapse must last before an engaged gate releases.
    public var releaseGrace: TimeInterval
    /// How long after a release before charging may begin again.
    public var rearmDelay: TimeInterval

    public init(
        sense: RAVEGateSense = .rising,
        enter: Float,
        exit: Float,
        holdToEngage: TimeInterval = 0,
        releaseGrace: TimeInterval = 0,
        rearmDelay: TimeInterval = 0
    ) {
        self.sense = sense
        self.enter = enter
        self.exit = exit
        self.holdToEngage = holdToEngage
        self.releaseGrace = releaseGrace
        self.rearmDelay = rearmDelay
    }

    /// A boolean signal (fed through `update(active:now:)`) that must be held
    /// for `seconds` — Longwave's 1.5 s hold-to-open menu is `hold(1.5)`.
    public static func hold(_ seconds: TimeInterval,
                            releaseGrace: TimeInterval = 0) -> RAVEGestureGateTuning {
        RAVEGestureGateTuning(sense: .rising, enter: 0.5, exit: 0.5,
                              holdToEngage: seconds, releaseGrace: releaseGrace)
    }
}

/// Where the gate is in its cycle.
public enum RAVEGatePhase: String, Sendable, Equatable {
    case idle
    /// In, waiting out `holdToEngage`. `progress` rises across it.
    case charging
    case engaged
    /// Engaged, lapsed, waiting out `releaseGrace`. Still reports engaged.
    case releasing
}

/// The gate's reading for one frame.
public struct RAVEGestureGateOutput: Sendable, Equatable {
    /// True while engaged, including through the release grace.
    public var engaged: Bool
    /// Set on the frame the gate engaged.
    public var began: Bool
    /// Set on the frame the gate released.
    public var ended: Bool
    /// 0…1 across the hold-to-engage window; 1 while engaged; 0 when idle.
    public var progress: Float
    public var phase: RAVEGatePhase
    /// How long the gate has been engaged. Zero unless engaged.
    public var engagedDuration: TimeInterval

    public init(
        engaged: Bool = false,
        began: Bool = false,
        ended: Bool = false,
        progress: Float = 0,
        phase: RAVEGatePhase = .idle,
        engagedDuration: TimeInterval = 0
    ) {
        self.engaged = engaged
        self.began = began
        self.ended = ended
        self.progress = progress
        self.phase = phase
        self.engagedDuration = engagedDuration
    }
}

/// Generic engage/release state machine. One per gesture.
public struct RAVEGestureGate: Sendable, Equatable {
    public var tuning: RAVEGestureGateTuning

    public private(set) var phase: RAVEGatePhase = .idle
    private var chargeSince: TimeInterval = 0
    private var engagedSince: TimeInterval = 0
    private var lapsedSince: TimeInterval = 0
    private var releasedAt: TimeInterval = -.infinity

    public init(tuning: RAVEGestureGateTuning) {
        self.tuning = tuning
    }

    public var isEngaged: Bool { phase == .engaged || phase == .releasing }

    /// Drop to idle without reporting an edge, and without a re-arm delay.
    public mutating func reset() {
        phase = .idle
        releasedAt = -.infinity
    }

    /// Release now, reporting the edge if the gate was engaged. Starts the
    /// re-arm delay like a natural release.
    @discardableResult
    public mutating func forceRelease(now: TimeInterval) -> RAVEGestureGateOutput {
        let wasEngaged = isEngaged
        phase = .idle
        if wasEngaged { releasedAt = now }
        return RAVEGestureGateOutput(ended: wasEngaged)
    }

    /// Boolean form: `active` is the signal itself. Thresholds are ignored
    /// beyond their sense; use `RAVEGestureGateTuning.hold(_:)` or any tuning
    /// whose `enter` is between 0 and 1 for `.rising`.
    @discardableResult
    public mutating func update(active: Bool, now: TimeInterval,
                                engageAllowed: Bool = true,
                                holdAllowed: Bool = true) -> RAVEGestureGateOutput {
        let isIn: Bool? = active
        return advance(entered: isIn, stillIn: isIn, now: now,
                       engageAllowed: engageAllowed, holdAllowed: holdAllowed)
    }

    /// Advance one frame with a continuous value, or `nil` for no reading.
    @discardableResult
    public mutating func update(value: Float?, now: TimeInterval,
                                engageAllowed: Bool = true,
                                holdAllowed: Bool = true) -> RAVEGestureGateOutput {
        guard let value, value.isFinite else {
            return advance(entered: nil, stillIn: nil, now: now,
                           engageAllowed: engageAllowed, holdAllowed: holdAllowed)
        }
        let entered: Bool
        let stillIn: Bool
        switch tuning.sense {
        case .rising:
            entered = value >= tuning.enter
            stillIn = value >= tuning.exit
        case .falling:
            entered = value <= tuning.enter
            stillIn = value <= tuning.exit
        }
        return advance(entered: entered, stillIn: stillIn, now: now,
                       engageAllowed: engageAllowed, holdAllowed: holdAllowed)
    }

    private mutating func advance(entered: Bool?, stillIn: Bool?, now: TimeInterval,
                                  engageAllowed: Bool, holdAllowed: Bool) -> RAVEGestureGateOutput {
        var out = RAVEGestureGateOutput()
        let entering = (entered ?? false) && engageAllowed
        let charging = (stillIn ?? false) && engageAllowed
        let holding = (stillIn ?? false) && holdAllowed

        func engage() {
            phase = .engaged
            engagedSince = now
            out.began = true
        }

        switch phase {
        case .idle:
            if entering, now - releasedAt >= tuning.rearmDelay {
                if tuning.holdToEngage <= 0 {
                    engage()
                } else {
                    phase = .charging
                    chargeSince = now
                }
            }
        case .charging:
            if !charging {
                phase = .idle
            } else if now - chargeSince >= tuning.holdToEngage {
                engage()
            }
        case .engaged:
            if !holding {
                if tuning.releaseGrace <= 0 {
                    phase = .idle
                    releasedAt = now
                    out.ended = true
                } else {
                    phase = .releasing
                    lapsedSince = now
                }
            }
        case .releasing:
            if holding {
                phase = .engaged
            } else if now - lapsedSince >= tuning.releaseGrace {
                phase = .idle
                releasedAt = now
                out.ended = true
            }
        }

        out.phase = phase
        switch phase {
        case .idle:
            out.progress = 0
        case .charging:
            out.progress = Float(min(max((now - chargeSince) / max(tuning.holdToEngage, 1e-6), 0), 1))
        case .engaged, .releasing:
            out.engaged = true
            out.progress = 1
            out.engagedDuration = max(0, now - engagedSince)
        }
        return out
    }
}
