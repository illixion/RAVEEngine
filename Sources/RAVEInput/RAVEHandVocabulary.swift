/*
 RAVE Engine — platform-independent hand vocabulary.

 These types name what a hand is doing without naming the framework that
 observed it. Spatialcraft arrived at this pattern first, extracting it from an
 ARKit-importing tracker so downstream consumers would stop transitively
 depending on visionOS; this is that vocabulary, promoted to a package so
 Longwave and Lambda stop re-declaring their own copies of it.

 Everything here is a plain value type with no import beyond `simd`, which is
 what makes the sensing layer testable on the Mac host and what leaves the door
 open for a non-ARKit producer later.
 */

import simd

/// Which hand.
///
/// Raw-valued and `Codable` because Longwave persists it inside binding tables;
/// `Hashable` because its sender keys per-hand dictionaries by it.
public enum RAVEHandChirality: String, Codable, Hashable, Sendable, CaseIterable {
    case left, right
}

/// The four non-thumb fingers, in anatomical order. A "pinch" is always
/// thumb-to-fingertip, so the thumb is the other side of every pair and never
/// appears here.
public enum RAVEHandFinger: Int, Codable, Hashable, Sendable, CaseIterable {
    case index = 0, middle, ring, little

    public var displayName: String {
        switch self {
        case .index:  return "Index"
        case .middle: return "Middle"
        case .ring:   return "Ring"
        case .little: return "Little"
        }
    }
}

/// A rising-edge thumb-to-fingertip pinch.
public struct RAVEHandPinchEvent: Hashable, Sendable {
    public let chirality: RAVEHandChirality
    public let finger: RAVEHandFinger

    public init(chirality: RAVEHandChirality, finger: RAVEHandFinger) {
        self.chirality = chirality
        self.finger = finger
    }
}

/// One frame of hand-derived input: discrete pinch edges plus the continuous
/// joystick vector.
///
/// Mirrors an additive input model — an empty frame (the no-hands case)
/// contributes nothing and disturbs no other input source, which is why hand
/// tracking can be absent without any call site branching on it.
public struct RAVEHandInputFrame: Sendable {
    public var pinchEvents: [RAVEHandPinchEvent]
    /// Head-relative (x = strafe, y = forward) movement vector, magnitude
    /// clamped to 1. Zero unless a sustained joystick pinch is held.
    public var joystick: SIMD2<Float>

    public init(pinchEvents: [RAVEHandPinchEvent] = [], joystick: SIMD2<Float> = .zero) {
        self.pinchEvents = pinchEvents
        self.joystick = joystick
    }
}

/// World-space pose of a palm: its center, the outward palm normal (points out
/// of the palm — toward your face when you look at it), and the up-the-hand
/// finger axis.
public struct RAVEPalmPose: Sendable, Equatable {
    public let position: SIMD3<Float>
    public let palmNormalOut: SIMD3<Float>
    public let fingersDirection: SIMD3<Float>

    public init(
        position: SIMD3<Float>,
        palmNormalOut: SIMD3<Float>,
        fingersDirection: SIMD3<Float>
    ) {
        self.position = position
        self.palmNormalOut = palmNormalOut
        self.fingersDirection = fingersDirection
    }
}
