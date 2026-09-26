/*
 RAVE Engine — the thumb-pinch state machine.

 Three apps carried a copy of this: Spatialcraft, Longwave's
 `HandGestureEngine`, and Lambda's `HandMovement`. They agree on every tuning
 constant (2.5 cm engage / 4.5 cm release / 6 cm curl / 3 fingers = fist) and
 diverge only in what they do with the result — which is exactly the shape that
 belongs in a package.

 **Held state is primary; edges are derived.** The original only ever emitted a
 rising edge, which is lossy: a VR controller button has to stay *down* for the
 duration of a pinch, so Longwave's port had to re-derive held state that the
 original had already thrown away. The reverse reconstruction is free, so this
 publishes both and lets each consumer take what it needs.

 The three filters, all carried over verbatim:

 - **Fist suppressor** — a hand with `fistCurledFingerCount`+ fingertips within
   `fistCurlThreshold` of their metacarpals produces nothing. Stops a thumb
   brushing against curled fingers from firing a button.
 - **Hysteresis** — engage at `enterDistance`, release only at `exitDistance`,
   so jitter at the boundary cannot flap.
 - **Hold debounce** — a pinch must persist `holdThreshold` before it counts,
   so momentary brushes are ignored. Opt out with `engagesImmediately` when the
   hysteresis alone is the intended filter.

 Four more, added later to make accidental input rarer across every consumer
 (the original three let a pinch fire on the slightest provocation):

 - **Selection margin** — the nearest finger engages only when the runner-up
   is at least `selectionMargin` farther from the thumb. Adjacent fingertips
   sit close enough that a thumb+middle pinch can put the index inside its
   engage radius too; nearest-wins with no margin read one as the other
   (Oneiros saw thumb+index recorded as thumb+middle — a *break* instead of a
   *place*). An ambiguous hand produces nothing rather than a coin toss.
 - **Finger-switch hysteresis** — a held pinch is not dropped just because a
   different finger came inside the engage radius. The other finger has to
   beat the held one by `selectionMargin` and keep beating it for
   `fingerSwitchHold` before the pinch re-targets. The original released the
   instant a neighbour crossed the threshold, emitting end+begin on the jitter.
 - **Tracking-loss grace** — `update(sample: nil,…)` keeps the state for
   `trackingLossGrace` before releasing. ARKit drops a hand for a frame or two
   routinely (occlusion, a fast turn), and a VR button that flickers up and
   down there is a double press. Deliberate suppression is *not* tracking loss:
   use `forceRelease()` for that — it is immediate.
 - **Closing speed** (off by default) — when `minClosingSpeed` is set, a pinch
   engages only if that finger was recently closing on the thumb at that speed,
   so a hand drifting slowly into pinch range while relaxed does not fire.

 This type is a `struct` on purpose: one detector per hand, stored by value in
 whatever owns the hand loop, with no isolation of its own. That is what lets
 the same code serve a `@MainActor` tracker and a render-thread poll without
 either side converting.
 */

import Foundation
import simd


/// Thresholds for the pinch state machine. All distances in meters.
public struct RAVEPinchTuning: Sendable, Equatable {
    /// Thumb-to-fingertip distance at which a pinch engages.
    public var enterDistance: Float
    /// Distance at which an engaged pinch releases. Must exceed `enterDistance` —
    /// the gap between them is the hysteresis band.
    public var exitDistance: Float
    /// How long a pinch must persist before it counts as held.
    public var holdThreshold: TimeInterval
    /// Fingertip-to-metacarpal distance below which a finger reads as curled.
    public var fistCurlThreshold: Float
    /// How many curled fingers make a fist (and so suppress all pinches).
    public var fistCurledFingerCount: Int
    /// When true a pinch is held on the very frame it engages, and
    /// `holdThreshold` is ignored. The enter/exit hysteresis is then the only
    /// filter — right for a locomotion clutch, where a debounce reads as lag.
    public var engagesImmediately: Bool
    /// Which fingers may pinch, in priority order. The nearest of these to the
    /// thumb wins, subject to `selectionMargin`. Ordered rather than a `Set` so
    /// ties break deterministically.
    public var candidateFingers: [RAVEHandFinger]
    /// How much farther from the thumb the runner-up candidate must be than the
    /// nearest for the nearest to engage, and how much a different finger must
    /// beat a held one by to take over. Zero restores nearest-wins.
    ///
    /// 1 cm: on a real hand a firm pinch puts the pinching tip within ~1 cm
    /// of the thumb and the neighbouring tip 2+ cm away; a hand where the two
    /// are within a centimetre of each other is genuinely ambiguous.
    public var selectionMargin: Float
    /// How long a different finger must keep beating the held one (by
    /// `selectionMargin`, inside `enterDistance`) before the pinch re-targets.
    /// Until then the held pinch stays held. Zero re-targets on the first frame.
    public var fingerSwitchHold: TimeInterval
    /// How long a nil sample (hand untracked) keeps the current state before it
    /// releases. Zero releases on the first nil, which was the original rule.
    public var trackingLossGrace: TimeInterval
    /// When set, the pinching finger must have closed on the thumb at least
    /// this fast (m/s) within `closingWindow` before the pinch may engage.
    /// `nil` (the default) disables the check.
    public var minClosingSpeed: Float?
    /// How recently the closing speed must have been seen.
    public var closingWindow: TimeInterval

    public init(
        enterDistance: Float = 0.025,
        exitDistance: Float = 0.045,
        holdThreshold: TimeInterval = 0.10,
        fistCurlThreshold: Float = 0.06,
        fistCurledFingerCount: Int = 3,
        engagesImmediately: Bool = false,
        candidateFingers: [RAVEHandFinger] = RAVEHandFinger.allCases,
        selectionMargin: Float = 0.01,
        fingerSwitchHold: TimeInterval = 0.10,
        trackingLossGrace: TimeInterval = 0.12,
        minClosingSpeed: Float? = nil,
        closingWindow: TimeInterval = 0.2
    ) {
        self.enterDistance = enterDistance
        self.exitDistance = exitDistance
        self.holdThreshold = holdThreshold
        self.fistCurlThreshold = fistCurlThreshold
        self.fistCurledFingerCount = fistCurledFingerCount
        self.engagesImmediately = engagesImmediately
        self.candidateFingers = candidateFingers
        self.selectionMargin = selectionMargin
        self.fingerSwitchHold = fingerSwitchHold
        self.trackingLossGrace = trackingLossGrace
        self.minClosingSpeed = minClosingSpeed
        self.closingWindow = closingWindow
    }

    /// Any finger may pinch, with a 100 ms debounce, a 1 cm selection margin,
    /// 100 ms finger-switch hysteresis and 120 ms tracking-loss grace. What a
    /// gesture-to-button mapping wants: a misfire presses something.
    public static let standard = RAVEPinchTuning()

    /// The original, filter-light behaviour: nearest finger wins, a neighbour
    /// crossing the engage radius drops the held pinch at once, and losing
    /// tracking releases on the first nil. Kept for comparison and for a
    /// consumer that needs the old timing exactly.
    public static let legacy = RAVEPinchTuning(
        selectionMargin: 0,
        fingerSwitchHold: 0,
        trackingLossGrace: 0
    )

    /// Index finger only, engaging the instant the fingers touch. What a
    /// locomotion clutch wants: a debounce there is felt as input lag, and the
    /// hysteresis already rejects accidental contact. Lambda's movement hand
    /// relies on the instant engage; the grace keeps a one-frame tracking drop
    /// from stopping the player.
    public static let clutch = RAVEPinchTuning(
        holdThreshold: 0,
        engagesImmediately: true,
        candidateFingers: [.index]
    )

    /// Index finger only, with a 150 ms hold before it counts — a locomotion
    /// joystick that should not lurch on a brushed thumb. Heavier than the
    /// button debounce because a false engage here moves the player, and the
    /// lag is hidden by the stick having to travel out of its deadzone anyway.
    public static let joystick = RAVEPinchTuning(
        holdThreshold: 0.15,
        candidateFingers: [.index]
    )
}

/// What one hand is doing this frame.
public struct RAVEPinchOutput: Sendable, Equatable {
    /// The sustained, debounced pinch, or nil. This is the primary signal.
    public var held: RAVEHandFinger?
    /// How long `held` has been pinched, measured from first contact (so it
    /// includes the debounce window). Zero when nothing is held.
    public var heldDuration: TimeInterval
    /// Set on the frame `held` became non-nil — the rising edge.
    public var began: RAVEHandFinger?
    /// Set on the frame a previously-held pinch stopped, for any reason
    /// (released, fist, finger switched, tracking lost past the grace). May be
    /// set together with `began` on a finger switch.
    public var ended: RAVEHandFinger?
    /// True while the fist suppressor is engaged.
    public var isFist: Bool
    /// Nearest candidate finger to the thumb and its distance, whether or not a
    /// pinch is engaged. Exposed for on-device diagnostics — every app had an
    /// ad-hoc readout of exactly this.
    public var nearestFinger: RAVEHandFinger
    public var nearestDistance: Float
    public var curledFingerCount: Int
    /// Distance of the second-nearest candidate, `.infinity` with one candidate.
    public var runnerUpDistance: Float
    /// True when the nearest and runner-up are within `selectionMargin` of each
    /// other, so a fresh pinch was refused as ambiguous.
    public var isAmbiguous: Bool
    /// True while the hand is untracked and the state is being held through
    /// the tracking-loss grace.
    public var inTrackingGrace: Bool

    public init(
        held: RAVEHandFinger? = nil,
        heldDuration: TimeInterval = 0,
        began: RAVEHandFinger? = nil,
        ended: RAVEHandFinger? = nil,
        isFist: Bool = false,
        nearestFinger: RAVEHandFinger = .index,
        nearestDistance: Float = .infinity,
        curledFingerCount: Int = 0,
        runnerUpDistance: Float = .infinity,
        isAmbiguous: Bool = false,
        inTrackingGrace: Bool = false
    ) {
        self.held = held
        self.heldDuration = heldDuration
        self.began = began
        self.ended = ended
        self.isFist = isFist
        self.nearestFinger = nearestFinger
        self.nearestDistance = nearestDistance
        self.curledFingerCount = curledFingerCount
        self.runnerUpDistance = runnerUpDistance
        self.isAmbiguous = isAmbiguous
        self.inTrackingGrace = inTrackingGrace
    }

    /// The rising edge as a routable event, once a chirality is attached.
    public func pinchEvent(for chirality: RAVEHandChirality) -> RAVEHandPinchEvent? {
        began.map { RAVEHandPinchEvent(chirality: chirality, finger: $0) }
    }
}

/// Per-hand pinch state machine. Feed it one sample per frame.
public struct RAVEPinchDetector: Sendable {
    public var tuning: RAVEPinchTuning

    private struct Engaged: Equatable {
        var finger: RAVEHandFinger
        var startTime: TimeInterval
        var fired: Bool
    }
    private var engaged: Engaged?
    /// A different finger currently beating the held one, and since when.
    private var switchCandidate: (finger: RAVEHandFinger, since: TimeInterval)?
    /// When the current run of nil samples began.
    private var lostSince: TimeInterval?
    /// Per-finger thumb distance on the previous tracked frame, and when each
    /// finger was last seen closing at `minClosingSpeed`. Fixed-size SIMD so
    /// the render-thread consumer pays no allocation.
    private var lastDistances = SIMD4<Float>(repeating: .infinity)
    private var lastSampleTime: TimeInterval?
    private var lastFastClose = SIMD4<Double>(repeating: -.infinity)

    public init(tuning: RAVEPinchTuning = .standard) {
        self.tuning = tuning
    }

    /// The finger currently held, without advancing the machine.
    public var heldFinger: RAVEHandFinger? {
        guard let engaged, engaged.fired else { return nil }
        return engaged.finger
    }

    /// Drop all state without reporting an edge. Use when the hand is
    /// deliberately taken out of play and the caller does not need the edge;
    /// `forceRelease()` does the same and reports it.
    public mutating func reset() {
        engaged = nil
        switchCandidate = nil
        lostSince = nil
        lastDistances = SIMD4(repeating: .infinity)
        lastSampleTime = nil
        lastFastClose = SIMD4(repeating: -.infinity)
    }

    /// Release immediately, reporting the falling edge if something was held.
    /// This is the call for deliberate suppression (a panel took the hand, a
    /// mode change): unlike `update(sample: nil,…)` it does not wait out the
    /// tracking-loss grace.
    @discardableResult
    public mutating func forceRelease() -> RAVEPinchOutput {
        let wasHeld = heldFinger
        reset()
        return RAVEPinchOutput(ended: wasHeld)
    }

    /// Advance one frame. Pass `nil` when the hand is not tracked; the state is
    /// kept for `tuning.trackingLossGrace`, then any held pinch releases with a
    /// falling edge. Use `forceRelease()` for deliberate suppression.
    @discardableResult
    public mutating func update(sample: RAVEHandSample?, now: TimeInterval) -> RAVEPinchOutput {
        let wasHeld = heldFinger

        guard let sample else {
            // Nothing to hold through: stay clean.
            guard engaged != nil else {
                reset()
                return RAVEPinchOutput()
            }
            if lostSince == nil { lostSince = now }
            if let lostSince, now - lostSince < tuning.trackingLossGrace {
                // A switch in progress cannot be judged blind.
                switchCandidate = nil
                var output = RAVEPinchOutput(held: wasHeld, inTrackingGrace: true)
                if wasHeld != nil, let engaged { output.heldDuration = max(0, now - engaged.startTime) }
                return output
            }
            reset()
            return RAVEPinchOutput(ended: wasHeld)
        }
        lostSince = nil

        let curled = sample.curledFingerCount(threshold: tuning.fistCurlThreshold)

        // Distances for every finger (indexed by raw value), and the closing
        // speed bookkeeping that needs them.
        var distances = SIMD4<Float>(repeating: .infinity)
        for finger in RAVEHandFinger.allCases {
            distances[finger.rawValue] = sample.pinchDistance(to: finger)
        }
        if let minSpeed = tuning.minClosingSpeed, let last = lastSampleTime {
            let dt = Float(now - last)
            // A long gap means the previous distances describe another moment.
            if dt > 1e-4, dt < 0.25 {
                for finger in RAVEHandFinger.allCases {
                    let i = finger.rawValue
                    let closing = (lastDistances[i] - distances[i]) / dt
                    if closing.isFinite, closing >= minSpeed { lastFastClose[i] = now }
                }
            }
        }
        lastDistances = distances
        lastSampleTime = now

        var nearestFinger = tuning.candidateFingers.first ?? .index
        var nearestDistance = Float.infinity
        var runnerUp = Float.infinity
        for finger in tuning.candidateFingers {
            let distance = distances[finger.rawValue]
            if distance < nearestDistance {
                runnerUp = nearestDistance
                nearestDistance = distance
                nearestFinger = finger
            } else if distance < runnerUp {
                runnerUp = distance
            }
        }
        let margin = max(tuning.selectionMargin, 0)
        let ambiguous = runnerUp - nearestDistance < margin

        var output = RAVEPinchOutput(
            ended: nil,
            isFist: curled >= tuning.fistCurledFingerCount,
            nearestFinger: nearestFinger,
            nearestDistance: nearestDistance,
            curledFingerCount: curled,
            runnerUpDistance: runnerUp,
            isAmbiguous: ambiguous
        )

        if output.isFist {
            engaged = nil
            switchCandidate = nil
            output.ended = wasHeld
            return output
        }

        func closingOK(_ finger: RAVEHandFinger) -> Bool {
            guard tuning.minClosingSpeed != nil else { return true }
            return now - lastFastClose[finger.rawValue] <= tuning.closingWindow
        }
        func canStart(_ finger: RAVEHandFinger) -> Bool {
            nearestDistance < tuning.enterDistance && !ambiguous && closingOK(finger)
        }

        var began: RAVEHandFinger?
        var ended: RAVEHandFinger?

        if var active = engaged {
            let ownDistance = distances[active.finger.rawValue]
            // A different finger inside the engage radius, clearly nearer than
            // the held one.
            let challenger: RAVEHandFinger? =
                nearestFinger != active.finger
                    && nearestDistance < tuning.enterDistance
                    && ownDistance - nearestDistance >= margin
                ? nearestFinger : nil

            if ownDistance > tuning.exitDistance {
                // Released on the exit hysteresis. A challenger inside the
                // engage radius starts fresh (it goes through its own debounce).
                engaged = nil
                switchCandidate = nil
                if canStart(nearestFinger) {
                    engaged = Engaged(finger: nearestFinger, startTime: now,
                                      fired: tuning.engagesImmediately)
                }
            } else if !active.fired {
                // Still debouncing: nothing has been reported, so there is no
                // held state to protect. Ambiguity cancels; a clear challenger
                // restarts the debounce on its own finger.
                if let challenger, canStart(challenger) {
                    engaged = Engaged(finger: challenger, startTime: now,
                                      fired: tuning.engagesImmediately)
                } else if ambiguous && nearestDistance < tuning.enterDistance {
                    engaged = nil
                } else if now - active.startTime >= tuning.holdThreshold {
                    active.fired = true
                    engaged = active
                }
                switchCandidate = nil
            } else if let challenger {
                // Held, and another finger is beating it: re-target only once
                // that has persisted.
                if switchCandidate?.finger != challenger {
                    switchCandidate = (challenger, now)
                }
                if let candidate = switchCandidate, now - candidate.since >= tuning.fingerSwitchHold {
                    ended = active.finger
                    let persisted = now - candidate.since
                    engaged = Engaged(
                        finger: challenger,
                        startTime: candidate.since,
                        fired: tuning.engagesImmediately || persisted >= tuning.holdThreshold
                    )
                    switchCandidate = nil
                }
            } else {
                switchCandidate = nil
            }
        } else if canStart(nearestFinger) {
            engaged = Engaged(
                finger: nearestFinger,
                startTime: now,
                fired: tuning.engagesImmediately
            )
        }

        let nowHeld = heldFinger
        output.held = nowHeld
        if let nowHeld, let engaged {
            output.heldDuration = max(0, now - engaged.startTime)
            if wasHeld != nowHeld { began = nowHeld }
        }
        if let wasHeld, wasHeld != nowHeld { ended = wasHeld }
        output.began = began
        output.ended = ended
        return output
    }
}
