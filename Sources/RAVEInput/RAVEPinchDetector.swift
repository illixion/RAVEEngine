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
    /// thumb wins. Ordered rather than a `Set` so ties break deterministically.
    public var candidateFingers: [RAVEHandFinger]

    public init(
        enterDistance: Float = 0.025,
        exitDistance: Float = 0.045,
        holdThreshold: TimeInterval = 0.10,
        fistCurlThreshold: Float = 0.06,
        fistCurledFingerCount: Int = 3,
        engagesImmediately: Bool = false,
        candidateFingers: [RAVEHandFinger] = RAVEHandFinger.allCases
    ) {
        self.enterDistance = enterDistance
        self.exitDistance = exitDistance
        self.holdThreshold = holdThreshold
        self.fistCurlThreshold = fistCurlThreshold
        self.fistCurledFingerCount = fistCurledFingerCount
        self.engagesImmediately = engagesImmediately
        self.candidateFingers = candidateFingers
    }

    /// Any finger may pinch, with a 100 ms debounce. What a gesture-to-button
    /// mapping wants: a misfire presses something.
    public static let standard = RAVEPinchTuning()

    /// Index finger only, engaging the instant the fingers touch. What a
    /// locomotion clutch wants: a debounce there is felt as input lag, and the
    /// hysteresis already rejects accidental contact.
    public static let clutch = RAVEPinchTuning(
        holdThreshold: 0,
        engagesImmediately: true,
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
    /// (released, fist, finger crossed, tracking lost).
    public var ended: RAVEHandFinger?
    /// True while the fist suppressor is engaged.
    public var isFist: Bool
    /// Nearest candidate finger to the thumb and its distance, whether or not a
    /// pinch is engaged. Exposed for on-device diagnostics — every app had an
    /// ad-hoc readout of exactly this.
    public var nearestFinger: RAVEHandFinger
    public var nearestDistance: Float
    public var curledFingerCount: Int

    public init(
        held: RAVEHandFinger? = nil,
        heldDuration: TimeInterval = 0,
        began: RAVEHandFinger? = nil,
        ended: RAVEHandFinger? = nil,
        isFist: Bool = false,
        nearestFinger: RAVEHandFinger = .index,
        nearestDistance: Float = .infinity,
        curledFingerCount: Int = 0
    ) {
        self.held = held
        self.heldDuration = heldDuration
        self.began = began
        self.ended = ended
        self.isFist = isFist
        self.nearestFinger = nearestFinger
        self.nearestDistance = nearestDistance
        self.curledFingerCount = curledFingerCount
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

    public init(tuning: RAVEPinchTuning = .standard) {
        self.tuning = tuning
    }

    /// The finger currently held, without advancing the machine.
    public var heldFinger: RAVEHandFinger? {
        guard let engaged, engaged.fired else { return nil }
        return engaged.finger
    }

    /// Drop all state. Use when the hand is deliberately taken out of play
    /// (a suppressed hand, a mode change) rather than merely untracked — though
    /// `update(sample: nil,…)` does the same thing and also reports the edge.
    public mutating func reset() {
        engaged = nil
    }

    /// Advance one frame. Pass `nil` when the hand is not tracked or its input
    /// is suppressed; that releases any held pinch and reports the falling edge.
    @discardableResult
    public mutating func update(sample: RAVEHandSample?, now: TimeInterval) -> RAVEPinchOutput {
        let wasHeld = heldFinger

        guard let sample else {
            engaged = nil
            return RAVEPinchOutput(ended: wasHeld)
        }

        let curled = sample.curledFingerCount(threshold: tuning.fistCurlThreshold)

        var nearestFinger = tuning.candidateFingers.first ?? .index
        var nearestDistance = Float.infinity
        for finger in tuning.candidateFingers {
            let distance = sample.pinchDistance(to: finger)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestFinger = finger
            }
        }

        var output = RAVEPinchOutput(
            ended: nil,
            isFist: curled >= tuning.fistCurledFingerCount,
            nearestFinger: nearestFinger,
            nearestDistance: nearestDistance,
            curledFingerCount: curled
        )

        if output.isFist {
            engaged = nil
            output.ended = wasHeld
            return output
        }

        if var active = engaged {
            // Release on exit hysteresis, or when a *different* finger has come
            // inside the engage threshold — the user shifted fingers mid-gesture
            // and means the new one.
            let crossedFingers = nearestFinger != active.finger
                && nearestDistance < tuning.enterDistance
            if nearestDistance > tuning.exitDistance || crossedFingers {
                engaged = nil
            } else if !active.fired && (now - active.startTime) >= tuning.holdThreshold {
                active.fired = true
                engaged = active
            }
        } else if nearestDistance < tuning.enterDistance {
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
            if wasHeld == nil { output.began = nowHeld }
        }
        if wasHeld != nil && nowHeld == nil { output.ended = wasHeld }
        return output
    }
}
