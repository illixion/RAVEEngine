import Foundation
import simd

/// Where the feet of a body that is *not* following a walk cycle belong: a
/// tracked VR player, whose hips go wherever the headset takes them and
/// whose travel through the world comes from a thumbstick as often as from
/// walking.
///
/// `LegStepper` is the other answer, and the right one for a character that
/// walks where it faces: it runs a distance-driven cycle along its forward
/// direction, with the left foot on the left of *that direction*. A VR body
/// breaks the assumption constantly — it strafes, backpedals, turns on the
/// spot, sways — and a cycle laid along the travel direction then puts the
/// left foot on the body's right the moment the player steps backward.
///
/// So this works the other way round. Each foot has a stance, a spot beside
/// the hips on its own side of the *body*, and holds still in the world until
/// it has drifted too far from that stance or turned too far from the body's
/// facing. Then it steps — one foot at a time, the other holding the body up
/// — to where the stance will be by the time it lands, which at speed is
/// ahead of the hips so the body passes over it. Standing still never
/// shuffles; walking, strafing and turning all come out as steps, because
/// every one of them is just the stance moving away from a planted foot.
///
/// Y is up, as in `LegStepper`. Units are the caller's: every length here is
/// in them and every time is in seconds.
public struct FootPlanter: Sendable {

    /// Distance between the two stances, across the body.
    public var footSpacing: Float
    /// How far a planted foot may drift from its stance before it steps.
    public var stepThreshold: Float
    /// How far, radians, a planted foot may be turned from the body's facing
    /// before it steps. Turning on the spot is taken in steps, not a pivot.
    public var turnThreshold: Float
    /// Seconds a step takes at a standstill. It shortens with speed, down to
    /// `minStepDuration`, so a walk's steps keep up with the body.
    public var stepDuration: Float
    public var minStepDuration: Float
    /// Longest step a foot may take: the lead ahead of the stance is capped
    /// at half of it.
    public var maxStride: Float
    /// Peak height of the swinging foot above the straight line it travels.
    public var liftHeight: Float

    public init(footSpacing: Float, stepThreshold: Float, turnThreshold: Float = 0.6,
                stepDuration: Float = 0.3, minStepDuration: Float = 0.14,
                maxStride: Float, liftHeight: Float) {
        self.footSpacing = footSpacing
        self.stepThreshold = max(stepThreshold, 1e-4)
        self.turnThreshold = turnThreshold
        self.stepDuration = max(stepDuration, 0.02)
        self.minStepDuration = max(min(minStepDuration, stepDuration), 0.02)
        self.maxStride = max(maxStride, 1e-3)
        self.liftHeight = liftHeight
    }

    /// A planter proportioned for a leg: a threshold of a fifth of its length
    /// lets a player lean and sway without the feet shuffling, and a stride
    /// of one leg length is an ordinary walking step.
    public static func forLeg(length: Float, hipWidth: Float) -> FootPlanter {
        FootPlanter(footSpacing: max(hipWidth, 1e-3),
                    stepThreshold: length * 0.2,
                    maxStride: length,
                    liftHeight: length * 0.12)
    }

    /// One foot's placement this frame.
    public struct Placement: Sendable, Equatable {
        /// Where the sole is, on the floor while planted.
        public var position: SIMD3<Float>
        /// Which way the foot points, unit, on the floor plane.
        public var forward: SIMD3<Float>
        /// True while the foot is on the ground and must not move.
        public var planted: Bool
        /// 0 at takeoff to 1 at touchdown while swinging; nil while planted.
        public var swingProgress: Float?
    }

    private struct Swing {
        var from: SIMD3<Float>
        var fromForward: SIMD3<Float>
        var progress: Float
        var duration: Float
    }

    private var plant: [SIMD3<Float>?] = [nil, nil]
    private var heading: [SIMD3<Float>] = [SIMD3(0, 0, 1), SIMD3(0, 0, 1)]
    private var swing: [Swing?] = [nil, nil]
    private var lastStepped = 1

    /// Forgets where the feet were; the next update stands them in their
    /// stances. For a teleport, a respawn, or landing from a fall.
    public mutating func reset() {
        plant = [nil, nil]
        swing = [nil, nil]
    }

    /// True while either foot is in the air.
    public var isStepping: Bool { swing[0] != nil || swing[1] != nil }

    /// Advances both feet by one frame.
    ///
    /// - Parameters:
    ///   - hips: the body's position, in world space. Only its floor-plane
    ///     position matters; heights come from `floor`.
    ///   - forward: which way the body faces. Projected onto the floor plane.
    ///   - velocity: how fast the body is travelling through the world, so a
    ///     step can land where the stance is going rather than where it was.
    ///   - deltaTime: seconds since the last update.
    ///   - floor: the height of the ground under a point.
    public mutating func update(hips: SIMD3<Float>, forward: SIMD3<Float>,
                                velocity: SIMD3<Float>, deltaTime: Float,
                                floor: (SIMD3<Float>) -> Float)
        -> (left: Placement, right: Placement) {
        var f = SIMD3<Float>(forward.x, 0, forward.z)
        f = simd_length(f) > 1e-5 ? simd_normalize(f) : SIMD3(0, 0, 1)
        let left = SIMD3<Float>(f.z, 0, -f.x)
        let v = SIMD3<Float>(velocity.x, 0, velocity.z)
        let speed = simd_length(v)
        let dt = max(deltaTime, 0)

        // A step takes less time the faster the body goes, so the swinging
        // foot keeps up; half a stride is as far ahead as a foot will reach.
        let duration = speed > 1e-4
            ? min(stepDuration, max(minStepDuration, maxStride / (2 * speed)))
            : stepDuration
        var lead = v * duration
        if simd_length(lead) > maxStride / 2 { lead = simd_normalize(lead) * (maxStride / 2) }

        func stance(_ foot: Int) -> SIMD3<Float> {
            var p = SIMD3<Float>(hips.x, 0, hips.z) + left * (footSpacing / 2) * (foot == 0 ? 1 : -1)
            p.y = floor(p)
            return p
        }
        // Where a step lands: the stance, led by the velocity so the body
        // passes over the foot mid-stance. Sideways, only the foot on the
        // side of travel may lead — a side-step opens with the leading foot
        // and closes with the trailing one, which comes in toward the hips
        // but not past them. Leading the trailing foot too put it on the
        // wrong side of the body on every strafe.
        func target(_ foot: Int) -> SIMD3<Float> {
            let sign: Float = foot == 0 ? 1 : -1
            let lateral = simd_dot(lead, left)
            let along = lead - left * lateral
            let allowed = lateral * sign > 0 ? lateral : sign * max(lateral * sign, -footSpacing / 4)
            var p = stance(foot) + along + left * allowed
            p.y = floor(p)
            return p
        }

        // First frame, or after a reset: stand in the stances.
        for foot in 0...1 where plant[foot] == nil && swing[foot] == nil {
            plant[foot] = stance(foot)
            heading[foot] = f
        }
        // A plant the body is nowhere near is a leftover — a teleport, a
        // respawn — not a footprint to walk back to.
        for foot in 0...1 where swing[foot] == nil {
            if let p = plant[foot], horizontalDistance(p, hips) > maxStride * 2 + footSpacing {
                plant[foot] = stance(foot)
                heading[foot] = f
            }
        }

        // Finish or advance the swing in progress.
        for foot in 0...1 {
            guard var s = swing[foot] else { continue }
            s.progress = min(1, s.progress + dt / s.duration)
            if s.progress >= 1 {
                plant[foot] = target(foot)
                heading[foot] = f
                swing[foot] = nil
                lastStepped = foot
            } else {
                swing[foot] = s
            }
        }

        // Start a step when nothing is in the air: whichever foot has
        // drifted or turned furthest past its limit, the one that did not
        // step last winning a tie, so a walk alternates.
        if swing[0] == nil, swing[1] == nil {
            var best: (foot: Int, need: Float)?
            for foot in [1 - lastStepped, lastStepped] {
                guard let p = plant[foot] else { continue }
                let drift = simd_distance(p, target(foot)) / stepThreshold
                let turn = acos(simd_clamp(simd_dot(heading[foot], f), -1, 1)) / turnThreshold
                // A body sidestepping slowly toward a planted foot reaches it
                // before the drift does; a foot the hips are about to pass
                // over steps out of the way rather than end up on the wrong
                // side of them.
                let lateral = simd_dot(SIMD3<Float>(p.x - hips.x, 0, p.z - hips.z), left)
                    * (foot == 0 ? 1 : -1)
                let crossing: Float = lateral < 0 ? 2 : 0
                let need = max(drift, turn, crossing)
                if need > 1, need > (best?.need ?? 0) + 1e-3 { best = (foot, need) }
            }
            if let foot = best?.foot, let p = plant[foot] {
                swing[foot] = Swing(from: p, fromForward: heading[foot], progress: 0, duration: duration)
                plant[foot] = nil
            }
        }

        func placement(_ foot: Int) -> Placement {
            guard let s = swing[foot] else {
                return Placement(position: plant[foot] ?? stance(foot), forward: heading[foot],
                                 planted: true, swingProgress: nil)
            }
            let t = s.progress * s.progress * (3 - 2 * s.progress)
            let to = target(foot)
            var p = simd_mix(s.from, to, SIMD3<Float>(repeating: t))
            // Peaks early and comes down long, as in LegStepper: a foot
            // descends into its landing rather than dropping off a hop.
            p.y += sin(pow(s.progress, 0.65) * .pi) * liftHeight
            p = heldOnOwnSide(p, hips: hips, left: left, foot: foot)
            var h = simd_mix(s.fromForward, f, SIMD3<Float>(repeating: t))
            h = simd_length(h) > 1e-5 ? simd_normalize(h) : f
            return Placement(position: p, forward: h, planted: false, swingProgress: s.progress)
        }
        return (placement(0), placement(1))
    }

    /// The swinging foot's straight line from takeoff to landing can pass
    /// through the other leg on a turn; held on its own side of the hips it
    /// goes round instead.
    private func heldOnOwnSide(_ point: SIMD3<Float>, hips: SIMD3<Float>, left: SIMD3<Float>,
                               foot: Int) -> SIMD3<Float> {
        let sign: Float = foot == 0 ? 1 : -1
        let offset = SIMD3<Float>(point.x - hips.x, 0, point.z - hips.z)
        let lateral = simd_dot(offset, left) * sign
        let limit = footSpacing * 0.1
        guard lateral < limit else { return point }
        return point + left * sign * (limit - lateral)
    }

    private func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2<Float>(a.x - b.x, a.z - b.z))
    }
}
