import Foundation
import simd

/// Generates where a walking character's feet belong, from the ground up.
///
/// The usual pipeline runs the other way: play a walk clip, and hope the
/// character's travel speed matches whatever stride the clip happens to carry.
/// That works while the clip and the body agree. Retargeting between very
/// different builds breaks the agreement — on a digitigrade leg the transferred
/// rotations leave the feet sliding at 95% of the travel speed, planted in 6%
/// of frames against the source's 68% — and no travel speed repairs it,
/// because the feet never stop moving relative to the hips at all. Slowing the
/// character down just scales the sliding down with it.
///
/// So the feet stop being animated and start being placed. A stance foot has
/// one job: hold still in the world. This tracks distance travelled, alternates
/// the two feet between holding still and arcing to the next footfall, and
/// hands out positions an IK solver can aim at. Ground sync is then not
/// something to tune — the planted foot is stationary by construction.
public struct LegStepper: Sendable {

    /// How far the body advances per step. A step much shorter than the leg
    /// reads as a shuffle; much longer and the leg cannot reach the ground.
    public var stepLength: Float
    /// Distance between the feet, across the direction of travel.
    public var footSpacing: Float
    /// Peak height of the swinging foot above the floor.
    public var liftHeight: Float
    /// Share of a step the foot spends on the ground. Real walks overlap —
    /// both feet are down for part of the cycle — which is what keeps a walk
    /// from reading as a run.
    public var stanceFraction: Float

    /// Distance covered so far, which is the only clock this needs. Driving
    /// the cycle from distance rather than time is what makes the feet agree
    /// with the ground at any speed, including a standstill.
    private var distance: Float = 0
    /// Distance the cycle has been driven through, for diagnostics. This is
    /// the stepper's entire clock: if it stops advancing, the gait stops.
    public var coveredDistance: Float { distance }
    /// Where in the step cycle the leading foot is, 0 to 1.
    public var phase: Float { (distance / stepLength).truncatingRemainder(dividingBy: 1) }
    /// Where each foot is held while it is on the ground.
    private var plant: [SIMD3<Float>?] = [nil, nil]
    /// Where each swing began, so the foot arcs from where it actually left.
    private var takeoff: [SIMD3<Float>?] = [nil, nil]
    /// Last position handed out for a swinging foot — the landing spot, once
    /// the swing ends.
    private var swinging: [SIMD3<Float>?] = [nil, nil]
    private var wasPlanted: [Bool] = [true, true]
    /// Which way the body faced last frame, so a turn can be charged as
    /// distance.
    private var lastForward: SIMD3<Float>?
    /// Which foot is closing up to its neutral stance, and how far through
    /// that move it is. Only one foot closes at a time; the other holds the
    /// body up.
    private var closing: Int?
    private var closeProgress: Float = 0
    private var closeFrom: SIMD3<Float> = .zero

    public init(stepLength: Float, footSpacing: Float,
                liftHeight: Float = 0.06, stanceFraction: Float = 0.62) {
        self.stepLength = max(stepLength, 0.01)
        self.footSpacing = footSpacing
        self.liftHeight = liftHeight
        self.stanceFraction = min(max(stanceFraction, 0.5), 0.95)
    }

    /// One foot's placement this frame.
    public struct Placement: Sendable, Equatable {
        public var position: SIMD3<Float>
        /// True while the foot is on the ground and must not move.
        public var planted: Bool
        /// How far through its swing a lifted foot is, 0 at takeoff and 1 at
        /// touchdown; nil while planted. The caller needs this to roll the
        /// foot through the step — a foot that only knows its height cannot
        /// tell a takeoff from a landing, because both are near the floor.
        public var swingProgress: Float?

        public init(position: SIMD3<Float>, planted: Bool, swingProgress: Float? = nil) {
            self.position = position
            self.planted = planted
            self.swingProgress = swingProgress
        }
    }

    public mutating func reset() {
        distance = 0
        plant = [nil, nil]
        takeoff = [nil, nil]
        swinging = [nil, nil]
        wasPlanted = [true, true]
        lastForward = nil
        closing = nil
        closeProgress = 0
    }

    /// Advances the cycle and returns where both feet belong.
    ///
    /// - Parameters:
    ///   - hips: the body's position on the floor, in world space.
    ///   - forward: unit vector the character walks along, on the floor plane.
    ///   - travelled: metres covered since the last call.
    ///   - floor: height of the ground under a given point, for stepping onto
    ///     and off surfaces. Return `hips.y` to keep the feet on one level.
    public mutating func step(hips: SIMD3<Float>, forward: SIMD3<Float>, travelled: Float,
                              floor: (SIMD3<Float>) -> Float)
        -> (left: Placement, right: Placement) {
        // Turning moves the feet even when the hips do not. Each foot rides
        // an arc of radius half the hip width around the body, so a turn is
        // distance travelled as far as the gait is concerned, and counting
        // it is what makes a character take steps as it turns instead of
        // pivoting on pinned feet.
        //
        // Not counting it is what "the leg gets stuck behind and then snaps
        // back" was: through the turn the cycle did not advance at all, so
        // no foot ever reached touchdown to re-place itself, and the plant
        // was held — visibly stranded — until the sidedness guard finally
        // condemned it and moved it in one frame.
        var advance = max(travelled, 0)
        if let previous = lastForward {
            advance += acos(simd_clamp(simd_dot(previous, forward), -1, 1)) * (footSpacing / 2)
        }
        lastForward = forward
        distance += advance
        let across = simd_normalize(SIMD3<Float>(forward.z, 0, -forward.x))
        // The two feet run half a cycle apart, which is what makes them
        // alternate rather than hop.
        let phase = distance / stepLength

        func placement(foot: Int, offset: Float) -> Placement {
            let local = (phase + offset).truncatingRemainder(dividingBy: 1)
            let side = across * (footSpacing / 2) * (foot == 0 ? 1 : -1)
            // Where this foot lands if it touches down now: half a step ahead
            // of the hips, so the body passes over it through mid-stance.
            var landing = hips + forward * (stepLength / 2) + side
            landing.y = floor(landing)

            let planted = local < stanceFraction
            defer { wasPlanted[foot] = planted }

            if planted {
                // On touchdown, adopt wherever the swing actually ended; the
                // foot then does not move again until it lifts. That is the
                // whole point: a stance foot is stationary in the world, so
                // it cannot slide however fast the body is going.
                if !wasPlanted[foot] || plant[foot] == nil {
                    plant[foot] = swinging[foot] ?? landing
                }
                // Refuse a plant the body is nowhere near. A stance foot is
                // held still on purpose, so nothing else in here can notice
                // that the body has since gone somewhere else entirely — and
                // a foot held two metres behind the character is not a plant,
                // it is a leftover from the last walk.
                //
                // This is what a caller forgetting to reset used to look
                // like: the character walked, arrived, and on its next walk
                // one leg stayed pinned where the last walk had left it. An
                // honest solver straightens the leg at the unreachable target
                // and holds it, so the whole body glided along with one leg
                // up and both frozen. Caught here rather than in the caller
                // because the same thing happens on a teleport, a re-path, or
                // any placement change, and each of those would otherwise
                // need to remember separately.
                //
                // Sidedness is checked too, and separately, because the
                // reach test cannot see it: turning on the spot leaves the
                // old plant well within a leg's length of the hips and
                // simply on the wrong side of them. The solver then reaches
                // across the body for it, which is the legs crossing and the
                // shins clipping through each other on a turn-and-walk-back.
                if let held = plant[foot],
                   !within(reach: held, of: hips)
                    || !onOwnSide(held, of: hips, across: across, foot: foot) {
                    plant[foot] = landing
                    takeoff[foot] = landing
                }
                return Placement(position: plant[foot] ?? landing, planted: true)
            }

            if wasPlanted[foot] { takeoff[foot] = plant[foot] ?? landing }
            let progress = (local - stanceFraction) / (1 - stanceFraction)
            var moving = simd_mix(takeoff[foot] ?? landing, landing,
                                  SIMD3<Float>(repeating: progress))
            // The arc peaks early and comes down long, so the foot descends
            // into its landing instead of dropping off the top of a
            // symmetric hop. A symmetric sine spends as long rising as
            // falling, which reads as the whole leg being picked up and put
            // down rather than as a step.
            moving.y += sin(pow(progress, 0.65) * .pi) * liftHeight
            // The arc is a straight line through the world, and during a
            // turn its ends can be on opposite sides of the body — so the
            // line passes through the other leg. Holding the swing on its
            // own side is what stops the feet clipping through each other
            // mid-turn; the reach and sidedness guards only ever see a
            // planted foot.
            moving = heldOnOwnSide(moving, of: hips, across: across, foot: foot)
            swinging[foot] = moving
            return Placement(position: moving, planted: false, swingProgress: progress)
        }

        return (placement(foot: 0, offset: 0), placement(foot: 1, offset: 0.5))
    }

    /// Whether a foot at `point` is close enough to `hips` for the leg to
    /// plausibly be holding it.
    ///
    /// Measured on the floor plane only: a foot below the hips is normal, a
    /// foot beside them by more than the leg is long is not. `stepLength` is
    /// half a stride, so twice it is about a leg, and the spacing allows for
    /// the foot being off to the side.
    private func within(reach point: SIMD3<Float>, of hips: SIMD3<Float>) -> Bool {
        let offset = SIMD2<Float>(point.x - hips.x, point.z - hips.z)
        return simd_length(offset) <= stepLength * 2 + footSpacing
    }

    /// Whether a foot at `point` is still on its own side of the body.
    ///
    /// A little crossing toward the midline is natural — a narrow walk puts
    /// both feet nearly on one line — so this allows the plant to cross by a
    /// quarter of the hip width before calling it stale. Past that the foot
    /// is on the other leg's side, which no gait does and every turn
    /// produces.
    private func onOwnSide(_ point: SIMD3<Float>, of hips: SIMD3<Float>,
                           across: SIMD3<Float>, foot: Int) -> Bool {
        let offset = SIMD3<Float>(point.x - hips.x, 0, point.z - hips.z)
        let lateral = simd_dot(offset, across) * (foot == 0 ? 1 : -1)
        return lateral > -footSpacing * 0.25
    }

    /// Brings both feet together under the body, one step at a time.
    ///
    /// A walk that simply stops leaves the feet wherever the cycle had them
    /// — typically one well ahead of the other, sometimes one in mid-air —
    /// and handing that straight back to the idle clip is a visible shuffle
    /// as the legs jump to a standing pose. A walker does not stop like
    /// that: the trailing foot closes up beside the leading one first.
    ///
    /// Call instead of `step` once the path has run out, and fade the solver
    /// out only when this reports `settled`.
    ///
    /// - Parameter closing: distance to advance the closing foot this frame.
    /// - Returns: both placements, and whether the character is now standing.
    public mutating func settle(hips: SIMD3<Float>, forward: SIMD3<Float>,
                                closing distance: Float,
                                floor: (SIMD3<Float>) -> Float)
        -> (left: Placement, right: Placement, settled: Bool) {
        lastForward = forward
        let across = simd_normalize(SIMD3<Float>(forward.z, 0, -forward.x))

        func neutral(_ foot: Int) -> SIMD3<Float> {
            var point = hips + across * (footSpacing / 2) * (foot == 0 ? 1 : -1)
            point.y = floor(point)
            return point
        }
        func current(_ foot: Int) -> SIMD3<Float> {
            plant[foot] ?? swinging[foot] ?? neutral(foot)
        }
        // Close enough to stand on. A tenth of a step, so the pose handed
        // back to the idle clip is a standing one rather than a narrow
        // stride that still has to be blended away.
        let tolerance = stepLength * 0.1

        // Pick a foot to close: the one further from where it should be.
        if closing == nil {
            let gaps = (0...1).map { simd_distance(current($0), neutral($0)) }
            if let worst = gaps.firstIndex(of: gaps.max()!), gaps[worst] > tolerance {
                closing = worst
                closeProgress = 0
                closeFrom = current(worst)
                wasPlanted[worst] = false
            }
        }

        guard let foot = closing else {
            // Both are where they belong; hold them there.
            for index in 0...1 where plant[index] == nil { plant[index] = neutral(index) }
            return (Placement(position: current(0), planted: true),
                    Placement(position: current(1), planted: true),
                    true)
        }

        let travel = max(simd_distance(closeFrom, neutral(foot)), 0.01)
        closeProgress = min(1, closeProgress + max(distance, 0) / travel)
        var moving = simd_mix(closeFrom, neutral(foot),
                              SIMD3<Float>(repeating: closeProgress))
        moving.y += sin(pow(closeProgress, 0.65) * .pi) * liftHeight * 0.6
        moving = heldOnOwnSide(moving, of: hips, across: across, foot: foot)

        let arrived = closeProgress >= 1
        if arrived {
            plant[foot] = neutral(foot)
            swinging[foot] = nil
            wasPlanted[foot] = true
            closing = nil
        } else {
            swinging[foot] = moving
        }

        let other = 1 - foot
        if plant[other] == nil { plant[other] = current(other) }
        let closingPlacement = Placement(position: arrived ? neutral(foot) : moving,
                                         planted: arrived,
                                         swingProgress: arrived ? nil : closeProgress)
        let holdingPlacement = Placement(position: current(other), planted: true)
        return foot == 0
            ? (closingPlacement, holdingPlacement, false)
            : (holdingPlacement, closingPlacement, false)
    }

    /// The same point, pushed back to its own side of the body if it has
    /// strayed across. Used on a swinging foot, which no other guard covers.
    private func heldOnOwnSide(_ point: SIMD3<Float>, of hips: SIMD3<Float>,
                               across: SIMD3<Float>, foot: Int) -> SIMD3<Float> {
        let sign: Float = foot == 0 ? 1 : -1
        let offset = SIMD3<Float>(point.x - hips.x, 0, point.z - hips.z)
        let lateral = simd_dot(offset, across) * sign
        // A narrow walk legitimately brings a foot close to the midline, so
        // the floor is just short of it rather than at the hip line.
        let floor = -footSpacing * 0.1
        guard lateral < floor else { return point }
        return point + across * sign * (floor - lateral)
    }

    /// A stepper proportioned for a character, from its leg length.
    ///
    /// Step length is taken from the source walk's own stride — a human walk
    /// swings its foot about a leg length front to back, so half of that is
    /// one step — scaled onto whatever legs this character has.
    public static func forLeg(length: Float, hipWidth: Float,
                              strideInLegLengths: Float = 1.0) -> LegStepper {
        LegStepper(stepLength: max(length * strideInLegLengths / 2, 0.05),
                   footSpacing: max(hipWidth, 0.05),
                   // A foot that barely leaves the floor reads as a shuffle
                   // however far it travels, so the lift is generous.
                   liftHeight: max(length * 0.16, 0.03))
    }
}
