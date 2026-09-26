/*
 RAVE Engine — the per-frame loop around the Quest calibration.

 `RAVEQuestCalibration` solves; `RAVEQuestHoldDetector` judges one hand. This
 is the glue that decides, every frame, what each pair is evidence of — the
 part that was a block of the Longwave PCVR host's frame loop and would
 otherwise be re-written by every app that adopts the Quest backend:

   1. Hold verdicts first: pair each tracked controller with the ARKit hand on
      the same side. The hand is holding the controller, so the pair is free —
      EXCEPT when it is not (controller on the desk), which is what the verdict
      exists to notice. A notHeld hand is not evidence of anything.
   2. Sampling: a pair that disagrees with a solved transform by more than
      `watchdogPairErrorMeters` is the watchdog's business, not the ring's —
      drift is what the continuous small corrections track, and a
      quarter-metre jump is never drift.
   3. Moved-desk watchdog: a transform whose fresh pairs disagree by a quarter
      metre for a sustained second is not drifting, it is wrong — the desk
      headset moved (or a restored transform describes another session). Start
      over rather than blending toward it.
   4. Feedback: the first solve asks for a double pulse ("calibration done,
      controllers live"), the second half 250 ms later.

 Isolation-free value type, clocked by the caller in milliseconds (non-zero:
 0 means "untimestamped" to the calibration ring).
 */

import simd

public struct RAVEQuestAlignment: Sendable {
    /// Transformed-pair distance past which a pair counts against the
    /// transform. Equal to the hold detector's agreement radius.
    public static let watchdogPairErrorMeters: Float = 0.25
    /// How long every checked pair must disagree before the transform resets.
    public static let watchdogHoldMs: UInt64 = 1000
    /// Gap between the two halves of the calibration-done pulse.
    public static let secondPulseDelayMs: UInt64 = 250

    /// One hand this frame: the raw Quest controller pose (Quest space) and the
    /// ARKit reference point for the same hand, if located.
    public struct HandObservation: Sendable {
        public var questTracked: Bool
        public var questPosition: SIMD3<Float>
        public var questRotation: simd_quatf
        public var reference: SIMD3<Float>?
        /// The reference's tracking confidence in (0, 1]. A weight, never a
        /// gate — see `RAVEQuestCalibration`.
        public var weight: Float

        public init(questTracked: Bool, questPosition: SIMD3<Float> = .zero,
                    questRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                    reference: SIMD3<Float>? = nil, weight: Float = 1) {
            self.questTracked = questTracked
            self.questPosition = questPosition
            self.questRotation = questRotation
            self.reference = reference
            self.weight = weight
        }
    }

    public struct StepResult: Sendable, Equatable {
        public var left: RAVEQuestHold = .held
        public var right: RAVEQuestHold = .held
        /// The transform (re)computed this step.
        public var solved = false
        /// The watchdog threw the transform away this step.
        public var watchdogReset = false
        /// Play one calibration pulse on both controllers now.
        public var pulse = false

        public init() {}

        public subscript(chirality: RAVEHandChirality) -> RAVEQuestHold {
            get { chirality == .left ? left : right }
            set { if chirality == .left { left = newValue } else { right = newValue } }
        }
    }

    public private(set) var calibration = RAVEQuestCalibration()
    private var hold = [RAVEQuestHoldDetector(), RAVEQuestHoldDetector()]
    /// The transform came from `restore` and no fresh pair has confirmed it yet.
    public private(set) var isWarmStart = false
    private var wasCalibrated = false
    private var badPairSinceMs: UInt64 = 0
    private var secondPulseDueMs: UInt64 = 0

    public init() {}

    public var isCalibrated: Bool { calibration.isCalibrated }

    public func verdict(_ chirality: RAVEHandChirality) -> RAVEQuestHold {
        hold[RAVEQuestCalibration.index(chirality)].state
    }

    /// Quest pose → reference space (identity until calibrated).
    public func apply(_ chirality: RAVEHandChirality, position: SIMD3<Float>,
                      rotation: simd_quatf) -> (position: SIMD3<Float>, rotation: simd_quatf) {
        calibration.apply(chirality, position: position, rotation: rotation)
    }

    /// Warm start from a persisted transform. Applied immediately but flagged
    /// until fresh pairs agree with it; if they do not, the watchdog resets it
    /// within `watchdogHoldMs`.
    public mutating func restore(_ transform: RAVEQuestCalibration.Transform) {
        calibration.restore(transform)
        isWarmStart = true
        wasCalibrated = true
    }

    /// Forget everything, including the hold verdicts.
    public mutating func reset() {
        self = RAVEQuestAlignment()
    }

    /// Advance only the pulse schedule — for frames with no fresh controller
    /// data, where pairing would be meaningless.
    public mutating func tickPulses(nowMs: UInt64) -> Bool {
        guard secondPulseDueMs != 0, nowMs >= secondPulseDueMs else { return false }
        secondPulseDueMs = 0
        return true
    }

    /// One frame of pairing, sampling, watchdog and solving.
    public mutating func step(left: HandObservation, right: HandObservation,
                              nowMs: UInt64) -> StepResult {
        var result = StepResult()
        result.pulse = tickPulses(nowMs: nowMs)

        var anyBadPair = false, anyPairChecked = false
        for (chirality, o) in [(RAVEHandChirality.left, left), (.right, right)] {
            let hand = RAVEQuestCalibration.index(chirality)
            var obs = RAVEQuestHoldDetector.Observation()
            obs.questTracked = o.questTracked
            if o.questTracked {
                obs.questPosition = calibration.apply(
                    chirality, position: o.questPosition, rotation: o.questRotation).position
            }
            if let reference = o.reference {
                obs.referenceValid = true
                obs.referencePosition = reference
            }
            obs.calibrated = calibration.isCalibrated
            let verdict = hold[hand].step(obs, nowMs: nowMs)
            result[chirality] = verdict

            guard o.questTracked, let reference = o.reference else { continue }
            if verdict == .notHeld { continue }   // desk, not evidence
            let pairError = calibration.pairErrorMeters(
                chirality, questPosition: o.questPosition, reference: reference)
            if calibration.isCalibrated {
                anyPairChecked = true
                if pairError > Self.watchdogPairErrorMeters {
                    anyBadPair = true
                    continue
                }
            }
            calibration.addSample(chirality, questPosition: o.questPosition,
                                  questRotation: o.questRotation, reference: reference,
                                  weight: o.weight, nowMs: nowMs)
        }

        if anyPairChecked {
            if anyBadPair {
                if badPairSinceMs == 0 {
                    badPairSinceMs = nowMs
                } else if nowMs - badPairSinceMs > Self.watchdogHoldMs {
                    calibration.reset()
                    wasCalibrated = false
                    isWarmStart = false
                    badPairSinceMs = 0
                    result.watchdogReset = true
                }
            } else {
                badPairSinceMs = 0
                isWarmStart = false   // fresh pairs agree: the restore is confirmed
            }
        }

        if calibration.maybeSolve(nowMs: nowMs) {
            result.solved = true
            if !wasCalibrated {
                wasCalibrated = true
                result.pulse = true
                secondPulseDueMs = nowMs + Self.secondPulseDelayMs
            }
        }
        return result
    }
}
