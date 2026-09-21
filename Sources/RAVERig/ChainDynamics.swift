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
        /// A base moved further than this in one frame was teleported, and
        /// the chain is put down where it now is rather than whipped across
        /// the room to catch up.
        public var teleportDistance: Float = 0.5

        public init() {}
    }

    public var settings: Settings
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
    public mutating func step(toward shape: [SIMD3<Float>], deltaTime: Float, floor: Float? = nil) {
        guard shape.count == positions.count, shape.count >= 2 else {
            reset(to: shape)
            return
        }
        if simd_distance(shape[0], positions[0]) > settings.teleportDistance {
            reset(to: shape)
            return
        }
        lengths = Self.lengths(of: shape)
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
            // Constraints, base outward, a few passes so the bend limit and
            // the lengths agree with each other.
            for _ in 0..<3 {
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
                    if let floor, positions[i].y < floor { positions[i].y = floor }
                }
            }
        }
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

    public init(style: Style) {
        wanted = style
        current = style
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
