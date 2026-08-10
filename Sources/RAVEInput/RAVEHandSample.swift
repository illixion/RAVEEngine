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
