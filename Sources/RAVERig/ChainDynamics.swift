import Foundation
import simd

/// Secondary motion for a chain of joints — a tail, an ear, a strap — as a
/// string of particles that gravity pulls on, the body drags around, and a
/// spring returns toward the shape the animation asked for.
///
/// The animation gives a shape every frame: where each joint would be if the
/// chain were rigid. This does not replace that shape, it lags behind it.
/// Each particle is pulled toward its animated position by a spring, down by
/// a fraction of gravity — a tail is muscle and bone, not rope, so it feels
/// gravity without hanging from it — and carries its own momentum from frame
/// to frame, which is what makes it trail a turn and bounce at a stop.
/// Segment lengths are then enforced from the base outward, and a bend limit
/// keeps consecutive segments from folding onto each other, so the result is
/// a smooth curve of the right length however hard the body is thrown about.
///
/// Positions are in whatever space the caller works in; gravity is along
/// `-Y`, so that space had better be Y-up world space. Pure arithmetic, no
/// framework: the same code poses a GoldSrc model's tail in halflife-visionos
/// and is testable on the Mac in a fraction of a second.
public struct ChainDynamics: Sendable, Equatable {

    public struct Settings: Sendable, Equatable {
        /// Metres per second squared, along -Y.
        public var gravity: Float = 9.81
        /// How much of gravity the chain feels. At one it is a rope; a tail
        /// held up by its own muscle feels much less. With the stiffness
        /// below, the Synth's 1.15 m tail droops 15 cm at the tip and
        /// trails 9 cm behind a 0.5 m/s walk (measured in the tests).
        public var gravityScale: Float = 0.6
        /// Spring toward the animated shape, per second squared. Higher is
        /// stiffer: less droop, less lag, quicker return.
        public var stiffness: Float = 40
        /// Velocity lost per second. Higher settles faster with less bounce.
        public var damping: Float = 6
        /// Most a segment may bend away from the one before it, in degrees.
        public var maxBendDegrees: Float = 35
        /// Integration step. The spring is stable while
        /// `stiffness * substep²` stays well under one.
        public var substep: Float = 1.0 / 120
        /// Radius of the chain itself, so a hand meets its surface rather
        /// than its centreline. One value along the whole length; the
        /// Synth's tail tapers, and this sits between its base and its tip.
        public var thickness: Float = 0.035
        /// A base moved further than this in one frame was teleported, and
        /// the chain is put down where it now is rather than whipped across
        /// the room to catch up.
        public var teleportDistance: Float = 0.5
        /// Radius at the tip, when the chain tapers; nil keeps `thickness`
        /// along the whole length.
        public var tipThickness: Float?
        /// How much of a particle's slide along a surface is lost each time
        /// it is pushed out of one, 0...1. Zero is ice: a tail laid over a
        /// hand slips off. Higher and it drapes and stays.
        /// The hold is against the surface's own motion, so a moving hand
        /// carries what lies on it.
        public var friction: Float = 0

        public init() {}
    }

    /// A limb or a forearm the chain may not pass through: a capsule from
    /// `a` to `b`.
    public struct Capsule: Sendable, Equatable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var radius: Float

        public init(a: SIMD3<Float>, b: SIMD3<Float>, radius: Float) {
            self.a = a
            self.b = b
            self.radius = radius
        }
    }

    /// A particle held at a point: a hand closed round the chain. The chain
    /// between the base and the hold is drawn up to it as far as its length
    /// allows; what is left over is `stretch`.
    public struct Hold: Sendable, Equatable {
        /// 1...count-1; the base is the body's.
        public var particle: Int
        public var point: SIMD3<Float>

        public init(particle: Int, point: SIMD3<Float>) {
            self.particle = particle
            self.point = point
        }
    }

    /// Something the chain may not pass through — a hand, in practice: a
    /// palm and fingertips as spheres. A particle found inside one is pushed
    /// to its surface, and the Verlet integration turns that displacement
    /// into velocity, so a hand swept through the chain flicks it.
    public struct Sphere: Sendable, Equatable {
        public var center: SIMD3<Float>
        public var radius: Float
        /// How it is moving, metres a second: with `Settings.friction`, what
        /// a chain resting on it is carried along by.
        public var velocity: SIMD3<Float>

        public init(center: SIMD3<Float>, radius: Float, velocity: SIMD3<Float> = .zero) {
            self.center = center
            self.radius = radius
            self.velocity = velocity
        }
    }

    public var settings: Settings
    /// What is holding the chain this frame. Set before `step`; kept until
    /// changed.
    public var holds: [Hold] = []
    /// How far the holds asked the chain to reach past its own length on the
    /// last step, summed: from where each held particle ended up to where its
    /// hold is. Zero while every hold is within reach. This is the pull a
    /// hand puts on whatever the base is attached to.
    public private(set) var stretch: SIMD3<Float> = .zero
    /// Current particle positions, base first. The base is pinned to the
    /// animated base every step.
    public private(set) var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    /// Segment lengths as of the last step, read off the animated shape.
    public private(set) var lengths: [Float]

    /// Starts the chain at `shape`, at rest.
    public init(shape: [SIMD3<Float>], settings: Settings = Settings()) {
        self.settings = settings
        positions = shape
        previous = shape
        lengths = Self.lengths(of: shape)
    }

    public var count: Int { positions.count }

    /// Puts the chain down at `shape` with no velocity.
    public mutating func reset(to shape: [SIMD3<Float>]) {
        positions = shape
        previous = shape
        lengths = Self.lengths(of: shape)
    }

    /// Advances the chain by `deltaTime` toward the animated `shape`.
    ///
    /// - Parameters:
    ///   - shape: where the animation puts each joint this frame, base first.
    ///     Its first entry pins the base; its segment lengths are the ones
    ///     enforced, so a rescaled character rescales the chain.
    ///   - floor: height nothing may sink below, when there is a floor.
    ///   - obstacles: volumes the chain is kept out of, this frame.
    ///   - capsules: limbs it is kept out of.
    ///   - measuring: the shape the segment lengths are read from, when
    ///     `shape` has been bent into something the chain is only drawn
    ///     toward (a curl) and no longer has the chain's own lengths.
    public mutating func step(toward shape: [SIMD3<Float>], deltaTime: Float, floor: Float? = nil,
                              obstacles: [Sphere] = [], capsules: [Capsule] = [],
                              measuring: [SIMD3<Float>]? = nil) {
        stretch = .zero
        guard shape.count == positions.count, shape.count >= 2 else {
            reset(to: shape)
            return
        }
        if simd_distance(shape[0], positions[0]) > settings.teleportDistance {
            reset(to: shape)
            return
        }
        let held = holds.filter { $0.particle >= 1 && $0.particle < positions.count }
        lengths = Self.lengths(of: measuring.flatMap { $0.count == shape.count ? $0 : nil } ?? shape)
        let total = min(max(deltaTime, 0), 0.1)
        guard total > 0 else { return }
        let steps = max(1, Int((total / settings.substep).rounded(.up)))
        let h = total / Float(steps)
        let keep = max(0, 1 - settings.damping * h)
        let gravity = SIMD3<Float>(0, -settings.gravity * settings.gravityScale, 0)
        let maxBend = settings.maxBendDegrees * .pi / 180

        for _ in 0..<steps {
            positions[0] = shape[0]
            previous[0] = shape[0]
            for i in 1..<positions.count {
                let acceleration = gravity + (shape[i] - positions[i]) * settings.stiffness
                let next = positions[i] + (positions[i] - previous[i]) * keep + acceleration * h * h
                previous[i] = positions[i]
                positions[i] = next
            }
            // Constraints, a few passes so the holds, the bend limit and the
            // lengths agree with each other.
            for _ in 0..<3 {
                // A held particle goes to its hold, and draws the chain
                // between it and the base after it. The pass outward from the
                // base then has the last word, so the base stays the body's
                // and a hold further off than the chain reaches leaves the
                // chain taut, pointing at it.
                for hold in held {
                    positions[hold.particle] = hold.point
                    var i = hold.particle
                    while i > 1 {
                        let toward = positions[i - 1] - positions[i]
                        let distance = simd_length(toward)
                        if distance > 1e-6 {
                            positions[i - 1] = positions[i] + toward / distance * lengths[i - 1]
                        }
                        i -= 1
                    }
                }
                for i in 1..<positions.count {
                    var direction = positions[i] - positions[i - 1]
                    let distance = simd_length(direction)
                    direction = distance > 1e-6 ? direction / distance
                        : (i >= 2 ? simd_normalize(positions[i - 1] - positions[i - 2]) : SIMD3<Float>(0, -1, 0))
                    if i >= 2 {
                        let along = simd_normalize(positions[i - 1] - positions[i - 2])
                        direction = Self.limited(direction, toward: along, maxBend: maxBend)
                    }
                    positions[i] = positions[i - 1] + direction * lengths[i - 1]
                    if let floor, positions[i].y < floor {
                        positions[i].y = floor
                        slow(i, along: SIMD3<Float>(0, 1, 0), surface: .zero)
                    }
                    // The whole segment is solid, not just its ends: the
                    // joints sit a hand's breadth apart, and a fingertip
                    // between two of them has to meet something. The
                    // segment is a capsule of the chain's thickness; the
                    // push lands on its two ends in proportion to where
                    // along it the contact is, and never on the pinned base.
                    let radius = thickness(ofSegment: i)
                    for sphere in obstacles {
                        let (closest, t) = Self.closestPoint(on: positions[i - 1], positions[i], to: sphere.center)
                        push(segment: i, at: t, away: closest - sphere.center, reach: sphere.radius + radius,
                             surface: sphere.velocity * h)
                    }
                    for capsule in capsules {
                        let (onChain, t, onCapsule) = Self.closestPoints(positions[i - 1], positions[i],
                                                                         capsule.a, capsule.b)
                        push(segment: i, at: t, away: onChain - onCapsule, reach: capsule.radius + radius,
                             surface: .zero)
                    }
                }
            }
        }
        for hold in held { stretch += hold.point - positions[hold.particle] }
    }

    /// The chain's radius at segment `i` (between particles `i - 1` and `i`).
    public func thickness(ofSegment i: Int) -> Float {
        guard let tip = settings.tipThickness, positions.count > 2 else { return settings.thickness }
        let t = (Float(i) - 0.5) / Float(positions.count - 1)
        return settings.thickness + (tip - settings.thickness) * min(max(t, 0), 1)
    }

    /// Moves segment `i` out of something it is `away` from by less than
    /// `reach`, the push shared between its two ends by where along it the
    /// contact is.
    private mutating func push(segment i: Int, at t: Float, away: SIMD3<Float>, reach: Float,
                               surface: SIMD3<Float>) {
        let distance = simd_length(away)
        guard distance < reach else { return }
        // A segment dead on the centre has no way out; send it up, which
        // for a hand under a tail is right.
        let outward = distance > 1e-5 ? away / distance : SIMD3<Float>(0, 1, 0)
        let push = outward * (reach - distance)
        if i - 1 > 0 {
            positions[i - 1] += push * (1 - t)
            positions[i] += push * t
            slow(i - 1, along: outward, surface: surface)
        } else {
            positions[i] += push
        }
        slow(i, along: outward, surface: surface)
    }

    /// Friction: takes `settings.friction` of particle `i`'s slide across a
    /// surface whose normal is `normal` and which itself moves `surface`
    /// this substep.
    private mutating func slow(_ i: Int, along normal: SIMD3<Float>, surface: SIMD3<Float>) {
        guard settings.friction > 0 else { return }
        let velocity = positions[i] - previous[i] - surface
        let sliding = velocity - normal * simd_dot(velocity, normal)
        previous[i] += sliding * min(settings.friction, 1)
    }

    /// Whether any segment is inside one of `obstacles`, for diagnostics.
    public func touches(_ obstacles: [Sphere]) -> Bool {
        for i in 1..<positions.count {
            for sphere in obstacles {
                let (closest, _) = Self.closestPoint(on: positions[i - 1], positions[i], to: sphere.center)
                if simd_distance(closest, sphere.center) < sphere.radius + settings.thickness - 1e-4 { return true }
            }
        }
        return false
    }

    /// The point on segment `a`–`b` nearest `point`, and how far along it lies.
    static func closestPoint(on a: SIMD3<Float>, _ b: SIMD3<Float>,
                             to point: SIMD3<Float>) -> (SIMD3<Float>, Float) {
        let ab = b - a
        let length = simd_length_squared(ab)
        guard length > 1e-10 else { return (a, 0) }
        let t = simd_clamp(simd_dot(point - a, ab) / length, 0, 1)
        return (a + ab * t, t)
    }

    /// The nearest points of segments `p1`–`q1` and `p2`–`q2`: the point on
    /// the first, how far along the first it lies, and the point on the
    /// second.
    static func closestPoints(_ p1: SIMD3<Float>, _ q1: SIMD3<Float>, _ p2: SIMD3<Float>,
                              _ q2: SIMD3<Float>) -> (SIMD3<Float>, Float, SIMD3<Float>) {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s: Float = 0, t: Float = 0
        if a <= 1e-10 && e <= 1e-10 { return (p1, 0, p2) }
        if a <= 1e-10 {
            t = simd_clamp(f / e, 0, 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= 1e-10 {
                s = simd_clamp(-c / a, 0, 1)
            } else {
                let b = simd_dot(d1, d2)
                let denominator = a * e - b * b
                s = denominator > 1e-10 ? simd_clamp((b * f - c * e) / denominator, 0, 1) : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = simd_clamp(-c / a, 0, 1)
                } else if t > 1 {
                    t = 1
                    s = simd_clamp((b - c) / a, 0, 1)
                }
            }
        }
        return (p1 + d1 * s, s, p2 + d2 * t)
    }

    /// `direction`, rotated toward `along` until they are within `maxBend`.
    static func limited(_ direction: SIMD3<Float>, toward along: SIMD3<Float>, maxBend: Float) -> SIMD3<Float> {
        let cosine = simd_clamp(simd_dot(direction, along), -1, 1)
        let angle = acos(cosine)
        guard angle > maxBend else { return direction }
        var perpendicular = direction - along * cosine
        let magnitude = simd_length(perpendicular)
        guard magnitude > 1e-6 else { return along }
        perpendicular /= magnitude
        return simd_normalize(along * cos(maxBend) + perpendicular * sin(maxBend))
    }

    static func lengths(of shape: [SIMD3<Float>]) -> [Float] {
        zip(shape, shape.dropFirst()).map { simd_length($1 - $0) }
    }
}

/// The deliberate part of a tail's motion: a wag about the base, and how
/// high the tail is carried.
///
/// The physics above supplies the lag and the bounce; this supplies the
/// intent. It rotates the animated shape as a whole about the base — a wag
/// is driven from the root of a tail, and the tip follows late, which the
/// spring then produces on its own — and it eases between styles rather
/// than switching, so a mood change is a tail speeding up, not a tail
/// jumping.
public struct TailSway: Sendable, Equatable {

    public struct Style: Sendable, Equatable {
        /// Wags per second.
        public var frequency: Float
        /// Peak swing to each side of centre, in radians.
        public var amplitude: Float
        /// How far the whole tail is raised above its animated carriage, in
        /// radians. Negative tucks it.
        public var lift: Float

        public init(frequency: Float, amplitude: Float, lift: Float) {
            self.frequency = frequency
            self.amplitude = amplitude
            self.lift = lift
        }

        public init(frequencyHz: Float, amplitudeDegrees: Float, liftDegrees: Float) {
            self.init(frequency: frequencyHz, amplitude: amplitudeDegrees * .pi / 180,
                      lift: liftDegrees * .pi / 180)
        }

        public static let still = Style(frequency: 0, amplitude: 0, lift: 0)
    }

    /// The style being eased toward.
    public var wanted: Style
    /// The style in effect right now.
    public private(set) var current: Style
    /// How quickly `current` follows `wanted`, per second.
    public var responseRate: Float = 2
    private var phase: Float = 0

    /// Fastest the tail's carriage may swing round to follow the body, in
    /// radians per second.
    ///
    /// The body turns on the spot in a fraction of a second. A tail whose
    /// animated shape is welded to the pelvis sweeps its tip through metres
    /// in that time, and the spring then hauls the simulated tail after it
    /// along the chord — through the legs — which reads as a flick. A real
    /// tail is carried round after the body, so the heading the shape is
    /// held at follows the body's at a bounded rate and the physics only
    /// ever sees a target that moves at a pace it can keep up with.
    public var maxTurnRate: Float = .pi
    /// The heading, about `up`, the animated shape is currently carried at.
    /// Nil until the first `follow`, which adopts the body's heading.
    public private(set) var heading: Float?

    public init(style: Style) {
        wanted = style
        current = style
    }

    /// Forgets the followed heading, so the next `follow` adopts the body's
    /// outright — for a character that has been teleported.
    public mutating func snapHeading() {
        heading = nil
    }

    /// `shape` turned about its base so it faces the followed heading rather
    /// than the body's, with the followed heading advanced toward the body's
    /// by at most `maxTurnRate` times `deltaTime`.
    ///
    /// Heading is the direction from the base to the tip in the plane
    /// perpendicular to `up`; a shape hanging straight up or down has none
    /// and is passed through untouched.
    public mutating func follow(_ shape: [SIMD3<Float>], deltaTime: Float,
                                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> [SIMD3<Float>] {
        guard shape.count >= 2 else { return shape }
        let base = shape[0]
        let along = shape[shape.count - 1] - base
        let flat = along - up * simd_dot(along, up)
        guard simd_length(flat) > 0.05 * max(simd_length(along), 1e-6) else { return shape }
        // Yaw measured in a frame built on `up`, so this works for any up.
        let reference = abs(up.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let right = simd_normalize(simd_cross(up, reference))
        let forward = simd_cross(right, up)
        let bodyHeading = atan2(simd_dot(flat, right), simd_dot(flat, forward))
        guard let held = heading else {
            heading = bodyHeading
            return shape
        }
        var delta = bodyHeading - held
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let limit = maxTurnRate * min(max(deltaTime, 0), 0.1)
        let advanced = held + min(max(delta, -limit), limit)
        heading = advanced
        let lag = advanced - bodyHeading
        guard abs(lag) > 1e-5 else { return shape }
        let rotation = simd_quatf(angle: lag, axis: simd_normalize(up))
        return shape.map { base + rotation.act($0 - base) }
    }

    /// Advances the wag by `deltaTime` and returns the angles to apply:
    /// `yaw` swings the tail to the side, `pitch` raises it.
    public mutating func advance(by deltaTime: Float) -> (yaw: Float, pitch: Float) {
        let dt = min(max(deltaTime, 0), 0.1)
        let t = min(1, responseRate * dt)
        current.frequency += (wanted.frequency - current.frequency) * t
        current.amplitude += (wanted.amplitude - current.amplitude) * t
        current.lift += (wanted.lift - current.lift) * t
        // Phase accumulates, so a change of frequency changes the pace of
        // the wag without moving the tail.
        phase += 2 * .pi * current.frequency * dt
        if phase > 2 * .pi { phase -= 2 * .pi }
        // A wag is not a pure side-to-side: the tail rides up a little at
        // each extreme, which is what the doubled-frequency pitch adds.
        let yaw = current.amplitude * sin(phase)
        let pitch = current.lift + current.amplitude * 0.15 * (1 - cos(2 * phase)) / 2
        return (yaw, pitch)
    }

    /// `shape` rotated as one piece about its base: by `yaw` about `up`, and
    /// raised by `pitch` toward `up`.
    public static func apply(to shape: [SIMD3<Float>], yaw: Float, pitch: Float,
                             up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> [SIMD3<Float>] {
        guard shape.count >= 2, abs(yaw) > 1e-6 || abs(pitch) > 1e-6 else { return shape }
        let base = shape[0]
        let along = shape[shape.count - 1] - base
        var rotation = simd_quatf(angle: yaw, axis: simd_normalize(up))
        // Raising the tail means turning it toward `up` about the axis
        // perpendicular to both — undefined for a tail already pointing
        // straight up or down, which then simply does not pitch.
        let raiseAxis = simd_cross(along, up)
        if simd_length(raiseAxis) > 1e-5 {
            rotation = simd_normalize(rotation * simd_quatf(angle: pitch, axis: simd_normalize(raiseAxis)))
        }
        return shape.map { base + rotation.act($0 - base) }
    }
}
