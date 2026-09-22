/*
 RAVE Engine — arm-swing locomotion, the Hot Dogs, Horseshoes & Hand Grenades way.

 You pump your arms like jogging and walk. The speed follows how fast your
 hands move. H3VR engages this with a held controller button. Hand tracking has
 no button, so the clutch here is a closed fist on each hand, fused with the
 swing itself.

 **Engagement is two signals, either of which can carry it.** A fist that
 tracking drops for a few frames mid-stroke must not stop you, and neither may
 a stroke that stalls for an instant at the top of its arc. So:

 - it *engages* only when both are present: fists, and a swing pattern (a
   velocity reversal recently, with real speed behind it). Fists held still do
   nothing, and open hands waving do nothing;
 - it *stays engaged* while either is present, with a short grace period;
 - it *disengages* once both lapse. The swing lapses as soon as the hands slow
   below the walking threshold, so opening your hands and stopping frees the
   gun hand at once rather than waiting out the pattern window.

 **Velocity is head-relative.** The wrist position has the head position
 subtracted before it is differentiated, so bobbing your head, or physically
 walking around the room, does not read as a swing. It is differentiated across
 a short window, not frame to frame, which absorbs hand-tracking jitter and
 the occasional repeated anchor.

 **Speed is smoothed asymmetrically.** Every stroke passes through zero
 velocity twice, at the top and bottom of the arc. A fast attack with a slow
 release carries the output through those instants, so the gait does not pulse
 with each arm stroke.

 The output is a unit-clamped head-relative vector, the same shape
 `RAVEHandJoystick` emits, so a consumer can feed either into the same
 movement axes. Full deflection is *reachable*, and a brisk jog saturates it.
 Nothing here decides how fast full deflection moves the player; that belongs
 to the game.
 */

import Foundation
import simd

/// Which way arm-swing walking goes.
public enum RAVEArmSwingDirection: String, Sendable, CaseIterable {
    /// Straight ahead of the head. The H3VR default.
    case head
    /// Where the fists point, averaged over the hands. Lets you look around
    /// while running a straight line.
    case hands
}

/// Thresholds for the arm swinger. Distances in meters, speeds in m/s,
/// times in seconds.
public struct RAVEArmSwingTuning: Sendable, Equatable {
    /// Fingertip-to-metacarpal distance below which a finger reads as curled.
    public var fistCurlThreshold: Float
    /// How many curled fingers make a fist. Matches the pinch detector's fist
    /// suppressor, which is what makes a fist and a pinch mutually exclusive.
    public var fistCurledFingerCount: Int
    /// How far back the velocity estimate reaches.
    public var velocityWindow: TimeInterval
    /// How recently the stroke must have reversed for the swing pattern to
    /// count. Longer than a slow stroke.
    public var patternWindow: TimeInterval
    /// Hand speed that counts as a real stroke for the pattern.
    public var patternSpeed: Float
    /// How recently the hand must have moved at `patternSpeed`. Shorter than
    /// `patternWindow`: it is what ends the pattern promptly once the hands
    /// stop, and needs only to outlast the stall at each end of a stroke.
    public var fastWindow: TimeInterval
    /// Along-stroke speed a reversal must cross on both sides, so jitter around
    /// zero is not a reversal.
    public var reversalSpeed: Float
    /// How long engagement survives after both signals lapse.
    public var grace: TimeInterval
    /// Stroke speed at which walking starts.
    public var walkSpeed: Float
    /// Stroke speed that reads as full deflection.
    public var runSpeed: Float
    /// How fast the stroke-speed envelope falls between peaks.
    public var envelopeDecay: TimeInterval
    /// Smoothing time constant while speeding up.
    public var attack: TimeInterval
    /// Smoothing time constant while slowing down. Must outlast the zero
    /// crossing at each end of a stroke.
    public var release: TimeInterval
    /// Upward hand speed that counts as a jump flick, on both hands.
    public var jumpSpeed: Float
    /// How close together the two hands' flicks must be.
    public var jumpPairWindow: TimeInterval
    /// Minimum time between jumps.
    public var jumpCooldown: TimeInterval

    public init(
        fistCurlThreshold: Float = 0.06,
        fistCurledFingerCount: Int = 3,
        velocityWindow: TimeInterval = 0.05,
        patternWindow: TimeInterval = 0.8,
        patternSpeed: Float = 0.4,
        fastWindow: TimeInterval = 0.25,
        reversalSpeed: Float = 0.15,
        grace: TimeInterval = 0.25,
        walkSpeed: Float = 0.4,
        runSpeed: Float = 2.0,
        envelopeDecay: TimeInterval = 0.35,
        attack: TimeInterval = 0.08,
        release: TimeInterval = 0.3,
        jumpSpeed: Float = 1.8,
        jumpPairWindow: TimeInterval = 0.1,
        jumpCooldown: TimeInterval = 0.5
    ) {
        self.fistCurlThreshold = fistCurlThreshold
        self.fistCurledFingerCount = fistCurledFingerCount
        self.velocityWindow = velocityWindow
        self.patternWindow = patternWindow
        self.patternSpeed = patternSpeed
        self.fastWindow = fastWindow
        self.reversalSpeed = reversalSpeed
        self.grace = grace
        self.walkSpeed = walkSpeed
        self.runSpeed = runSpeed
        self.envelopeDecay = envelopeDecay
        self.attack = attack
        self.release = release
        self.jumpSpeed = jumpSpeed
        self.jumpPairWindow = jumpPairWindow
        self.jumpCooldown = jumpCooldown
    }

    /// The same tuning, needing `sensitivity` times less arm speed to walk and
    /// to reach full deflection. Changes the effort, never the top speed.
    public func scaled(sensitivity: Float) -> RAVEArmSwingTuning {
        let s = sensitivity.isFinite ? max(sensitivity, 0.1) : 1
        var t = self
        t.walkSpeed /= s
        t.runSpeed /= s
        t.patternSpeed /= s
        return t
    }
}

/// What keeps the swinger engaged this frame. For on-device diagnostics.
public enum RAVEArmSwingSupport: String, Sendable {
    case none
    /// Fists and a swing pattern: the full engage condition.
    case both
    case fist
    case pattern
    /// Neither signal, but still inside the grace period.
    case grace
}

/// The arm swinger's reading for one frame.
public struct RAVEArmSwingOutput: Sendable, Equatable {
    /// True while arm swinging owns locomotion (and the hands with it).
    public var engaged: Bool
    /// Head-relative (x = strafe, y = forward), magnitude clamped to 1.
    public var vector: SIMD2<Float>
    /// Smoothed speed, 0 to 1. The length of `vector`.
    public var speed01: Float
    /// Stroke speed this frame, m/s: the peak hand speed of recent strokes,
    /// decaying between them.
    public var handSpeed: Float
    /// Set on the frame both hands flicked upward together.
    public var jumpBegan: Bool
    public var support: RAVEArmSwingSupport

    public init(
        engaged: Bool = false,
        vector: SIMD2<Float> = .zero,
        speed01: Float = 0,
        handSpeed: Float = 0,
        jumpBegan: Bool = false,
        support: RAVEArmSwingSupport = .none
    ) {
        self.engaged = engaged
        self.vector = vector
        self.speed01 = speed01
        self.handSpeed = handSpeed
        self.jumpBegan = jumpBegan
        self.support = support
    }
}

/// Arm-swing locomotion over both hands. Stored by value in whatever owns the
/// hand loop; feed it both hands every frame.
public struct RAVEArmSwinger: Sendable {
    public var tuning: RAVEArmSwingTuning
    public var direction: RAVEArmSwingDirection

    /// One hand's recent history. A fixed ring, so a render-thread consumer
    /// pays no allocation per frame.
    private struct Track: Sendable {
        static let capacity = 16
        var times = [TimeInterval](repeating: 0, count: capacity)
        var points = [SIMD3<Float>](repeating: .zero, count: capacity)
        var count = 0
        var head = 0
        var velocity: SIMD3<Float> = .zero
        /// Sign of the along-stroke velocity last time it was clearly moving.
        var strokeSign: Float = 0
        var lastReversal: TimeInterval = -.infinity
        var lastFast: TimeInterval = -.infinity
        var lastUpFlick: TimeInterval = -.infinity

        mutating func clear() {
            count = 0
            head = 0
            velocity = .zero
            strokeSign = 0
            lastReversal = -.infinity
            lastFast = -.infinity
            lastUpFlick = -.infinity
        }

        mutating func push(_ point: SIMD3<Float>, at time: TimeInterval, window: TimeInterval) {
            if count > 0 {
                let newest = (head + Self.capacity - 1) % Self.capacity
                // A repeated anchor carries no new information, and a gap this
                // long means the hand left tracking: start over.
                if time <= times[newest] { return }
                if time - times[newest] > 0.25 { clear() }
            }
            times[head] = time
            points[head] = point
            head = (head + 1) % Self.capacity
            count = min(count + 1, Self.capacity)

            // Difference against the newest sample at least `window` old, or
            // the oldest held if none is that old yet.
            var reference = (head + Self.capacity - count) % Self.capacity
            for back in 1..<count {
                let i = (head + Self.capacity - 1 - back) % Self.capacity
                reference = i
                if time - times[i] >= window { break }
            }
            let dt = Float(time - times[reference])
            velocity = dt > 1e-4 ? (point - points[reference]) / dt : .zero
        }
    }

    private var left = Track()
    private var right = Track()
    private var engaged = false
    private var lastSupported: TimeInterval = -.infinity
    private var smoothed: Float = 0
    private var envelope: Float = 0
    private var lastUpdate: TimeInterval?
    private var lastJump: TimeInterval = -.infinity
    private var heading = SIMD2<Float>(0, 1)

    public init(tuning: RAVEArmSwingTuning = RAVEArmSwingTuning(),
                direction: RAVEArmSwingDirection = .head) {
        self.tuning = tuning
        self.direction = direction
    }

    public var isEngaged: Bool { engaged }

    /// Drop all state. Use when something else takes the hands (a pinch
    /// clutch, a menu), so the next swing has to engage from scratch.
    public mutating func reset() {
        left.clear()
        right.clear()
        engaged = false
        lastSupported = -.infinity
        smoothed = 0
        envelope = 0
        lastUpdate = nil
        heading = SIMD2(0, 1)
    }

    /// Advance one frame.
    ///
    /// - Parameters:
    ///   - left: the left hand, or `nil` when it is not tracked.
    ///   - right: the right hand, or `nil` when it is not tracked.
    ///   - headPosition: the head, in the same space as the hand samples.
    ///   - basis: the player's head-relative axes, in that same space.
    ///   - now: a monotonic time in seconds.
    @discardableResult
    public mutating func update(
        left leftSample: RAVEHandSample?,
        right rightSample: RAVEHandSample?,
        headPosition: SIMD3<Float>,
        basis: RAVEPlanarBasis,
        now: TimeInterval
    ) -> RAVEArmSwingOutput {
        let t = tuning
        let dt = lastUpdate.map { Float(max(0, min(now - $0, 0.25))) } ?? 0
        lastUpdate = now

        func observe(_ sample: RAVEHandSample?, _ track: inout Track) -> (fist: Bool, pattern: Bool)? {
            guard let sample,
                  sample.wrist.x.isFinite, sample.wrist.y.isFinite, sample.wrist.z.isFinite
            else {
                track.clear()
                return nil
            }
            track.push(sample.wrist - headPosition, at: now, window: t.velocityWindow)
            let v = track.velocity
            let speed = simd_length(v)
            if speed >= t.patternSpeed { track.lastFast = now }
            // A jogging stroke arcs up as it goes forward and down as it goes
            // back, so forward and up add up to one signed stroke speed.
            let along = simd_dot(v, basis.forward) + v.y
            if abs(along) >= t.reversalSpeed {
                let sign: Float = along > 0 ? 1 : -1
                if track.strokeSign != 0, sign != track.strokeSign { track.lastReversal = now }
                track.strokeSign = sign
            }
            if v.y >= t.jumpSpeed { track.lastUpFlick = now }
            let fist = sample.curledFingerCount(threshold: t.fistCurlThreshold) >= t.fistCurledFingerCount
            let pattern = now - track.lastReversal <= t.patternWindow
                && now - track.lastFast <= t.fastWindow
            return (fist, pattern)
        }

        let l = observe(leftSample, &left)
        let r = observe(rightSample, &right)
        let trackedCount = (l == nil ? 0 : 1) + (r == nil ? 0 : 1)

        // Mean speed over the hands we can see, so losing one hand halves
        // nothing.
        var handSpeed: Float = 0
        if l != nil { handSpeed += simd_length(left.velocity) }
        if r != nil { handSpeed += simd_length(right.velocity) }
        if trackedCount > 0 { handSpeed /= Float(trackedCount) }

        // Every tracked hand a fist, and at least one tracked. An untracked
        // hand does not veto: jogging arms swing in and out of the cameras.
        let allFists = trackedCount > 0 && (l?.fist ?? true) && (r?.fist ?? true)
        let anyFist = (l?.fist ?? false) || (r?.fist ?? false)
        let pattern = ((l?.pattern ?? false) || (r?.pattern ?? false))

        var support: RAVEArmSwingSupport = .none
        if !engaged {
            if allFists && pattern {
                engaged = true
                support = .both
            }
        } else if anyFist && pattern {
            support = .both
        } else if anyFist {
            support = .fist
        } else if pattern {
            support = .pattern
        }
        if support != .none {
            lastSupported = now
        } else if engaged {
            if now - lastSupported <= t.grace {
                support = .grace
            } else {
                engaged = false
            }
        }

        // Speed comes from the stroke, not the instant. A hand's speed runs
        // from zero at each end of a stroke to its peak mid-stroke, so the
        // mean of a jog sits well under its peak and a speed ramp fed
        // instantaneous values can never hold full deflection. The envelope
        // holds each stroke's peak and decays between strokes, which reads
        // a steady jog as steady.
        if dt > 0 { envelope *= expf(-dt / Float(max(t.envelopeDecay, 1e-3))) }
        envelope = max(envelope, handSpeed)
        let span = max(t.runSpeed - t.walkSpeed, 1e-3)
        let target = engaged ? min(max((envelope - t.walkSpeed) / span, 0), 1) : 0
        let tau = Float(target > smoothed ? t.attack : t.release)
        if dt > 0 {
            smoothed += (target - smoothed) * (1 - expf(-dt / max(tau, 1e-3)))
        }
        // Once free, let the tail settle through the release, then stop
        // outright rather than creeping.
        if !engaged && smoothed < 0.05 { smoothed = 0 }

        // Direction.
        var dir = SIMD2<Float>(0, 1)
        if direction == .hands {
            func pointing(_ sample: RAVEHandSample?) -> SIMD3<Float> {
                guard let sample else { return .zero }
                let p = sample.middle.knuckle - sample.wrist
                return p.x.isFinite && p.z.isFinite ? p : .zero
            }
            let sum = pointing(leftSample) + pointing(rightSample)
            let planar = SIMD2(simd_dot(sum, basis.right), simd_dot(sum, basis.forward))
            let length = simd_length(planar)
            if length > 1e-3 {
                heading = planar / length
            }
            // Hold the last good heading through a frame with no usable hand.
            dir = heading
        }

        // Jump: both hands flick up together. A jogging stroke is anti-phase,
        // so both hands rising fast at once is the flick and not the gait.
        var jumpBegan = false
        if engaged,
           abs(left.lastUpFlick - right.lastUpFlick) <= t.jumpPairWindow,
           now - max(left.lastUpFlick, right.lastUpFlick) <= t.jumpPairWindow,
           now - lastJump >= t.jumpCooldown {
            jumpBegan = true
            lastJump = now
        }

        return RAVEArmSwingOutput(
            engaged: engaged,
            vector: dir * smoothed,
            speed01: smoothed,
            handSpeed: envelope,
            jumpBegan: jumpBegan,
            support: support
        )
    }
}
