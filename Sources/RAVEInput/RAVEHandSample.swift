/*
 RAVE Engine — one frame of hand joint positions, framework-free.

 This is the seam that makes the pinch detector, the joystick and the palm
 geometry testable. All three apps previously did the same thing: pull a
 handful of joints out of an ARKit `HandSkeleton`, immediately do float math on
 them, and bury that math inside a type that could not be constructed without a
 live headset. Splitting the *sampling* from the *interpretation* means the
 interpretation is now ordinary arithmetic over a struct you can write down.

 Positions are world-space (whatever "world" the producer reports in — ARKit's
 origin for the visionOS sensor). Nothing here assumes a coordinate convention
 beyond "these are all in the same frame as each other".
 */

import simd

/// The three joints of one finger that the input layer cares about.
///
/// `metacarpal` is the knuckle at the *base of the hand* — the tip-to-metacarpal
/// distance is what tells a curled finger from an extended one, and so what
/// drives the fist suppressor. `knuckle` is the proximal joint, used for the
/// palm plane.
public struct RAVEFingerJoints: Sendable, Equatable {
    public var tip: SIMD3<Float>
    public var metacarpal: SIMD3<Float>
    public var knuckle: SIMD3<Float>

    public init(tip: SIMD3<Float>, metacarpal: SIMD3<Float>, knuckle: SIMD3<Float>) {
        self.tip = tip
        self.metacarpal = metacarpal
        self.knuckle = knuckle
    }

    /// How extended the finger is, in meters, tip to hand-base knuckle.
    public var extension_: Float { simd_distance(tip, metacarpal) }
}

/// A single frame of one hand's joint positions.
///
/// Deliberately fixed-shape rather than a dictionary: this is sampled every
/// frame on a render thread in at least one consumer, and a per-frame heap
/// allocation there is not free.
public struct RAVEHandSample: Sendable, Equatable {
    public var wrist: SIMD3<Float>
    public var thumbTip: SIMD3<Float>
    public var thumbKnuckle: SIMD3<Float>
    public var index: RAVEFingerJoints
    public var middle: RAVEFingerJoints
    public var ring: RAVEFingerJoints
    public var little: RAVEFingerJoints

    public init(
        wrist: SIMD3<Float>,
        thumbTip: SIMD3<Float>,
        thumbKnuckle: SIMD3<Float>,
        index: RAVEFingerJoints,
        middle: RAVEFingerJoints,
        ring: RAVEFingerJoints,
        little: RAVEFingerJoints
    ) {
        self.wrist = wrist
        self.thumbTip = thumbTip
        self.thumbKnuckle = thumbKnuckle
        self.index = index
        self.middle = middle
        self.ring = ring
        self.little = little
    }

    public subscript(finger: RAVEHandFinger) -> RAVEFingerJoints {
        get {
            switch finger {
            case .index:  return index
            case .middle: return middle
            case .ring:   return ring
            case .little: return little
            }
        }
        set {
            switch finger {
            case .index:  index = newValue
            case .middle: middle = newValue
            case .ring:   ring = newValue
            case .little: little = newValue
            }
        }
    }

    /// Thumb-to-fingertip distance — the pinch measurement.
    public func pinchDistance(to finger: RAVEHandFinger) -> Float {
        simd_distance(self[finger].tip, thumbTip)
    }

    /// How many non-thumb fingers are curled tighter than `threshold`.
    /// Three or more is the fist suppressor's trigger in every app that has one.
    public func curledFingerCount(threshold: Float) -> Int {
        var count = 0
        for finger in RAVEHandFinger.allCases where self[finger].extension_ < threshold {
            count += 1
        }
        return count
    }

    /// How many non-thumb fingers are extended further than `threshold`.
    /// The complement of the fist test, used for open-palm pose gates.
    public func extendedFingerCount(threshold: Float) -> Int {
        var count = 0
        for finger in RAVEHandFinger.allCases where self[finger].extension_ > threshold {
            count += 1
        }
        return count
    }
}

// MARK: - Size-normalised metrics

/// Pose metrics divided by the hand's own palm length, so one threshold works
/// for a child's hand and an adult's. LambdaVision computes these locally for
/// its finger-gun trigger, thumb-curl reload and 🤌 weapon wheel; they live here
/// so the next consumer does not derive them a fourth time.
public extension RAVEHandSample {
    /// Wrist to middle-finger knuckle, meters. The normaliser for every ratio
    /// below.
    var palmLength: Float { simd_distance(wrist, middle.knuckle) }

    /// Below this palm length the ratios are meaningless (joints coincident);
    /// they then report 1, "extended", which is the safe reading for a trigger.
    static let minimumPalmLength: Float = 1e-4

    private func normalised(_ distance: Float) -> Float {
        let palm = palmLength
        return palm > Self.minimumPalmLength ? distance / palm : 1
    }

    /// Fingertip to its proximal knuckle, over palm length. Extended ≈ 1; a
    /// curled finger drops toward ~0.3. The knuckle barely moves as the finger
    /// curls, so this is safe to read on an aiming hand. Lambda's `indexExt`.
    func extensionRatio(_ finger: RAVEHandFinger) -> Float {
        normalised(simd_distance(self[finger].tip, self[finger].knuckle))
    }

    /// `extensionRatio(.index)` — the finger-gun trigger metric.
    var indexExtensionRatio: Float { extensionRatio(.index) }

    /// Thumb tip to the index knuckle, over palm length. A raised thumb reads
    /// ~0.5+; curled down onto the fist it approaches ~0.3. Lambda's `thumbExt`
    /// (the reload gesture).
    var thumbExtensionRatio: Float {
        normalised(simd_distance(thumbTip, index.knuckle))
    }

    /// Fingertip to its hand-base metacarpal, over palm length. Low = curled.
    /// The size-normalised form of the fist test (`extension_` in meters).
    func curlRatio(_ finger: RAVEHandFinger) -> Float {
        normalised(self[finger].extension_)
    }

    /// The farthest of the four fingertips from the thumb tip, meters. All tips
    /// gathered at the thumb (🤌) reads low, ~2–4 cm. Not normalised, matching
    /// the thresholds Lambda tuned; see `fingertipSpreadRatio`.
    var fingertipSpreadToThumb: Float {
        var spread: Float = 0
        for finger in RAVEHandFinger.allCases {
            spread = max(spread, simd_distance(self[finger].tip, thumbTip))
        }
        return spread
    }

    /// `fingertipSpreadToThumb` over palm length.
    var fingertipSpreadRatio: Float { normalised(fingertipSpreadToThumb) }
}
