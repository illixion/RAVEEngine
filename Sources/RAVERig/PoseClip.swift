import Foundation
import simd

/// A skeletal clip as plain keyframes: one `JointPose` per joint per frame,
/// evenly spaced in time.
///
/// This is the half of animation playback a host owns once it stops handing
/// the skeleton to an engine's animation system. RealityKit, for one, renders
/// a pose written straight to the skeleton only while nothing else animates
/// it, and offers no way to evaluate one of its own clips at a time value. So
/// a host that wants to blend, solve and write the pose itself has to sample
/// its clips itself too. The joint order is whatever the host's skeleton uses;
/// the clip neither knows nor checks the names.
public struct PoseClip: Sendable, Equatable {
    /// `frames[f][j]` is joint `j` at frame `f`, parent-relative.
    public var frames: [[JointPose]]
    /// Seconds between frames.
    public var frameInterval: Float
    /// A looping clip interpolates from its last frame back to its first;
    /// one that plays once holds its last frame.
    public var loops: Bool

    public init(frames: [[JointPose]], frameInterval: Float, loops: Bool) {
        precondition(frameInterval > 0, "a clip needs time between its frames")
        self.frames = frames
        self.frameInterval = frameInterval
        self.loops = loops
    }

    public var jointCount: Int { frames.first?.count ?? 0 }

    /// How long one pass takes. A loop includes the step from the last frame
    /// back to the first, so a cycle whose closing duplicate was trimmed still
    /// takes its authored time.
    public var duration: Float {
        guard !frames.isEmpty else { return 0 }
        return Float(loops ? frames.count : frames.count - 1) * frameInterval
    }

    /// The pose `time` seconds in. Times outside the clip wrap when it loops
    /// and clamp when it does not.
    public func sample(at time: Float) -> [JointPose] {
        guard let first = frames.first else { return [] }
        guard frames.count > 1, duration > 0 else { return first }
        let t: Float
        if loops {
            let wrapped = time.truncatingRemainder(dividingBy: duration)
            t = wrapped < 0 ? wrapped + duration : wrapped
        } else {
            t = min(max(time, 0), duration)
        }
        let position = t / frameInterval
        let index = min(Int(position), frames.count - 1)
        let next = loops ? (index + 1) % frames.count : min(index + 1, frames.count - 1)
        return JointPose.mix(frames[index], frames[next], position - Float(index))
    }

    /// Whether a clip that plays once has reached its end.
    public func isFinished(at time: Float) -> Bool { !loops && time >= duration }
}

extension JointPose {
    /// `a` at 0, `b` at 1: translation and scale linearly, rotation along the
    /// shorter arc so a pair of nearly equal quaternions with opposite signs
    /// does not swing the long way round.
    public static func mix(_ a: JointPose, _ b: JointPose, _ t: Float) -> JointPose {
        var to = b.rotation
        if simd_dot(a.rotation.vector, to.vector) < 0 { to = simd_quatf(vector: -to.vector) }
        return JointPose(rotation: simd_slerp(a.rotation, to, t),
                         translation: simd_mix(a.translation, b.translation, SIMD3(repeating: t)),
                         scale: simd_mix(a.scale, b.scale, SIMD3(repeating: t)))
    }

    /// Joint by joint. The two poses must use the same joint order; a longer
    /// one is cut to the shorter.
    public static func mix(_ a: [JointPose], _ b: [JointPose], _ t: Float) -> [JointPose] {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return zip(a, b).map { mix($0, $1, t) }
    }
}

/// Plays one clip at a time and crossfades into the next, which is all an
/// engine's animation state machine was doing for a character that only ever
/// shows one state.
///
/// The crossfade blends from the *pose on screen* when the change was asked
/// for, frozen, rather than from the old clip still running. That is what
/// stops a change during a change from jumping: the starting point is always
/// something that was actually displayed.
public struct PosePlayer: Sendable {
    public private(set) var clip: PoseClip?
    public private(set) var time: Float = 0
    public var rate: Float = 1
    private var fadeFrom: [JointPose]?
    private var fadeElapsed: Float = 0
    private var fadeDuration: Float = 0
    /// The last pose `advance` returned.
    public private(set) var pose: [JointPose] = []

    public init() {}

    /// Starts `clip` from `startTime`, blending over `fade` seconds from
    /// whatever is showing now. The first clip ever played cuts straight in.
    public mutating func play(_ clip: PoseClip, fade: Float, from startTime: Float = 0) {
        fadeFrom = pose.isEmpty || fade <= 0 ? nil : pose
        fadeElapsed = 0
        fadeDuration = fade
        self.clip = clip
        time = startTime
    }

    public var isFading: Bool { fadeFrom != nil }

    /// Whether the current clip plays once and has run out.
    public var isFinished: Bool { clip?.isFinished(at: time) ?? true }

    /// Moves on `deltaTime` seconds and returns the pose to show.
    public mutating func advance(_ deltaTime: Float) -> [JointPose] {
        guard clip != nil else { return pose }
        return advance(deltaTime, at: time + deltaTime * rate)
    }

    /// Shows the clip at `clipTime` rather than at wherever `rate` would have
    /// taken it, while any crossfade still runs on `deltaTime`.
    ///
    /// For a clip whose clock is something other than time: a walk locked to
    /// the steps the legs are actually taking, so the arms and body swing
    /// with the feet at whatever pace the feet go.
    public mutating func advance(_ deltaTime: Float, at clipTime: Float) -> [JointPose] {
        guard let clip else { return pose }
        time = clipTime
        var out = clip.sample(at: time)
        if let from = fadeFrom {
            fadeElapsed += deltaTime
            let t = fadeDuration > 0 ? min(fadeElapsed / fadeDuration, 1) : 1
            // Smoothstep, so the blend leaves and arrives without a kink.
            out = JointPose.mix(from, out, t * t * (3 - 2 * t))
            if t >= 1 { fadeFrom = nil }
        }
        pose = out
        return out
    }
}
