/*
 RAVE Engine — the forearm as a coordinate system.

 A sleeve is a HUD worn on the forearm rather than floated near the palm: its
 tiles are placed by how far along the arm they sit, how far round it, and how
 far off the skin. Everything here turns one frame of tracked joints into that
 coordinate system, with no framework in it.

 **What the host samples.** ARKit's hand skeleton carries two forearm joints,
 `forearmWrist` and `forearmArm` (the elbow end), under the hand-tracking
 authorisation the apps already hold. The host passes their positions and the
 hand's palm pose (`RAVEPalmGeometry.palmPose`). Joint orientations are not
 read: which local axis means what differs between the hands, and the palm
 pose already answers "which way is the back of the hand" by measurement.

 **Roll.** The outer face of the sleeve (the watch side) points out of the back
 of the hand, taken perpendicular to the arm. That is exact at the wrist; skin
 nearer the elbow turns less when the hand pronates, and the elbow's own
 reference is not something the hand skeleton reports. A host that has one
 (a body-tracking rig) passes `elbowBack` and the roll is blended along the
 arm; otherwise the wrist's roll is used for the whole sleeve, which is right
 for the half of the forearm nearest the hand, where tiles go.

 **Without the elbow joint** (untracked, or a host that only has a palm) the
 arm is assumed to run straight back from the fingers. The frame says so in
 `isEstimated`, and it is good enough for a sleeve near the wrist.
 */

import Foundation
import RAVEInput
import simd

/// Which arm. The sleeve is worn on the non-dominant one by default, so the
/// dominant hand's index finger presses it.
public enum RAVESleeveSide: String, Codable, Sendable, CaseIterable {
    case left, right

    public var other: RAVESleeveSide { self == .left ? .right : .left }
}

/// One frame of the arm a sleeve is worn on, in world metres.
public struct RAVESleeveArm: Sendable, Equatable {
    public var side: RAVESleeveSide
    /// The wrist end of the forearm (`forearmWrist`).
    public var wrist: SIMD3<Float>
    /// The elbow end of the forearm (`forearmArm`), nil while untracked.
    public var elbow: SIMD3<Float>?
    /// The hand's palm pose: which way the back of the hand faces.
    public var palm: RAVEPalmPose
    /// The outer-face direction at the elbow, if the host knows it.
    public var elbowBack: SIMD3<Float>?

    public init(side: RAVESleeveSide, wrist: SIMD3<Float>, elbow: SIMD3<Float>?, palm: RAVEPalmPose,
                elbowBack: SIMD3<Float>? = nil) {
        self.side = side
        self.wrist = wrist
        self.elbow = elbow
        self.palm = palm
        self.elbowBack = elbowBack
    }
}

public extension RAVESleeveArm {
    /// The arm in another space: points through `matrix`, directions through
    /// its rotation. A host that parents its tiles to the system's own wrist
    /// anchor runs the sleeve in that joint's space (`matrix` is the joint's
    /// inverse), so the system moves the tiles with the arm at render time
    /// and only what changes relative to the wrist goes through the app.
    func transformed(by matrix: simd_float4x4) -> RAVESleeveArm {
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = matrix * SIMD4(p, 1)
            return SIMD3(q.x, q.y, q.z)
        }
        func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
            let q = matrix * SIMD4(d, 0)
            let v = SIMD3(q.x, q.y, q.z)
            return simd_length(v) > 1e-6 ? simd_normalize(v) : d
        }
        return RAVESleeveArm(side: side, wrist: point(wrist), elbow: elbow.map(point),
                             palm: RAVEPalmPose(position: point(palm.position),
                                                palmNormalOut: direction(palm.palmNormalOut),
                                                fingersDirection: direction(palm.fingersDirection)),
                             elbowBack: elbowBack.map(direction))
    }
}

/// Which side of the forearm a tile is on.
public enum RAVESleeveFace: String, Codable, Sendable, CaseIterable {
    /// The back of the forearm: where a watch face is.
    case outer
    /// The palm side of the forearm.
    case inner

    /// The face's centre, radians round the arm from the outer face.
    public var angle: Float { self == .outer ? 0 : .pi }
}

/// Which way up a tile's content reads.
public enum RAVESleeveReading: String, Codable, Sendable {
    /// Like a watch: lines run along the arm, read with the arm held across
    /// the body.
    case watch
    /// Lines run across the arm, the top toward the hand: read with the arm
    /// held out ahead.
    case lengthwise
}

/// The forearm's coordinate system for one frame.
public struct RAVESleeveFrame: Sendable, Equatable {
    public var side: RAVESleeveSide
    /// The wrist.
    public var origin: SIMD3<Float>
    /// Unit, from the wrist toward the elbow.
    public var along: SIMD3<Float>
    /// Unit, out of the outer face at the wrist, perpendicular to `along`.
    public var back: SIMD3<Float>
    /// Radians the outer face has turned by the elbow end, about `along`.
    /// Zero unless the arm carried an `elbowBack`.
    public var twist: Float
    /// Wrist to elbow, metres.
    public var length: Float
    /// The elbow was not tracked: `along` comes from the hand and `length`
    /// is the default.
    public var isEstimated: Bool

    /// A forearm when the elbow is not tracked.
    public static let defaultLength: Float = 0.25

    public init(side: RAVESleeveSide, origin: SIMD3<Float>, along: SIMD3<Float>, back: SIMD3<Float>,
                twist: Float = 0, length: Float = RAVESleeveFrame.defaultLength, isEstimated: Bool = false) {
        self.side = side
        self.origin = origin
        self.along = along
        self.back = back
        self.twist = twist
        self.length = length
        self.isEstimated = isEstimated
    }

    /// The frame of an arm, or nil when the pose cannot say which way the
    /// outer face points (joints on top of each other, or the hand bent so
    /// far that its back points along the arm). A caller keeps the last frame.
    public init?(arm: RAVESleeveArm) {
        var along: SIMD3<Float>
        var length = Self.defaultLength
        var estimated = true
        if let elbow = arm.elbow, simd_distance(elbow, arm.wrist) > 0.05 {
            along = simd_normalize(elbow - arm.wrist)
            length = simd_distance(elbow, arm.wrist)
            estimated = false
        } else {
            guard simd_length(arm.palm.fingersDirection) > 1e-4 else { return nil }
            along = -simd_normalize(arm.palm.fingersDirection)
        }
        guard let back = Self.perpendicular(-arm.palm.palmNormalOut, to: along) else { return nil }
        var twist: Float = 0
        if let elbowBack = arm.elbowBack, let far = Self.perpendicular(elbowBack, to: along) {
            twist = atan2(simd_dot(simd_cross(back, far), along), simd_dot(back, far))
        }
        self.init(side: arm.side, origin: arm.wrist, along: along, back: back, twist: twist,
                  length: length, isEstimated: estimated)
    }

    /// The part of `v` perpendicular to `axis`, unit length; nil when `v`
    /// runs within about 20° of the axis.
    static func perpendicular(_ v: SIMD3<Float>, to axis: SIMD3<Float>) -> SIMD3<Float>? {
        let length = simd_length(v)
        guard length > 1e-5 else { return nil }
        let p = v / length - axis * simd_dot(v / length, axis)
        return simd_length(p) > 0.34 ? simd_normalize(p) : nil
    }

    /// Unit, toward the thumb's side of the arm at the wrist.
    public var thumbward: SIMD3<Float> {
        let t = simd_cross(along, back)
        return side == .right ? t : -t
    }

    /// The outward direction at `angle` radians round the arm from the outer
    /// face (toward the thumb side), `distance` metres from the wrist.
    public func normal(angle: Float, distance: Float = 0) -> SIMD3<Float> {
        let a = angle + rollOffset(at: distance)
        return back * cos(a) + thumbward * sin(a)
    }

    /// The direction a point moves as `angle` grows.
    public func tangent(angle: Float, distance: Float = 0) -> SIMD3<Float> {
        let a = angle + rollOffset(at: distance)
        return thumbward * cos(a) - back * sin(a)
    }

    /// How far the outer face has turned `distance` metres up the arm, in the
    /// angle's own sense.
    private func rollOffset(at distance: Float) -> Float {
        guard twist != 0, length > 1e-3 else { return 0 }
        let t = max(0, min(1, distance / length))
        // `twist` is about `along`; angles grow toward the thumb, which is
        // about `along` on a right arm and against it on a left.
        return (side == .right ? twist : -twist) * t
    }

    /// A point `distance` metres from the wrist toward the elbow, `angle`
    /// radians round, `radius` metres from the arm's axis.
    public func point(distance: Float, angle: Float, radius: Float) -> SIMD3<Float> {
        origin + along * distance + normal(angle: angle, distance: distance) * radius
    }

    /// A flat tile tangent to the arm there: local x is the reading's right,
    /// y its up, +z out of the arm (the way a SwiftUI attachment and a
    /// `RAVEHoloPanel` both face).
    public func tile(distance: Float, angle: Float, radius: Float,
                     reading: RAVESleeveReading = .watch) -> simd_float4x4 {
        let n = normal(angle: angle, distance: distance)
        let right: SIMD3<Float>
        switch reading {
        case .watch:
            // Held across the body the hand is at the reader's right for a
            // left arm and at their left for a right arm.
            right = side == .left ? -along : along
        case .lengthwise:
            right = simd_cross(-along, n)
        }
        let up = simd_cross(n, right)
        return simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(n, 0),
                             SIMD4(point(distance: distance, angle: angle, radius: radius), 1))
    }

    /// How squarely the arm's surface at `angle` faces `viewer`: 1 toward,
    /// 0 edge-on, -1 away.
    public func facing(angle: Float, distance: Float, radius: Float, toward viewer: SIMD3<Float>) -> Float {
        let p = point(distance: distance, angle: angle, radius: radius)
        let d = viewer - p
        let l = simd_length(d)
        return l > 1e-4 ? simd_dot(normal(angle: angle, distance: distance), d / l) : 0
    }
}
