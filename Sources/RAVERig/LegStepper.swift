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
    /// How many feet have been closed up since the walk stopped. The first
    /// close is held to a tight tolerance; a second one is only worth taking
    /// when a foot is genuinely out of place.
    private var closedThisStop = 0

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
        closedThisStop = 0
    }

    /// Starts a walk from wherever the feet are standing.
    ///
    /// `reset` forgets the plants, and the first step then puts both feet
    /// half a step AHEAD of the hips in one frame — which is the jump at the
    /// start of every walk. A character that is standing has its feet on the
    /// ground already, and those are the right places to start from: the
    /// cycle restarts at the point where both feet are down and the first
    /// swing is still a fraction of a step away, so the first thing that
    /// happens is a foot lifting, not a foot appearing somewhere else.
    ///
    /// A foot still closing up from the previous stop is left closing: the
    /// first frames of the walk finish putting it down, and the cycle starts
    /// once it has.
    public mutating func beginWalk() {
        distance = 0
        closedThisStop = 0
    }

    /// Where the closing foot is headed, kept for the diagnostics.
    private var closeTarget: SIMD3<Float>?

    /// Advances the cycle and returns where both feet belong.
    ///
    /// - Parameters:
    ///   - hips: the body's position on the floor, in world space.
    ///   - forward: unit vector the character walks along, on the floor plane.
    ///   - travelled: metres covered since the last call.
    ///   - remaining: metres still to go before the walk ends, when known. A
    ///     landing is never placed past the destination, so the last step
    ///     shortens to arrive on it instead of overshooting and having to be
    ///     pulled back — which is the backward shuffle a walk used to end in.
    ///   - floor: height of the ground under a given point, for stepping onto
    ///     and off surfaces. Return `hips.y` to keep the feet on one level.
    public mutating func step(hips: SIMD3<Float>, forward: SIMD3<Float>, travelled: Float,
                              remaining: Float? = nil,
                              floor: (SIMD3<Float>) -> Float)
        -> (left: Placement, right: Placement) {
        closedThisStop = 0
        // A foot caught mid-close by a new walk is put down first, at the
        // pace of the walk, and only then does the cycle start — from
        // distance zero, so nothing jumps.
        if closing != nil {
            let finishing = settle(hips: hips, forward: forward, closing: travelled, floor: floor)
            closedThisStop = 0
            if closing != nil { return (finishing.left, finishing.right) }
        }
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
            // of the hips, so the body passes over it through mid-stance — or
            // on the destination, when that is nearer.
            let ahead = min(stepLength / 2, max(remaining ?? .infinity, 0))
            var landing = hips + forward * ahead + side
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
        // Where the foot actually is. A foot that was in the air when the
        // walk stopped is at its swing position, not at the plant it took
        // off from — reading the plant put the airborne foot back on its
        // old footprint in one frame, which was the snap at the end of a
        // walk.
        func current(_ foot: Int) -> SIMD3<Float> {
            if wasPlanted[foot] { return plant[foot] ?? swinging[foot] ?? neutral(foot) }
            return swinging[foot] ?? plant[foot] ?? neutral(foot)
        }
        // Close enough to stand on. A tenth of a step for the first foot, so
        // the pose handed back is a standing one; a third of a step after
        // that, because a stance with the feet slightly staggered is how a
        // walker actually stops, and pulling the leading foot back to square
        // it up reads as a second, backward step.
        let tolerance = stepLength * (closedThisStop == 0 ? 0.1 : 0.3)

        if closing == nil {
            // A foot in the air is always dealt with first: it has nowhere to
            // stand until it is put down. Otherwise close whichever foot is
            // further from where it should be.
            if let air = (0...1).first(where: { !wasPlanted[$0] && swinging[$0] != nil }) {
                closing = air
            } else {
                let gaps = (0...1).map { simd_distance(current($0), neutral($0)) }
                if let worst = gaps.firstIndex(of: gaps.max()!), gaps[worst] > tolerance {
                    closing = worst
                }
            }
            if let foot = closing {
                closeProgress = 0
                closeFrom = current(foot)
                wasPlanted[foot] = false
            }
        }

        guard let foot = closing else {
            // Both are where they belong; hold them there.
            for index in 0...1 where plant[index] == nil { plant[index] = neutral(index) }
            closeTarget = nil
            return (Placement(position: current(0), planted: true),
                    Placement(position: current(1), planted: true),
                    true)
        }

        // The closing foot moves at swing speed, not hip speed: a swing
        // covers about a step and a half while the hips cover the swing's
        // share of a step, so the last step of a walk keeps the pace of the
        // ones before it instead of dragging.
        let footTravel = max(distance, 0) * (2 - stanceFraction) / max(1 - stanceFraction, 0.05)
        let toward = neutral(foot)
        closeTarget = toward
        let travel = max(simd_distance(closeFrom, toward), 0.01)
        closeProgress = min(1, closeProgress + footTravel / travel)
        var moving = simd_mix(closeFrom, toward, SIMD3<Float>(repeating: closeProgress))
        moving.y += sin(pow(closeProgress, 0.65) * .pi) * liftHeight * 0.6
        moving = heldOnOwnSide(moving, of: hips, across: across, foot: foot)

        let arrived = closeProgress >= 1
        if arrived {
            plant[foot] = toward
            swinging[foot] = nil
            wasPlanted[foot] = true
            closing = nil
            closeTarget = nil
            closedThisStop += 1
        } else {
            swinging[foot] = moving
        }

        let other = 1 - foot
        if plant[other] == nil { plant[other] = current(other) }
        let closingPlacement = Placement(position: arrived ? toward : moving,
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
