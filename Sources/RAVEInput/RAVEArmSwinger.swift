/*
 RAVE Engine — arm-swing locomotion, the Hot Dogs, Horseshoes & Hand Grenades way.

 You pump your arms like jogging and walk. The speed follows how fast your
 hands move. H3VR engages this with a held controller button. Hand tracking has
 no button, so the clutch here is a closed fist on each hand, fused with the
 swing itself.

 **Engagement is two signals, either of which can carry it.** A fist that
 tracking drops for a few frames mid-stroke must not stop you, and neither may
 a stroke that stalls for an instant at the top of its arc. So:

 - it *engages* only when both are present: fists, and a swing pattern —
   `minReversals` stroke reversals within `engageWindow` with real speed
   behind them, and (by default) the two hands moving in opposite phase, as
   jogging arms do. Fists held still do nothing, open hands waving do nothing,
   and neither does a single fist-shake, a two-handed shove, or clapping;
 - it *stays engaged* while either is present, with a short grace period;
 - it *disengages* once both lapse. The swing lapses as soon as the hands slow
   below the walking threshold, so opening your hands and stopping frees the
   gun hand at once rather than waiting out the pattern window.

 **Each hand joins and leaves on its own.** Both hands start the swing, but once
 moving either can carry it alone, so a player can keep running on one arm and
 aim with the other. A hand leaves when both of its own signals lapse, or at
 once when it makes a pointing pose: a finger gun, index out with the ring and
 little fingers curled, the middle either curled or held out alongside the index.
 That pose is a deliberate signal, where a lapse could be tracking noise. A hand
 that left rejoins only after it has been a swinging fist for `rejoinHold`, so
 firing (an index curl) while sweeping the aim does not pull it back in. The
 output reports which hands are swinging so the consumer knows which ones are
 free.

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
    /// The index must be among them: a finger gun has three curled fingers
    /// and is not a fist.
    public var fistCurledFingerCount: Int
    /// Index fingertip-to-metacarpal distance above which the index reads as
    /// pointing.
    public var pointExtension: Float
    /// How long a pointing pose must hold before its hand leaves the swing.
    /// Long enough to reject a tracking flicker, short enough to feel instant.
    public var pointHold: TimeInterval
    /// How many stroke reversals (on either hand) must have happened within
    /// `engageWindow` before the swing may engage. One reversal is a single
    /// back-and-forth flick, which a gesture made for any other reason
    /// produces constantly; two is the start of a rhythm.
    public var minReversals: Int
    /// How far back `minReversals` are counted. Longer than two strokes of a
    /// slow jog.
    public var engageWindow: TimeInterval
    /// Require the two hands to move in opposite phase — one forward while the
    /// other goes back — to engage. Jogging arms do; a two-handed push, a pull
    /// or a clap do not. Needs both hands tracked to engage (either may drop
    /// out afterwards). False restores the one-hand-can-engage rule.
    public var requireOppositePhase: Bool
    /// How anti-phase the hands must read to engage, 0…1: the smoothed
    /// agreement of the two hands' stroke directions must be at or below
    /// `-antiPhaseThreshold` (−1 is perfectly opposite).
    public var antiPhaseThreshold: Float
    /// Time constant of the phase-agreement average.
    public var phaseSmoothing: TimeInterval
    /// Let a single swinging arm's upward flick jump. Off by default: with one
    /// hand there is no partner to tell a jump flick from a big stroke or a
    /// reach, so it misfires.
    public var oneArmJump: Bool
    /// How long a hand that left must be a swinging fist before it rejoins.
    public var rejoinHold: TimeInterval
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
        pointExtension: Float = 0.08,
        pointHold: TimeInterval = 0.12,
        minReversals: Int = 2,
        engageWindow: TimeInterval = 1.2,
        requireOppositePhase: Bool = true,
        antiPhaseThreshold: Float = 0.5,
        phaseSmoothing: TimeInterval = 0.3,
        oneArmJump: Bool = false,
        rejoinHold: TimeInterval = 0.3,
        velocityWindow: TimeInterval = 0.05,
        patternWindow: TimeInterval = 0.8,
        patternSpeed: Float = 0.5,
        fastWindow: TimeInterval = 0.25,
        reversalSpeed: Float = 0.2,
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
        self.pointExtension = pointExtension
        self.pointHold = pointHold
        self.minReversals = minReversals
        self.engageWindow = engageWindow
        self.requireOppositePhase = requireOppositePhase
        self.antiPhaseThreshold = antiPhaseThreshold
        self.phaseSmoothing = phaseSmoothing
        self.oneArmJump = oneArmJump
        self.rejoinHold = rejoinHold
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

    /// The original, easier-to-engage thresholds: one reversal engages, no
    /// phase check, one-arm jump on, 80 ms point hold, 0.4 m/s pattern speed,
    /// 0.15 m/s reversal speed. For comparison, or an app that wants them.
    public static let legacy = RAVEArmSwingTuning(
        pointHold: 0.08,
        minReversals: 1,
        engageWindow: 0.8,
        requireOppositePhase: false,
        oneArmJump: true,
        patternSpeed: 0.4,
        reversalSpeed: 0.15
    )
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
    /// True while arm swinging owns locomotion.
    public var engaged: Bool
    /// Which hands are swinging, and so not free for anything else. At least
    /// one is while `engaged`; either may be false while the other carries it.
    public var leftSwinging: Bool
    public var rightSwinging: Bool
    /// Head-relative (x = strafe, y = forward), magnitude clamped to 1.
    public var vector: SIMD2<Float>
    /// Smoothed speed, 0 to 1. The length of `vector`.
    public var speed01: Float
    /// Stroke speed this frame, m/s: the peak hand speed of recent strokes,
    /// decaying between them.
    public var handSpeed: Float
    /// Set on the frame the swinging hands flicked upward together (the one
    /// hand, when only one is swinging and the tuning allows `oneArmJump`).
    public var jumpBegan: Bool
    public var support: RAVEArmSwingSupport

    public init(
        engaged: Bool = false,
        leftSwinging: Bool = false,
        rightSwinging: Bool = false,
        vector: SIMD2<Float> = .zero,
        speed01: Float = 0,
        handSpeed: Float = 0,
        jumpBegan: Bool = false,
        support: RAVEArmSwingSupport = .none
    ) {
        self.engaged = engaged
        self.leftSwinging = leftSwinging
        self.rightSwinging = rightSwinging
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
        /// The last few reversal times, newest in lane 0, for counting them.
        var reversals = SIMD4<Double>(repeating: -.infinity)
        /// Signed along-stroke speed this frame (0 when below reversalSpeed).
        var along: Float = 0
        var lastFast: TimeInterval = -.infinity
        var lastUpFlick: TimeInterval = -.infinity
        /// Participation, which outlives a tracking gap (the grace covers it),
        /// so `clear()` leaves it alone.
        var swinging = false
        var lastSupported: TimeInterval = -.infinity
        var pointSince: TimeInterval?
        var rejoinSince: TimeInterval?

        mutating func leave() {
            swinging = false
            pointSince = nil
            rejoinSince = nil
        }

        mutating func clear() {
            count = 0
            head = 0
            velocity = .zero
            strokeSign = 0
            lastReversal = -.infinity
            reversals = SIMD4(repeating: -.infinity)
            along = 0
            lastFast = -.infinity
            lastUpFlick = -.infinity
        }

        mutating func noteReversal(at time: TimeInterval) {
            lastReversal = time
            reversals = SIMD4(time, reversals[0], reversals[1], reversals[2])
        }

        func reversalCount(within window: TimeInterval, now: TimeInterval) -> Int {
            var n = 0
            for i in 0..<4 where now - reversals[i] <= window { n += 1 }
            return n
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
    private var smoothed: Float = 0
    private var envelope: Float = 0
    private var lastUpdate: TimeInterval?
    private var lastJump: TimeInterval = -.infinity
    private var heading = SIMD2<Float>(0, 1)
    /// Smoothed agreement of the two hands' stroke directions: +1 in phase,
    /// −1 opposite, 0 unknown.
    private var phase: Float = 0

    /// The smoothed phase agreement, −1 (opposite, jogging) … +1 (together).
    /// For diagnostics.
    public var phaseAgreement: Float { phase }

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
        left.leave()
        right.leave()
        engaged = false
        smoothed = 0
        envelope = 0
        lastUpdate = nil
        heading = SIMD2(0, 1)
        phase = 0
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

        struct Reading { var fist: Bool; var pattern: Bool; var pointing: Bool }

        func observe(_ sample: RAVEHandSample?, _ track: inout Track) -> Reading? {
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
                if track.strokeSign != 0, sign != track.strokeSign { track.noteReversal(at: now) }
                track.strokeSign = sign
                track.along = along
            } else {
                track.along = 0
            }
            if v.y >= t.jumpSpeed { track.lastUpFlick = now }
            let indexCurled = sample.index.extension_ < t.fistCurlThreshold
            let curled = sample.curledFingerCount(threshold: t.fistCurlThreshold)
            let fist = indexCurled && curled >= t.fistCurledFingerCount
            // A finger gun: index out, ring and little curled. The middle is
            // free, because a two-finger gun (middle alongside the index) is
            // the same gesture.
            let pointing = sample.index.extension_ > t.pointExtension
                && sample.ring.extension_ < t.fistCurlThreshold
                && sample.little.extension_ < t.fistCurlThreshold
            let pattern = now - track.lastReversal <= t.patternWindow
                && now - track.lastFast <= t.fastWindow
            return Reading(fist: fist, pattern: pattern, pointing: pointing)
        }

        let l = observe(leftSample, &left)
        let r = observe(rightSample, &right)
        let trackedCount = (l == nil ? 0 : 1) + (r == nil ? 0 : 1)

        // Phase agreement, only while both hands are clearly moving; it drifts
        // back to "unknown" while either is out of view.
        if dt > 0 {
            let k = 1 - expf(-dt / Float(max(t.phaseSmoothing, 1e-3)))
            if l != nil, r != nil, left.along != 0, right.along != 0 {
                let agreement: Float = (left.along > 0) == (right.along > 0) ? 1 : -1
                phase += (agreement - phase) * k
            } else if l == nil || r == nil {
                phase += (0 - phase) * k
            }
        }

        // Engage: every tracked hand a swinging-ready fist, and at least one
        // tracked. An untracked hand does not veto (jogging arms swing in and
        // out of the cameras). Both hands join, the unseen one on credit: the
        // grace drops it if it never shows up.
        if !engaged {
            let allFists = trackedCount > 0 && (l?.fist ?? true) && (r?.fist ?? true)
            let pattern = (l?.pattern ?? false) || (r?.pattern ?? false)
            let rhythm = max(left.reversalCount(within: t.engageWindow, now: now),
                             right.reversalCount(within: t.engageWindow, now: now))
                >= max(t.minReversals, 1)
            let phased = !t.requireOppositePhase
                || (trackedCount == 2 && phase <= -t.antiPhaseThreshold)
            if allFists && pattern && rhythm && phased {
                engaged = true
                func join(_ track: inout Track) {
                    track.leave()
                    track.swinging = true
                    track.lastSupported = now
                }
                join(&left)
                join(&right)
            }
        } else {
            // Each hand on its own: stay while either of its signals holds,
            // leave on a lapse past the grace or on a held pointing pose,
            // rejoin after being a swinging fist for a while.
            func advance(_ track: inout Track, _ reading: Reading?) {
                if track.swinging {
                    if let reading, reading.pointing {
                        if track.pointSince == nil { track.pointSince = now }
                        if now - track.pointSince! >= t.pointHold { track.leave(); return }
                    } else {
                        track.pointSince = nil
                    }
                    if let reading, reading.fist || reading.pattern {
                        track.lastSupported = now
                    } else if now - track.lastSupported > t.grace {
                        track.leave()
                    }
                } else if let reading, reading.fist, reading.pattern, !reading.pointing {
                    if track.rejoinSince == nil { track.rejoinSince = now }
                    if now - track.rejoinSince! >= t.rejoinHold {
                        track.swinging = true
                        track.lastSupported = now
                        track.rejoinSince = nil
                    }
                } else {
                    track.rejoinSince = nil
                }
            }
            advance(&left, l)
            advance(&right, r)
            engaged = left.swinging || right.swinging
        }
        if !engaged {
            left.leave()
            right.leave()
        }

        // What holds the swing, over the swinging hands.
        var support: RAVEArmSwingSupport = .none
        if engaged {
            var anyFist = false, anyPattern = false
            if left.swinging, let l { anyFist = anyFist || l.fist; anyPattern = anyPattern || l.pattern }
            if right.swinging, let r { anyFist = anyFist || r.fist; anyPattern = anyPattern || r.pattern }
            support = anyFist && anyPattern ? .both
                : anyFist ? .fist
                : anyPattern ? .pattern
                : .grace
        }

        // Mean speed over the swinging hands we can see, so a hand that is
        // aiming, or out of view, halves nothing.
        var handSpeed: Float = 0
        var speedCount = 0
        if l != nil, left.swinging || !engaged { handSpeed += simd_length(left.velocity); speedCount += 1 }
        if r != nil, right.swinging || !engaged { handSpeed += simd_length(right.velocity); speedCount += 1 }
        if speedCount > 0 { handSpeed /= Float(speedCount) }

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
            let sum = (left.swinging ? pointing(leftSample) : .zero)
                    + (right.swinging ? pointing(rightSample) : .zero)
            let planar = SIMD2(simd_dot(sum, basis.right), simd_dot(sum, basis.forward))
            let length = simd_length(planar)
            if length > 1e-3 {
                heading = planar / length
            }
            // Hold the last good heading through a frame with no usable hand.
            dir = heading
        }

        // Jump: the swinging hands flick up together. A jogging stroke is
        // anti-phase, so both hands rising fast at once is the flick and not
        // the gait. One hand swinging alone has no partner to check against;
        // its own flick counts only with `oneArmJump`, since without a partner
        // a big stroke or a reach can read as one.
        var jumpBegan = false
        let flicked: Bool
        switch (left.swinging, right.swinging) {
        case (true, true):
            flicked = abs(left.lastUpFlick - right.lastUpFlick) <= t.jumpPairWindow
                && now - max(left.lastUpFlick, right.lastUpFlick) <= t.jumpPairWindow
        case (true, false): flicked = t.oneArmJump && now - left.lastUpFlick <= t.jumpPairWindow
        case (false, true): flicked = t.oneArmJump && now - right.lastUpFlick <= t.jumpPairWindow
        case (false, false): flicked = false
        }
        if engaged, flicked, now - lastJump >= t.jumpCooldown {
            jumpBegan = true
            lastJump = now
        }

        return RAVEArmSwingOutput(
            engaged: engaged,
            leftSwinging: left.swinging,
            rightSwinging: right.swinging,
            vector: dir * smoothed,
            speed01: smoothed,
            handSpeed: envelope,
            jumpBegan: jumpBegan,
            support: support
        )
    }
}
