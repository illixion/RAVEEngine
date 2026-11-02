/*
 RAVE Engine — the finger gun's trigger: curl the index to pull, extend it to release.

 The index is measured as an extension ratio (tip ↔ knuckle over palm length;
 `RAVEHandSample.indexExtensionRatio`), low when curled. The trigger pulls
 below `pullBelow` and releases above `releaseAbove`; between them it **holds
 whatever it was doing**, which is what stops tracking noise at the threshold
 chattering the button.

 **A trigger must never stick.** When the gesture is off, a menu is up, an arm
 swing owns the hand, or the hand sample is gone, it releases at once, so a hand
 lost mid-pull cannot leave fire held. It answers with an edge (`RAVEEdge`) so a
 consumer that sends commands to an engine sends them only on a press or a
 release, not every frame.

 The same 0.55 / 0.75 pair is `RAVEThumbGestures.Tuning.indexCurled` and
 `.indexExtended`, so the finger-gun posture and the trigger agree on what
 "curled" means; pass the one tuning to both.

 Value type, no isolation.
 */

import Foundation

public struct RAVEFingerGunTrigger: Sendable, Equatable {
    public struct Tuning: Sendable, Equatable {
        /// Extension below this pulls the trigger.
        public var pullBelow: Float = 0.55
        /// Extension above this releases it.
        public var releaseAbove: Float = 0.75

        public init(pullBelow: Float = 0.55, releaseAbove: Float = 0.75) {
            self.pullBelow = pullBelow
            self.releaseAbove = releaseAbove
        }
    }

    /// The trigger is pulled.
    public private(set) var isFiring = false

    public init() {}

    /// Advance one frame.
    ///
    /// - Parameters:
    ///   - indexExtension: the index's extension ratio, or nil when the hand is
    ///     lost (which releases).
    ///   - allowed: false while anything else owns the hand or the gesture is
    ///     off; releases at once.
    /// - Returns: `.began` on the frame the trigger is pulled, `.ended` on the
    ///   frame it is released, otherwise `.steady`.
    @discardableResult
    public mutating func update(indexExtension: Float?, allowed: Bool,
                                tuning: Tuning = Tuning()) -> RAVEEdge {
        var want = isFiring
        if allowed, let extensionRatio = indexExtension {
            if extensionRatio < tuning.pullBelow { want = true }
            else if extensionRatio > tuning.releaseAbove { want = false }
            // else: inside the hysteresis band, hold the current state.
        } else {
            want = false
        }
        defer { isFiring = want }
        if want == isFiring { return .steady }
        return want ? .began : .ended
    }

    /// The same, reading the ratio from a hand sample.
    @discardableResult
    public mutating func update(sample: RAVEHandSample?, allowed: Bool,
                                tuning: Tuning = Tuning()) -> RAVEEdge {
        update(indexExtension: sample?.indexExtensionRatio, allowed: allowed, tuning: tuning)
    }

    public mutating func reset() {
        isFiring = false
    }
}
