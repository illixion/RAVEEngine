import Foundation
import simd

// MARK: - The lower body

/// One foot, as a tracker strapped to it would report it.
public struct PerformerFoot: Sendable, Equatable {
    /// The ankle joint, in tracking space.
    public var ankle: SIMD3<Float>
    /// The foot's frame: +Z along the sole toward the toes, +Y up out of the
    /// instep, +X to the foot's left. A flat foot pointing the way the body
    /// faces has the body's frame.
    public var rotation: simd_quatf
    /// On the ground and holding still.
    public var planted: Bool
    /// How far the toes bend up from the rest of the foot, radians: a heel
    /// raised over toes still on the floor.
    public var toeBend: Float

    public init(ankle: SIMD3<Float>, rotation: simd_quatf, planted: Bool, toeBend: Float = 0) {
        self.ankle = ankle
        self.rotation = rotation
        self.planted = planted
        self.toeBend = toeBend
    }
}

/// The pelvis and both feet, in tracking space: the three poses hip and foot
/// trackers report.
///
/// `PerformerGait` makes one up from the head; a tracker that sees the legs (a
/// phone's camera, PC VR trackers) measures one. `PerformerRig` poses an
/// avatar's legs from either, and a PC VR host can hand the same three poses
/// to its runtime as trackers.
public struct PerformerLowerBody: Sendable, Equatable {
    /// Between the hip joints.
    public var pelvis: SIMD3<Float>
    /// The pelvis's frame: x to its left, y up, z forward.
    public var pelvisRotation: simd_quatf
    public var left: PerformerFoot
    public var right: PerformerFoot
    /// Height of the floor the feet stand on.
    public var floor: Float
    /// How much of an avatar's legs this decides: 0 leaves them to the base
    /// pose, 1 is all of this.
    public var weight: Float
    /// How far arms that nothing tracks swing with the walk, −1 to 1: positive
    /// brings the left arm forward.
    public var armSwing: Float

    public init(pelvis: SIMD3<Float>, pelvisRotation: simd_quatf, left: PerformerFoot, right: PerformerFoot,
                floor: Float, weight: Float = 1, armSwing: Float = 0) {
        self.pelvis = pelvis
        self.pelvisRotation = pelvisRotation
        self.left = left
        self.right = right
        self.floor = floor
        self.weight = weight
        self.armSwing = armSwing
    }
}

// MARK: - Walking from the head alone

/// A performer's legs, made up from the head alone, for someone who really
/// walks: across the room, round it, up to the desk and back.
///
/// A headset tracks the head and hands; everything below them is a guess, and
/// the guess that shows most is the feet. A body that glides about on still
/// legs reads as a ghost in the first person and as a broken avatar on camera.
/// `FootPlanter` answers this for LambdaVision, and has to answer it
/// reactively: a thumbstick sends a player anywhere at any speed, running
/// included, so a foot steps when it has been left behind. A performer only
/// ever walks, on their own legs, at walking pace, and that buys three things
/// a reactive stepper can't have:
///
/// - **Steps in time with theirs.** A walking head bobs, lowest just after
///   each heel strike, and sways toward the foot that just landed. The gait
///   hears that rhythm and runs its own step cycle in phase with it, so a
///   performer who looks down sees their feet land when they feel them land.
/// - **A real foot.** It strikes with the heel, rolls flat, lifts the heel
///   over the ball as the body passes over it and pushes off from the toes,
///   which bend. Walking backward the roll reverses. A foot with no heel (a
///   digitigrade avatar's, whose raised hock is its "ankle") lands on its toes.
/// - **A pelvis that walks.** It bobs and sways as the head does (measured,
///   not made up), turns and dips with the stride, and arms that nothing
///   tracks swing against it.
///
/// It also carries the body under the head: a lean or a glance stays one, and
/// only a head that has gone (walked off, turned round, sat down) takes the
/// body with it. `body` is that body, what every solve measures the head
/// against.
///
/// The output, `lowerBody`, is a pelvis and two feet in tracking space,
/// exactly what hip and foot trackers report, so a PC VR host can pass it on
/// as trackers and a tracker that sees the real legs replaces it outright.
///
/// Y is up and lengths are metres, in the tracking space the head comes from.
public struct PerformerGait: Sendable {

    /// A foot as the gait models it: a rigid sole that pivots about its heel
    /// or its ball, with the ankle above it.
    public struct FootShape: Sendable, Equatable {
        /// The ankle above the sole when the foot is flat.
        public var ankleHeight: Float
        /// Along the sole from below the ankle back to the heel, and forward
        /// to the ball of the foot.
        public var heel: Float
        public var ball: Float

        public init(ankleHeight: Float, heel: Float, ball: Float) {
            self.ankleHeight = max(ankleHeight, 0.005)
            self.heel = max(heel, 0)
            self.ball = max(ball, 0.005)
        }

        /// A human foot for someone `height` tall.
        public static func human(height: Float) -> FootShape {
            FootShape(ankleHeight: 0.045 * height, heel: 0.03 * height, ball: 0.08 * height)
        }

        /// A foot with no heel stands on its toes.
        public var hasHeel: Bool { heel > 0.001 }
    }

    /// Tuning, all of it worth changing live. Lengths are for a performer
    /// 1.70 m tall and scale with their height.
    public struct Tuning: Sendable, Equatable {
        /// How far the head may move from the body before it is a step rather
        /// than a lean: forward (over a desk), sideways, and back. People
        /// barely lean back at all; a head that goes back has stepped back,
        /// and a body left in front of it puts the eyes inside its neck.
        public var leanReach: Float = 0.3
        public var sidewaysLeanReach: Float = 0.2
        public var backwardLeanReach: Float = 0.12
        /// A head this far out and still going at least this fast (m/s) is
        /// walking off, not leaning, and starts the walk before `leanReach`;
        /// so is one going at least `bobbingStartSpeed` that bobs as it goes.
        public var walkStartDistance: Float = 0.15
        public var walkStartSpeed: Float = 0.45
        public var bobbingStartSpeed: Float = 0.2
        /// Slower than this, with the body back under the head, the walk is
        /// over.
        public var walkStopSpeed: Float = 0.12
        /// How far the head may turn from the body before the body turns too.
        public var twistReach: Float = 60 * .pi / 180
        /// How quickly the body takes the head's height, seconds: slow enough
        /// to leave a walk's bob to the pelvis.
        public var heightCatchUp: Float = 0.4
        /// How quickly the body catches the head up once it has gone, seconds.
        public var catchUp: Float = 0.12
        /// How quickly a body walking forward turns to face where it is going.
        public var walkTurning: Float = 0.25

        /// How far a standing foot may be from its place beside the body, and
        /// how far turned from the body's facing, before it steps.
        public var stepDrift: Float = 0.12
        public var stepTurn: Float = 35 * .pi / 180
        /// The same, once stepping: a walk that stops keeps stepping until
        /// both feet are this close, so it ends square.
        public var settleDrift: Float = 0.05
        public var settleTurn: Float = 12 * .pi / 180
        /// How far each foot turns out from the body's facing.
        public var toeOut: Float = 4 * .pi / 180
        /// Steps a second on the spot, how many more each m/s adds (and each
        /// m/s sideways on top: side-steps are short and quick), and the most
        /// there are.
        public var restCadence: Float = 1.5
        /// Steps a second once the body has stopped and the feet are still
        /// catching up: a room's few steps end with the walker, not after.
        public var settleCadence: Float = 2.0
        public var cadencePerSpeed: Float = 0.45
        public var cadencePerSidewaysSpeed: Float = 0.6
        public var maxCadence: Float = 2.2
        /// Seconds a foot spends in the air. A slow walk spends its extra time
        /// with both feet down, not swinging slower.
        public var swingTime: Float = 0.4
        /// The feet's width apart walking, as a share of standing's.
        public var walkingWidth: Float = 0.7

        /// The foot's angle off the floor at heel strike and at toe-off, for a
        /// full stride.
        public var heelStrike: Float = 18 * .pi / 180
        public var toeOff: Float = 45 * .pi / 180
        /// Seconds for a foot that struck with its heel to roll flat.
        public var loading: Float = 0.12
        /// How high the ankle lifts over a full stride, above where it starts
        /// and lands.
        public var lift: Float = 0.07

        /// How far the pelvis turns and dips with the stride at full speed.
        public var pelvisYaw: Float = 5 * .pi / 180
        public var pelvisList: Float = 4 * .pi / 180
        /// The arm swing's size, 0 to turn it off.
        public var armSwing: Float = 1

        /// The head's height has to turn by this much before a trough or a
        /// crest counts, and a step's bob be at least this deep, to be heard.
        public var bobHysteresis: Float = 0.002
        public var minimumBob: Float = 0.004
        /// Share of a heard step's timing error made up at once.
        public var phaseGain: Float = 0.6

        public init() {}
    }

    /// What the gait is doing, for a debug readout.
    public struct Report: Sendable, Equatable {
        public var walking = false
        public var turning = false
        public var rising = false
        public var seated = false
        public var stepping = false
        public var speed: Float = 0
        /// Steps a second, and the share of a stride a foot is down.
        public var cadence: Float = 0
        public var stance: Float = 0
        public var phase: Float = 0
        public var walkWeight: Float = 0
        /// Steps a second as the head's bob has it, while it can be heard.
        public var heardCadence: Float?
        /// The bob's trough-to-crest depth, metres.
        public var bob: Float = 0
        /// Steps heard, and the timing error of the last, in cycles: positive
        /// means the gait was behind.
        public var heard = 0
        public var lastError: Float = 0
        /// Which foot the head's sway said landed last: `left`, `right`, or
        /// `unsure`.
        public var sway = "unsure"
        /// Steps taken since the gait was recentred.
        public var steps = 0
    }

    public var tuning = Tuning()
    /// The feet the gait models. A human foot by default; an avatar's, scaled
    /// to the performer, for the gait to land that avatar's feet exactly.
    public var foot: FootShape
    /// Ankle to ankle, across the body, standing.
    public var stanceWidth: Float
    /// Height of the floor.
    public var floor: Float
    /// The body under the head: where the performer stands and which way they
    /// face, with the lean taken out.
    public private(set) var body: PerformerCalibration
    public private(set) var lowerBody: PerformerLowerBody
    public private(set) var report = Report()

    private var walking = false
    private var stoppedWalking = false
    private var turning = false
    private var rising = false
    private var seated = false
    private var time: Float = 0
    private var lastHead: SIMD3<Float>?
    /// How long the head has read implausibly far from where it just was.
    private var jumping: Float = 0
    private var headVelocity = SIMD3<Float>.zero
    private var bodyVelocity = SIMD3<Float>.zero
    /// The body's velocity over most of a step: where it is going, without
    /// most of the sway from foot to foot. And how fast that direction is
    /// turning, radians a second, to lead it by on a curve.
    private var travelVelocity = SIMD3<Float>.zero
    private var travelHeading: Float?
    private var travelTurnRate: Float = 0
    /// The head's neck pivot over the last second or so: what the bob and
    /// the sway are read from.
    private var atlases: [(time: Float, point: SIMD3<Float>)] = []
    private var atlas = SIMD3<Float>.zero

    /// The step cycle, in strides, never wrapped: each foot lands once per
    /// whole number of them.
    private var phase: Float = 0
    private var phases: [(time: Float, phase: Float)] = []
    private var stepping = false
    private var cadence: Float
    private var stance: Float = 0.65
    private var feet: [Foot]
    private var lastStepped = 1
    private var walkWeight: Float = 0
    private var legWeight: Float = 1
    private var correction: Float = 0
    private var bob = Bob()

    private struct Foot {
        /// Where the ankle is when the foot lies flat on its plant, and which
        /// way the foot points.
        var plant: SIMD3<Float>
        var heading: SIMD3<Float>
        /// The cycle phase it last landed at.
        var landedAt: Float = 0
        var sinceLanding: Float = 10
        var landingPitch: Float = 0
        /// +1 if its last step went the way it points, −1 if backward, 0 if
        /// mostly sideways: which way the foot rolls.
        var travel: Float = 1
        var swing: Swing?
        /// Last frame's pose.
        var pose = Pose()
    }

    private struct Swing {
        var from: Pose
        var fromPlant: SIMD3<Float>
        var liftedAt: Float
        var landsAt: Float
        var target: SIMD3<Float>
        var targetHeading: SIMD3<Float>
        var landingPitch: Float = 0
    }

    private struct Pose {
        var ankle = SIMD3<Float>.zero
        var heading = SIMD3<Float>(0, 0, -1)
        /// Positive raises the toes, negative the heel.
        var pitch: Float = 0
        var toeBend: Float = 0
    }

    public init(calibration: PerformerCalibration, floor: Float = 0, foot: FootShape? = nil,
                stanceWidth: Float? = nil) {
        self.body = calibration
        self.floor = floor
        self.foot = foot ?? .human(height: calibration.height)
        self.stanceWidth = stanceWidth ?? 0.09 * calibration.height
        cadence = Tuning().restCadence
        feet = [Foot(plant: .zero, heading: calibration.forward), Foot(plant: .zero, heading: calibration.forward)]
        lowerBody = PerformerLowerBody(pelvis: calibration.neutralHips,
                                       pelvisRotation: PerformerRig.frame(up: SIMD3<Float>(0, 1, 0),
                                                                          forward: calibration.forward),
                                       left: PerformerFoot(ankle: .zero, rotation: .init(), planted: true),
                                       right: PerformerFoot(ankle: .zero, rotation: .init(), planted: true),
                                       floor: floor)
        recenter(calibration)
    }

    /// Starts again with the performer standing as calibrated, feet beside
    /// each other under them.
    public mutating func recenter(_ calibration: PerformerCalibration) {
        body = calibration
        walking = false
        turning = false
        rising = false
        seated = calibration.head.y - floor < 0.8 * calibration.height
        lastHead = nil
        jumping = 0
        headVelocity = .zero
        bodyVelocity = .zero
        travelVelocity = .zero
        travelHeading = nil
        travelTurnRate = 0
        atlases.removeAll()
        phases.removeAll()
        stepping = false
        phase = 0
        correction = 0
        walkWeight = 0
        legWeight = seated ? 0 : 1
        bob = Bob()
        report = Report()
        standFeet()
        atlas = calibration.head + PerformerRig.neutralHead(performer: performerFrame)
            .act(PerformerCalibration.atlasOffset * calibration.proportion)
        lowerBody = output()
    }

    /// Seconds over which the travel's direction is smoothed.
    private static let travelSmoothing: Float = 0.3

    private var proportion: Float { body.proportion }
    private var legLength: Float { body.legLength }
    private var performerFrame: simd_quatf { PerformerRig.frame(up: SIMD3<Float>(0, 1, 0), forward: body.forward) }
    private var bodyLeft: SIMD3<Float> { simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), body.forward)) }
    /// The body's place on the floor: under the hips, a hand's breadth
    /// behind the eyes, which stand over the middle of the feet.
    private var ground: SIMD3<Float> {
        let hips = body.neutralHips
        return SIMD3<Float>(hips.x, floor, hips.z)
    }

    /// Both feet flat beside each other under the body.
    private mutating func standFeet() {
        for f in 0...1 {
            feet[f].plant = place(f, width: stanceWidth)
            feet[f].heading = facing(f)
            feet[f].swing = nil
            feet[f].sinceLanding = 10
            feet[f].landingPitch = 0
            feet[f].pose = Pose(ankle: feet[f].plant, heading: feet[f].heading)
        }
    }

    // MARK: - Every frame

    /// Moves the body, the feet and the pelvis on by one frame. A nil frame
    /// (the head lost) holds everything where it is.
    public mutating func update(_ frame: PerformerFrame?, deltaTime: Float) {
        let dt = min(max(deltaTime, 0), 0.1)
        time += dt
        guard let frame else { return }
        // A head further from where it just was than anyone moves in a frame
        // was not tracked there (once, the head read the floor for a frame
        // while the hands stayed put). Held a moment, it is real: the space
        // moved under it.
        if let last = lastHead, simd_distance(last, frame.head) > 0.5 {
            jumping += dt
            guard jumping > 0.3 else { return }
            recenter(PerformerCalibration(head: frame.head, forward: body.forward, height: body.height))
        }
        jumping = 0

        follow(frame, dt: dt)
        atlas = frame.head + frame.headRotation.act(PerformerCalibration.atlasOffset * proportion)
        atlases.append((time, atlas))
        if let stale = atlases.firstIndex(where: { $0.time > time - 1.2 }), stale > 0 {
            atlases.removeFirst(stale)
        }
        listen(dt: dt)
        step(dt: dt)
        phases.append((time, phase))
        if let stale = phases.firstIndex(where: { $0.time > time - 1.2 }), stale > 0 {
            phases.removeFirst(stale)
        }
        lowerBody = output()
        report.walking = walking
        report.turning = turning
        report.rising = rising
        report.seated = seated
        report.stepping = stepping
        report.speed = simd_length(bodyVelocity)
        report.cadence = cadence
        report.stance = stance
        report.phase = phase - phase.rounded(.down)
        report.walkWeight = walkWeight
        report.bob = bob.depth
    }

    // MARK: - The body under the head

    /// Carries the body along under a performer who walks off, turns round,
    /// or sits down. A lean or a glance stays one: the body only moves once
    /// the head has gone further than either reaches, and then follows it
    /// until it is back over the body.
    private mutating func follow(_ frame: PerformerFrame, dt: Float) {
        let k = proportion
        if let last = lastHead, dt > 0 {
            var v = (frame.head - last) / dt
            v.y = 0
            headVelocity += (v - headVelocity) * min(1, dt / 0.1)
        }
        lastHead = frame.head
        let before = body.head
        var offset = frame.head - body.head
        offset.y = 0
        let distance = simd_length(offset)
        let speed = simd_length(headVelocity)
        // A lean drops the head as it goes but never bobs it: a head that has
        // just come up out of a trough is stepping.
        let bobbing = time - bob.lastTrough < 0.6
        let ahead = distance > 1e-4 ? simd_dot(offset / distance, body.forward) : 1
        let reach = (ahead >= 0
            ? tuning.sidewaysLeanReach + (tuning.leanReach - tuning.sidewaysLeanReach) * ahead
            : tuning.sidewaysLeanReach + (tuning.backwardLeanReach - tuning.sidewaysLeanReach) * -ahead) * k
        if !walking, distance > reach
            || (distance > tuning.walkStartDistance * k && simd_dot(headVelocity, offset) > 0
                && (speed > tuning.walkStartSpeed || (bobbing && speed > tuning.bobbingStartSpeed))) {
            walking = true
        }
        if walking {
            // Carried at the head's own pace, the body keeps up with a walking
            // head instead of trailing it by a lean's worth. It never passes
            // it, though: a walk that stops would carry it past the head and
            // step it back.
            body.head += headVelocity * dt + offset * min(1, dt / tuning.catchUp)
            if speed > 1e-3 {
                let way = headVelocity / speed
                var past = body.head - frame.head
                past.y = 0
                let ahead = simd_dot(past, way)
                if ahead > 0 { body.head -= way * ahead }
            }
            var left = frame.head - body.head
            left.y = 0
            if simd_length(left) < 0.05 * k, speed < tuning.walkStopSpeed {
                walking = false
                // A walk ends squared up with where they look.
                stoppedWalking = true
            }
        }

        // The body stands as tall as the head says, once the drop a lean
        // makes is taken back out: standing up taller, crouching and sitting
        // down all carry it with them, while a lean over the desk leaves it
        // standing. Following only big changes left it low after a recentre
        // while stooping, and the eyes looked down into its neck.
        var lean = frame.head - body.head
        lean.y = 0
        let torso = max(simd_length(body.neutralNeck - body.neutralHips) + 0.18 * k, 0.1)
        let out = min(simd_length(lean) / torso, 1)
        let upright = frame.head.y + torso * (1 - (1 - out * out).squareRoot())
        let rise = upright - body.head.y
        rising = abs(rise) > 0.05 * k
        body.head.y += rise * min(1, dt / tuning.heightCatchUp)
        // Eyes stand at about 0.94 of a person's height and sit nearer 0.7.
        let eyes = body.head.y - floor
        if seated ? eyes > 0.85 * body.height : eyes < 0.8 * body.height {
            seated.toggle()
        }

        if dt > 0 {
            var v = (body.head - before) / dt
            v.y = 0
            bodyVelocity += (v - bodyVelocity) * min(1, dt / 0.15)
            travelVelocity += (v - travelVelocity) * min(1, dt / Self.travelSmoothing)
        }

        var look = frame.headRotation.act(SIMD3<Float>(0, 0, -1))
        look.y = 0
        guard simd_length(look) > 0.2 else { return }
        look = simd_normalize(look)
        func twist(to direction: SIMD3<Float>) -> Float {
            atan2(simd_cross(body.forward, direction).y, simd_dot(body.forward, direction))
        }
        let moving = simd_length(travelVelocity)
        if walking, moving > 0.25 {
            // Walking forward, people face where they go and look about as
            // they please; walking backward or sideways they keep facing the
            // way they look. Round a curve, where they go is ahead of where
            // they have been going: led by how fast it turns, the body keeps
            // up with the curve instead of trailing it.
            var travel = travelVelocity / moving
            let heading = atan2(travel.x, travel.z)
            if let previous = travelHeading, dt > 0 {
                var change = heading - previous
                if change > .pi { change -= 2 * .pi } else if change < -.pi { change += 2 * .pi }
                travelTurnRate += (change / dt - travelTurnRate) * min(1, dt / 0.4)
            }
            travelHeading = heading
            let lead = max(-1, min(1, travelTurnRate * (Self.travelSmoothing + tuning.walkTurning)))
            travel = simd_quatf(angle: lead, axis: SIMD3<Float>(0, 1, 0)).act(travel)
            let aim = simd_dot(travel, look) > cos(75 * Float.pi / 180) ? travel : look
            let turn = twist(to: aim)
            turnBody(by: turn * min(1, dt / tuning.walkTurning))
            turning = abs(turn) > 10 * .pi / 180
            return
        }
        travelHeading = nil
        travelTurnRate = 0
        let turn = twist(to: look)
        if abs(turn) > tuning.twistReach || (stoppedWalking && abs(turn) > 10 * .pi / 180) { turning = true }
        stoppedWalking = false
        if turning {
            turnBody(by: turn * min(1, dt / tuning.catchUp))
            if abs(turn) < 3 * .pi / 180 { turning = false }
        }
    }

    /// Turns the body about its own axis, through the hips. The eyes are a
    /// hand's breadth in front of it and swing round with it, as a real head
    /// turned on the spot does; turned about the eyes instead, the hips
    /// swung through an arc and dragged the feet with them.
    private mutating func turnBody(by angle: Float) {
        let pivot = body.neutralHips
        let turn = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        var out = body.head - pivot
        out.y = 0
        body.head += turn.act(out) - out
        body.forward = simd_normalize(turn.act(body.forward))
    }

    // MARK: - Hearing the steps

    /// Listens to the head's bob for steps, and pulls the cycle into time with
    /// each one heard.
    ///
    /// The neck's pivot is lowest just after each heel strike, with both feet
    /// down and the weight passing from one to the other, and moving sideways
    /// toward the foot that just landed. The pivot, not the eyes: nodding
    /// swings the eyes up and down by centimetres, the neck barely at all.
    private mutating func listen(dt: Float) {
        guard let trough = bob.feed(atlas.y, time: time, dt: dt, hysteresis: tuning.bobHysteresis,
                                    minimum: tuning.minimumBob * proportion) else { return }
        report.heardCadence = bob.period.map { 1 / $0 }
        // Heard whenever the feet are stepping: a few steps across a room are
        // over, as far as the body is concerned, before the last of them
        // lands.
        guard stepping, let at = phaseAt(trough) else { return }

        // Which foot: the way the neck was moving across the body, less the
        // way the body itself goes (the sway rides on the travel; measured
        // across the travel's moment-to-moment direction, it cancels itself).
        var landed: Int?
        if let before = atlasAt(trough - 0.05), let after = atlasAt(min(trough + 0.05, time)),
           time - trough > 0.02 {
            let seconds = max(min(trough + 0.05, time) - (trough - 0.05), 1e-3)
            let sway = simd_dot(after - before, bodyLeft) / seconds - simd_dot(travelVelocity, bodyLeft)
            if abs(sway) > 0.03 { landed = sway > 0 ? 0 : 1 }
        }
        report.sway = landed.map { $0 == 0 ? "left" : "right" } ?? "unsure"

        // Its trough comes half the double support after it lands.
        let settle = (stance - 0.5) / 2
        func error(_ f: Int) -> Float {
            let mark = feet[f].landedAt + settle
            return mark + (at - mark).rounded() - at
        }
        let f = landed ?? (abs(error(0)) <= abs(error(1)) ? 0 : 1)
        let e = error(f)
        report.heard += 1
        report.lastError = e
        correction = min(max(correction + tuning.phaseGain * e, -0.35), 0.35)
    }

    /// The cycle phase at an earlier time this second.
    private func phaseAt(_ t: Float) -> Float? {
        guard let i = phases.lastIndex(where: { $0.time <= t }) else { return nil }
        guard i + 1 < phases.count else { return phases[i].phase }
        let a = phases[i], b = phases[i + 1]
        let u = b.time > a.time ? (t - a.time) / (b.time - a.time) : 0
        return a.phase + (b.phase - a.phase) * u
    }

    private func atlasAt(_ t: Float) -> SIMD3<Float>? {
        guard let i = atlases.lastIndex(where: { $0.time <= t }) else { return nil }
        guard i + 1 < atlases.count else { return atlases[i].point }
        let a = atlases[i], b = atlases[i + 1]
        let u = b.time > a.time ? (t - a.time) / (b.time - a.time) : 0
        return a.point + (b.point - a.point) * u
    }

    // MARK: - Stepping

    private mutating func step(dt: Float) {
        legWeight += ((seated ? 0 : 1) - legWeight) * min(1, dt / 0.25)
        if seated {
            // Sitting, the legs are the seat's. They stand afresh, under the
            // body, when the performer gets up.
            stepping = false
            walkWeight = 0
            standFeet()
            return
        }
        let speed = simd_length(bodyVelocity)
        let k = proportion
        walkWeight += ((stepping && (walking || speed > 0.1) ? 1 : 0) - walkWeight) * min(1, dt / 0.25)

        // How fast to step: what the head's bob says while it says anything,
        // what the speed says otherwise.
        let sideways = abs(simd_dot(bodyVelocity, bodyLeft))
        let modelled = min(tuning.maxCadence, tuning.restCadence
                           + (tuning.cadencePerSpeed * speed + tuning.cadencePerSidewaysSpeed * sideways) / k.squareRoot())
        var wanted = walking ? modelled : max(modelled, tuning.settleCadence)
        if let period = bob.period, time - bob.lastStep < 1.2 {
            wanted = min(max(1 / period, 1.2), 2.4)
        }
        cadence += (wanted - cadence) * min(1, dt / 0.3)
        let rate = cadence / 2
        stance = min(max(1 - tuning.swingTime * rate, 0.55), 0.8)

        if !stepping {
            let walkingOff = walking && speed > 0.05
            let needs = [need(0, settling: false), need(1, settling: false)]
            if walkingOff || needs.max()! > 1 {
                begin(with: firstFoot(walkingOff: walkingOff, needs: needs))
            }
        }

        if stepping {
            var advance = rate * dt
            if correction != 0 {
                // Made up gradually, and never by running the clock backward.
                let made = min(max(correction, -0.6 * advance), advance)
                advance += made
                correction -= made
            }
            phase += advance
            // Landings first: a foot that touches down this frame is down
            // before the other may lift.
            for f in 0...1 {
                if let swing = feet[f].swing, phase >= swing.landsAt { land(f) }
            }
            for f in [1 - lastStepped, lastStepped] {
                guard feet[f].swing == nil, phase >= feet[f].landedAt + stance else { continue }
                if walking || need(f, settling: true) > 1 {
                    lift(f)
                } else if feet[1 - f].swing == nil {
                    // Nothing left to do: both feet are down and in place.
                    stepping = false
                    correction = 0
                    break
                } else {
                    // The other foot is still in the air; this one waits.
                    feet[f].landedAt = phase - stance
                }
            }
        } else {
            correction = 0
        }

        for f in 0...1 {
            if feet[f].swing != nil {
                feet[f].pose = swingPose(f, rate: rate)
            } else {
                feet[f].sinceLanding += dt
                feet[f].pose = standingPose(f)
            }
        }
        if phase > 10_000 {
            // Keep the clock small enough to stay precise.
            let whole = (phase - 10).rounded(.down)
            phase -= whole
            for f in 0...1 {
                feet[f].landedAt -= whole
                feet[f].swing?.liftedAt -= whole
                feet[f].swing?.landsAt -= whole
            }
            for i in phases.indices { phases[i].phase -= whole }
        }
    }

    /// Where foot `f` stands beside the body, `width` apart from the other.
    private func place(_ f: Int, width: Float) -> SIMD3<Float> {
        var p = ground + bodyLeft * (width / 2) * (f == 0 ? 1 : -1)
        p.y = floor + foot.ankleHeight
        return p
    }

    /// The way foot `f` points: the body's facing, turned out a little.
    private func facing(_ f: Int) -> SIMD3<Float> {
        simd_quatf(angle: tuning.toeOut * (f == 0 ? 1 : -1), axis: SIMD3<Float>(0, 1, 0)).act(body.forward)
    }

    /// How badly a planted foot wants to step, as a multiple of its limits:
    /// past 1 it should.
    private func need(_ f: Int, settling: Bool) -> Float {
        let k = proportion
        let spot = place(f, width: stanceWidth)
        let drift = horizontal(feet[f].plant - spot) / ((settling ? tuning.settleDrift : tuning.stepDrift) * k)
        let turn = angle(feet[f].heading, facing(f)) / (settling ? tuning.settleTurn : tuning.stepTurn)
        // A foot the body has moved across must step out of its way.
        let lateral = simd_dot(feet[f].plant - ground, bodyLeft) * (f == 0 ? 1 : -1)
        let crossing: Float = lateral < 0 ? 2 : 0
        return max(drift, turn, crossing)
    }

    /// The foot that steps first. Going sideways, the one on that side.
    /// Walking off forward or back, the head's sway says where the weight
    /// went, and the other foot is the free one; failing that, the foot with
    /// further to go.
    private func firstFoot(walkingOff: Bool, needs: [Float]) -> Int {
        guard walkingOff else { return needs[0] >= needs[1] ? 0 : 1 }
        let sideways = simd_dot(bodyVelocity, bodyLeft)
        if abs(sideways) > 0.5 * simd_length(bodyVelocity) { return sideways > 0 ? 0 : 1 }
        if let before = atlasAt(time - 0.1) {
            let sway = simd_dot(atlas - before, bodyLeft) / 0.1 - sideways
            if abs(sway) > 0.04 { return sway > 0 ? 1 : 0 }
        }
        let lead = bodyVelocity * 0.4
        let distances = (0...1).map { horizontal(feet[$0].plant - (place($0, width: stanceWidth) + lead)) }
        if abs(distances[0] - distances[1]) > 0.02 { return distances[0] > distances[1] ? 0 : 1 }
        return 1 - lastStepped
    }

    /// Starts the cycle from standing with foot `f` lifting now.
    private mutating func begin(with f: Int) {
        stepping = true
        feet[f].landedAt = phase - stance
        feet[1 - f].landedAt = phase - stance + 0.5
        lift(f)
    }

    private mutating func lift(_ f: Int) {
        var landsAt = feet[f].landedAt + 1
        // A foot held back while the other finished its step still gets a
        // whole swing.
        if landsAt - phase < 0.6 * (1 - stance) { landsAt = phase + (1 - stance) }
        feet[f].swing = Swing(from: feet[f].pose, fromPlant: feet[f].plant, liftedAt: phase, landsAt: landsAt,
                              target: feet[f].plant, targetHeading: feet[f].heading)
    }

    private mutating func land(_ f: Int) {
        guard let swing = feet[f].swing else { return }
        feet[f].plant = swing.target
        feet[f].heading = swing.targetHeading
        feet[f].landedAt = swing.landsAt
        feet[f].sinceLanding = 0
        feet[f].landingPitch = swing.landingPitch
        let moved = swing.target - swing.fromPlant
        let along = simd_dot(moved, swing.targetHeading)
        let distance = horizontal(moved)
        feet[f].travel = distance > 0.02 && abs(along) > 0.5 * distance ? (along > 0 ? 1 : -1) : 0
        feet[f].swing = nil
        lastStepped = f
        report.steps += 1
    }

    // MARK: - Foot poses

    /// Where a swinging foot is this frame, and where it will land, kept up
    /// to date as the body goes: each frame it aims for its place beside the
    /// body as the body will be halfway through the foot's next stance.
    private mutating func swingPose(_ f: Int, rate: Float) -> Pose {
        guard var swing = feet[f].swing else { return feet[f].pose }
        let left = bodyLeft
        let sign: Float = f == 0 ? 1 : -1
        let seconds = max(swing.landsAt - phase, 0) / max(rate, 0.05)
        let stanceSeconds = stance / max(rate, 0.05)
        // Forward or back, a foot lands where the body will be halfway
        // through its stance, so the body passes over the middle of it.
        // Sideways that crosses the legs: the body covers half a stride while
        // the other foot is down, more than the feet are apart. A side-step
        // is a step out and a close instead: the foot on the side of travel
        // leads by its whole stance, the body reaching it as it lifts, and the
        // other comes in beside the body, never past it.
        let sideways = simd_dot(bodyVelocity, left)
        var lead = (bodyVelocity - left * sideways) * (seconds + stanceSeconds / 2)
        if sideways * sign > 0 { lead += left * sideways * (seconds + stanceSeconds) }
        let longest = 0.45 * legLength
        if simd_length(lead) > longest { lead *= longest / simd_length(lead) }
        let width = stanceWidth * (1 - (1 - tuning.walkingWidth) * walkWeight)
        var target = place(f, width: width) + lead
        target.y = floor + foot.ankleHeight
        // Never further from the hip than the leg reaches.
        let hip = ground + bodyVelocity * seconds + left * (stanceWidth / 2) * sign
        let room = (legLength * legLength - pow(legLength - foot.ankleHeight, 2) * 0.9).squareRoot()
        var reach = SIMD3<Float>(target.x - hip.x, 0, target.z - hip.z)
        if simd_length(reach) > room {
            reach *= room / simd_length(reach)
            target = SIMD3<Float>(hip.x + reach.x, target.y, hip.z + reach.z)
        }
        target = heldOnOwnSide(target, f)
        swing.target = target
        swing.targetHeading = facing(f)

        // Struck with the heel going forward, with the toes going backward,
        // in proportion to the stride.
        let moved = target - swing.fromPlant
        let along = simd_dot(moved, swing.targetHeading)
        let stride = min(abs(along) / (0.5 * legLength), 1)
        if horizontal(moved) > 0.02, abs(along) > 0.5 * horizontal(moved) {
            swing.landingPitch = along > 0
                ? (foot.hasHeel ? tuning.heelStrike * stride : 0)
                : -0.6 * tuning.heelStrike * stride
        } else {
            swing.landingPitch = 0
        }
        feet[f].swing = swing

        let u = min(max((phase - swing.liftedAt) / max(swing.landsAt - swing.liftedAt, 1e-3), 0), 1)
        let eased = u * u * u * (10 + u * (6 * u - 15))
        let end = ankle(plant: target, heading: swing.targetHeading, pitch: swing.landingPitch)
        var point = swing.from.ankle + (end - swing.from.ankle) * eased
        // The lift peaks early and comes down long, so the foot descends into
        // its landing rather than dropping off the top of a hop.
        let travel = horizontal(end - swing.from.ankle)
        let rise = tuning.lift * proportion * min(max(travel / (0.5 * legLength), 0.35), 1.2)
        point.y += sin(pow(u, 0.65) * .pi) * rise
        point = heldOnOwnSide(point, f)
        let pitch = swing.from.pitch + (swing.landingPitch - swing.from.pitch) * smoothstep(0.15, 0.95, u)
        let turn = atan2(simd_cross(swing.from.heading, swing.targetHeading).y,
                         simd_dot(swing.from.heading, swing.targetHeading))
        let pointing = simd_quatf(angle: turn * eased, axis: SIMD3<Float>(0, 1, 0)).act(swing.from.heading)
        let toes = swing.from.toeBend * (1 - smoothstep(0, 0.35, u))
        return Pose(ankle: point, heading: pointing, pitch: pitch, toeBend: toes)
    }

    /// A foot on the ground: flat, or rolling. It lands rolled back on its
    /// heel and comes down flat; as the body passes over it the heel lifts
    /// over the ball, toes flat on the floor, until it leaves.
    private func standingPose(_ f: Int) -> Pose {
        let state = feet[f]
        var pitch = state.landingPitch * (1 - smoothstep(0, tuning.loading, state.sinceLanding))
        let along = simd_dot(ground - state.plant, state.heading)
        let start = 0.1 * legLength, full = 0.42 * legLength
        if state.travel > 0, along > start {
            pitch -= tuning.toeOff * smoothstep(start, full, along) * walkWeight
        } else if state.travel < 0, along < -start, foot.hasHeel {
            pitch += 0.6 * tuning.toeOff * smoothstep(start, full, -along) * walkWeight
        }
        return Pose(ankle: ankle(plant: state.plant, heading: state.heading, pitch: pitch),
                    heading: state.heading, pitch: pitch, toeBend: max(-pitch, 0))
    }

    /// The ankle of a foot planted flat at `plant`, rolled by `pitch` about
    /// its heel (toes up) or its ball (heel up), which stays on the floor.
    private func ankle(plant: SIMD3<Float>, heading: SIMD3<Float>, pitch: Float) -> SIMD3<Float> {
        guard abs(pitch) > 1e-5 else { return plant }
        let roll = rotation(heading: heading, pitch: pitch)
        if pitch > 0, foot.hasHeel {
            let heel = plant - heading * foot.heel - SIMD3<Float>(0, foot.ankleHeight, 0)
            return heel + roll.act(SIMD3<Float>(0, foot.ankleHeight, foot.heel))
        }
        let ball = plant + heading * foot.ball - SIMD3<Float>(0, foot.ankleHeight, 0)
        return ball + roll.act(SIMD3<Float>(0, foot.ankleHeight, -foot.ball))
    }

    /// A foot pointing along `heading`, its toes raised by `pitch`.
    private func rotation(heading: SIMD3<Float>, pitch: Float) -> simd_quatf {
        let flat = PerformerRig.frame(up: SIMD3<Float>(0, 1, 0), forward: heading)
        let left = flat.act(SIMD3<Float>(1, 0, 0))
        return simd_normalize(simd_quatf(angle: -pitch, axis: left) * flat)
    }

    /// The same point, pushed back to its own side of the body if it has
    /// strayed across: a swing's straight line can pass through the other
    /// leg on a turn.
    private func heldOnOwnSide(_ point: SIMD3<Float>, _ f: Int) -> SIMD3<Float> {
        let sign: Float = f == 0 ? 1 : -1
        let lateral = simd_dot(point - ground, bodyLeft) * sign
        let limit = stanceWidth * 0.1
        guard lateral < limit else { return point }
        return point + bodyLeft * sign * (limit - lateral)
    }

    // MARK: - Output

    private func output() -> PerformerLowerBody {
        let frame = performerFrame
        let neutralHips = body.neutralHips
        let neutralAtlas = body.head + PerformerRig.neutralHead(performer: frame)
            .act(PerformerCalibration.atlasOffset * proportion)

        // The pelvis goes where the head goes and a lean can't account for
        // it: down with the bob and a crouch, across with the sway while
        // walking. Leaning over drops the head as well, by as much as the
        // lean explains, and that much stays with the spine.
        let moved = atlas - neutralAtlas
        let torso = max(simd_length(neutralAtlas - neutralHips), 0.1)
        let out = min(horizontal(moved) / torso, 1)
        let explained = torso * (1 - (1 - out * out).squareRoot())
        let drop = min(max(moved.y + explained, -0.6 * legLength), 0.03)
        let sway = simd_dot(moved, bodyLeft) * walkWeight
        let pelvis = neutralHips + SIMD3<Float>(0, drop, 0) + bodyLeft * sway

        // It turns with the stride, the leading leg's hip forward, and dips
        // on the side of the swinging leg.
        let strength = walkWeight * min(simd_length(bodyVelocity) / proportion.squareRoot(), 1)
        let cycle = 2 * Float.pi * (phase - feet[0].landedAt)
        let yaw = simd_quatf(angle: -tuning.pelvisYaw * strength * cos(cycle), axis: SIMD3<Float>(0, 1, 0))
        let list = simd_quatf(angle: tuning.pelvisList * strength * sin(cycle), axis: SIMD3<Float>(0, 0, 1))
        let pelvisRotation = simd_normalize(frame * yaw * list)

        func tracker(_ f: Int) -> PerformerFoot {
            let pose = feet[f].pose
            return PerformerFoot(ankle: pose.ankle, rotation: rotation(heading: pose.heading, pitch: pose.pitch),
                                 planted: feet[f].swing == nil, toeBend: pose.toeBend)
        }
        return PerformerLowerBody(pelvis: pelvis, pelvisRotation: pelvisRotation, left: tracker(0), right: tracker(1),
                                  floor: floor, weight: legWeight,
                                  armSwing: -cos(cycle) * strength * tuning.armSwing)
    }

    // MARK: - Helpers

    private func horizontal(_ v: SIMD3<Float>) -> Float { simd_length(SIMD2<Float>(v.x, v.z)) }

    private func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(max(simd_dot(simd_normalize(SIMD3<Float>(a.x, 0, a.z)), simd_normalize(SIMD3<Float>(b.x, 0, b.z))), -1), 1))
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / max(b - a, 1e-6), 0), 1)
    return t * t * (3 - 2 * t)
}

/// The head's vertical bob, heard as steps: each trough a heel strike.
private struct Bob {
    private var baseline: Float?
    private var falling = true
    private var extreme: (time: Float, value: Float) = (0, 0)
    /// The highest the head has been since the last trough.
    private var crest: Float = 0
    private var previousTrough: Float?
    /// When the last trough deep enough to be a step was, even one too far
    /// from the one before to time a step by.
    private(set) var lastTrough: Float = -10
    /// Seconds between steps, eased.
    private(set) var period: Float?
    /// Trough to crest, metres, eased.
    private(set) var depth: Float = 0
    /// When the last step was heard.
    private(set) var lastStep: Float = -10

    /// Takes one height; returns the time of a step's trough once the head
    /// has turned back up out of it.
    mutating func feed(_ y: Float, time: Float, dt: Float, hysteresis: Float, minimum: Float) -> Float? {
        guard let base = baseline else {
            baseline = y
            extreme = (time, 0)
            crest = 0
            return nil
        }
        // The bob against the head's slower drift: standing taller, crouching.
        let drift = base + (y - base) * min(1, dt / 0.6)
        baseline = drift
        let b = y - drift
        crest = max(crest, b)
        if !falling {
            if b > extreme.value {
                extreme = (time, b)
            } else if b < extreme.value - hysteresis {
                falling = true
                extreme = (time, b)
            }
            return nil
        }
        if b < extreme.value {
            extreme = (time, b)
            return nil
        }
        guard b > extreme.value + hysteresis else { return nil }
        let trough = extreme
        let deep = crest - trough.value
        falling = false
        extreme = (time, b)
        crest = b
        guard deep >= minimum else { return nil }
        let previous = previousTrough
        previousTrough = trough.time
        lastTrough = trough.time
        guard let previous else { return nil }
        let interval = trough.time - previous
        // Slower than this is not walking; faster is not a step.
        guard interval > 0.28, interval < 0.95 else { return nil }
        period = period.map { $0 + (interval - $0) * 0.4 } ?? interval
        depth += (deep - depth) * 0.4
        lastStep = time
        return trough.time
    }
}
