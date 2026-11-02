/*
 RAVE Engine — arm-swing walking as an option a game switches on.

 `RAVEArmSwinger` is the sensing: both fists plus a swing pattern engage it, and
 its output has the joystick's shape. This is the policy around it that
 LambdaVision wrote and Longwave's `armSwing` profile wanted again: whether the
 player has it on, how hard they must swing, which way it walks, and when it
 must stand down. **It is off by default.** A game that never sets
 `isEnabled` never sees the swinger move, and pays nothing for it.

 What it keeps for the game:

 - **Enabled, sensitivity, direction.** `sensitivity` scales how hard you have
   to swing, never the speed you reach (`RAVEArmSwingTuning.scaled`).
   `followsHands` walks where the fists point rather than where the head does.
 - **Standing down.** Pass `active: false` while something else owns
   locomotion (a held pinch clutch, a menu). The swinger resets and has to
   engage from scratch afterwards.
 - **Which hand the swing wants.** `wantsHand(_:)` is true for a hand that is
   swinging; before a run starts it is also true for a gun hand whose partner
   is already a fist, so the way into a swing — the index curls as the fist
   closes — cannot fire. Claim the hand from `RAVEHandOwnership` when it says
   so, and let that own the priority and the holdoff after the swing lets go;
   this type does not arbitrate.

 Value type, no isolation, time passed in, like the swinger it wraps.
 */

import Foundation
import simd

public struct RAVEArmSwingLocomotion: Sendable {
    /// Off by default: a game opts in.
    public var isEnabled: Bool
    /// Scales the effort of a swing, never the resulting speed. 1 = default.
    public var sensitivity: Float
    /// Walk where the fists point instead of where the head faces.
    public var followsHands: Bool
    /// Fingertip ↔ metacarpal distance (m) below which a finger counts as
    /// curled, for the off-hand fist test.
    public var fistCurlThreshold: Float
    /// How many curled fingers make a fist.
    public var fistFingerCount: Int

    /// The last update's output, or an idle one while disabled or stood down.
    public private(set) var output = RAVEArmSwingOutput()

    private var swinger = RAVEArmSwinger()
    private var partnerFist = false
    private var gunHand: RAVEHandChirality = .right

    public init(isEnabled: Bool = false, sensitivity: Float = 1, followsHands: Bool = false,
                fistCurlThreshold: Float = 0.06, fistFingerCount: Int = 3) {
        self.isEnabled = isEnabled
        self.sensitivity = sensitivity
        self.followsHands = followsHands
        self.fistCurlThreshold = fistCurlThreshold
        self.fistFingerCount = fistFingerCount
    }

    /// Advance the swing one frame.
    ///
    /// - Parameters:
    ///   - active: false while something else owns locomotion; resets the swing.
    ///   - gunHand: the hand that holds the weapon, which can leave the swing
    ///     to aim while the other arm keeps running.
    ///   - basis: the head's planar axes in the same tracking space as the hands.
    @discardableResult
    public mutating func update(
        active: Bool,
        left: RAVEHandSample?,
        right: RAVEHandSample?,
        headPosition: SIMD3<Float>,
        basis: RAVEPlanarBasis,
        gunHand: RAVEHandChirality,
        now: TimeInterval
    ) -> RAVEArmSwingOutput {
        self.gunHand = gunHand
        guard isEnabled, active else {
            reset()
            return output
        }
        swinger.tuning = RAVEArmSwingTuning().scaled(sensitivity: sensitivity)
        swinger.direction = followsHands ? .hands : .head
        output = swinger.update(left: left, right: right, headPosition: headPosition,
                                basis: basis, now: now)
        let partner = gunHand == .left ? right : left
        partnerFist = partner.map { $0.curledFingerCount(threshold: fistCurlThreshold) >= fistFingerCount } ?? false
        return output
    }

    /// Whether the swing wants `hand` this frame. See the header: a hand that
    /// is swinging, and — before a run starts — the gun hand whose partner is
    /// already a fist.
    public func wantsHand(_ hand: RAVEHandChirality) -> Bool {
        guard isEnabled else { return false }
        let swinging = hand == .left ? output.leftSwinging : output.rightSwinging
        if output.engaged { return swinging }
        return hand == gunHand && partnerFist
    }

    /// Drop all state: swing output, engagement, the fist reading.
    public mutating func reset() {
        swinger.reset()
        output = RAVEArmSwingOutput()
        partnerFist = false
    }
}
