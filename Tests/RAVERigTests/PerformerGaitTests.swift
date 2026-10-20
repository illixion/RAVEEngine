import Testing
import simd
@testable import RAVERig

/// The gait against a synthetic walker: a head carried along a path, bobbing
/// lowest just after each heel strike and swaying toward the foot that just
/// landed, as a real one does. The walker knows when its feet land, so the
/// gait's steps can be checked against them.
@Suite("PerformerGait")
struct PerformerGaitTests {

    static let up = SIMD3<Float>(0, 1, 0)

    static func looking(_ forward: SIMD3<Float>) -> simd_quatf {
        PerformerRig.neutralHead(performer: PerformerRig.frame(up: up, forward: forward))
    }

    struct Walker {
        var eye: Float = 1.6
        var start = SIMD3<Float>(0, 0, 0)
        var facing = SIMD3<Float>(0, 0, -1)
        var travel = SIMD3<Float>(0, 0, -1)
        var speed: Float = 1.0
        /// Steps a second.
        var cadence: Float = 1.9
        var walkFrom: Float = 1
        var walkTo: Float = 6
        /// Half the bob's depth, and the sway's reach to either side.
        var bob: Float = 0.015
        var sway: Float = 0.02
        /// The bob's trough comes in the middle of the double support after
        /// each strike: both feet down, the weight passing from one to the
        /// other. A slower walk spends longer there; the swing takes about
        /// as long at any pace.
        var troughLag: Float {
            let stance = min(max(1 - 0.4 * cadence / 2, 0.55), 0.8)
            return (stance - 0.5) / 2 / (cadence / 2)
        }
        /// The foot that lands first.
        var firstFoot = 0
        /// Up to this much tracking noise on the head, either way.
        var noise: Float = 0
        let ramp: Float = 0.3

        var left: SIMD3<Float> { simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), travel)) }

        /// Distance along the path, ramping up and down over `ramp`.
        func distance(_ t: Float) -> Float {
            func integral(_ t: Float) -> Float {
                // Speed ramps linearly from 0 at walkFrom to full at walkFrom + ramp,
                // and back to 0 over the last ramp.
                let a = walkFrom, b = walkFrom + ramp, c = walkTo - ramp, d = walkTo
                if t <= a { return 0 }
                if t <= b { return speed * (t - a) * (t - a) / (2 * ramp) }
                let first = speed * ramp / 2
                if t <= c { return first + speed * (t - b) }
                let middle = first + speed * (c - b)
                if t <= d { let u = t - c; return middle + speed * (u - u * u / (2 * ramp)) }
                return middle + speed * ramp / 2
            }
            return integral(t)
        }

        /// The first strike, half a step into the walk.
        var firstStrike: Float { walkFrom + 0.5 / cadence }

        func strikes() -> [(time: Float, foot: Int)] {
            var out: [(Float, Int)] = []
            var t = firstStrike
            var foot = firstFoot
            while t < walkTo {
                out.append((t, foot))
                t += 1 / cadence
                foot = 1 - foot
            }
            return out
        }

        func head(_ t: Float) -> SIMD3<Float> {
            var p = start + travel * distance(t) + SIMD3<Float>(0, eye, 0)
            guard t > walkFrom, t < walkTo else { return p }
            let envelope = min(1, (t - walkFrom) / ramp, (walkTo - t) / ramp)
            p.y -= bob * cos(2 * .pi * cadence * (t - firstStrike - troughLag)) * envelope
            // Toward the foot landing: left at a left strike.
            let toward: Float = firstFoot == 0 ? 1 : -1
            p += left * (toward * sway * sin(.pi * cadence * (t - firstStrike)) * envelope)
            if noise > 0 {
                // Deterministic, and uncorrelated from frame to frame.
                func hash(_ x: Float) -> Float {
                    let s = sin(x * 12.9898 + 78.233) * 43758.5453
                    return (s - s.rounded(.down)) * 2 - 1
                }
                p += SIMD3<Float>(hash(t), hash(t + 1.7), hash(t + 3.1)) * noise
            }
            return p
        }
    }

    struct Trace {
        var landings: [(time: Float, foot: Int, pitch: Float)] = []
        /// The furthest a planted foot's contact with the floor moved in a
        /// frame.
        var slide: Float = 0
        /// The least the left ankle was to the left of the right one.
        var narrowest: Float = .infinity
        var steps = 0
    }

    /// Runs the gait at 90 Hz from `from` to `to`, recording landings, slides
    /// and how close the legs came to crossing, across the way the body faces.
    static func run(_ gait: inout PerformerGait, from: Float, to: Float,
                    head: (Float) -> (position: SIMD3<Float>, rotation: simd_quatf)) -> Trace {
        var trace = Trace()
        let dt: Float = 1 / 90
        var previous: PerformerLowerBody?
        let shape = gait.foot
        func contacts(_ foot: PerformerFoot) -> [SIMD3<Float>] {
            [foot.ankle + foot.rotation.act(SIMD3<Float>(0, -shape.ankleHeight, -shape.heel)),
             foot.ankle + foot.rotation.act(SIMD3<Float>(0, -shape.ankleHeight, shape.ball))]
        }
        var t = from
        while t < to {
            let h = head(t)
            gait.update(PerformerFrame(head: h.position, headRotation: h.rotation), deltaTime: dt)
            let body = gait.lowerBody
            for (index, (now, before)) in [(body.left, previous?.left), (body.right, previous?.right)].enumerated() {
                guard let before else { continue }
                if now.planted, !before.planted {
                    let pitch = asin(min(max(now.rotation.act(SIMD3<Float>(0, 0, 1)).y, -1), 1))
                    trace.landings.append((t, index, pitch))
                }
                guard now.planted, before.planted else { continue }
                for (a, b) in zip(contacts(now), contacts(before))
                    where a.y < gait.floor + 0.002 && b.y < gait.floor + 0.002 {
                    trace.slide = max(trace.slide, simd_length(SIMD2<Float>(a.x - b.x, a.z - b.z)))
                }
            }
            let left = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), gait.body.forward))
            trace.narrowest = min(trace.narrowest, simd_dot(body.left.ankle - body.right.ankle, left))
            previous = body
            t += dt
        }
        trace.steps = gait.report.steps
        return trace
    }

    static let calibration = PerformerCalibration(head: SIMD3(0, 1.6, 0), forward: SIMD3(0, 0, -1), height: 1.7)

    struct Pace: Sendable, CustomTestStringConvertible {
        var speed: Float
        var cadence: Float
        var bob: Float
        var firstFoot: Int
        var noise: Float = 0
        var testDescription: String {
            "\(speed) m/s, \(cadence) steps/s, bob \(bob * 200) cm, \(firstFoot == 0 ? "left" : "right") first"
        }
    }

    @Test(arguments: [
        Pace(speed: 1.0, cadence: 1.9, bob: 0.015, firstFoot: 0),
        Pace(speed: 1.0, cadence: 1.9, bob: 0.015, firstFoot: 1),
        Pace(speed: 0.5, cadence: 1.6, bob: 0.008, firstFoot: 1, noise: 0.0005),
        Pace(speed: 1.3, cadence: 2.05, bob: 0.02, firstFoot: 0, noise: 0.0005),
    ])
    func stepsInTimeWithTheHead(_ pace: Pace) {
        var walker = Walker()
        walker.speed = pace.speed
        walker.cadence = pace.cadence
        walker.bob = pace.bob
        walker.sway = pace.bob * 1.3
        walker.firstFoot = pace.firstFoot
        walker.noise = pace.noise
        var gait = PerformerGait(calibration: Self.calibration)
        let trace = Self.run(&gait, from: 0, to: 8,
                             head: { (walker.head($0), Self.looking(walker.facing)) })
        let truth = walker.strikes()
        // Once it has heard a couple of steps, every landing is a real one,
        // on the right foot, within a few frames.
        let settled = trace.landings.filter { $0.time > walker.walkFrom + 2 && $0.time < walker.walkTo - 0.3 }
        #expect(settled.count >= 4)
        for landing in settled {
            let nearest = truth.min { abs($0.time - landing.time) < abs($1.time - landing.time) }!
            #expect(abs(nearest.time - landing.time) < 0.07, "landed at \(landing.time), heard \(nearest.time)")
            #expect(nearest.foot == landing.foot, "the \(landing.foot) foot landed when the \(nearest.foot) did")
        }
        #expect(gait.report.heard >= 4)
        #expect(trace.slide < 0.002, "a planted foot slid \(trace.slide) m")
        #expect(trace.narrowest > 0.03, "the feet came within \(trace.narrowest) m of crossing")
        // Heel first, walking forward.
        #expect(settled.allSatisfy { $0.pitch > 0.1 })

        // Stopped, it ends square: both feet down and flat, side by side.
        let body = gait.lowerBody
        #expect(!gait.report.stepping)
        #expect(body.left.planted && body.right.planted)
        #expect(abs(simd_dot(body.left.ankle - body.right.ankle, walker.travel)) < 0.06)
        #expect(body.left.rotation.act(Self.up).y > 0.999 && body.right.rotation.act(Self.up).y > 0.999)
        // Under the head, not left behind.
        let end = walker.head(8)
        #expect(simd_distance(SIMD2(gait.body.head.x, gait.body.head.z), SIMD2(end.x, end.z)) < 0.06)
    }

    @Test func walkingWithoutABobStillSteps() {
        var walker = Walker()
        walker.bob = 0
        walker.sway = 0
        var gait = PerformerGait(calibration: Self.calibration)
        let trace = Self.run(&gait, from: 0, to: 8,
                             head: { (walker.head($0), Self.looking(walker.facing)) })
        // Stepping at its own pace: a step every 0.4 to 0.7 s.
        let walking = trace.landings.filter { $0.time > walker.walkFrom + 1 && $0.time < walker.walkTo - 0.5 }
        #expect(walking.count >= 5)
        for (a, b) in zip(walking, walking.dropFirst()) {
            #expect(b.foot != a.foot)
            #expect(b.time - a.time > 0.35 && b.time - a.time < 0.75)
        }
        #expect(trace.slide < 0.002)
        #expect(trace.narrowest > 0.03)
        #expect(!gait.report.stepping)
    }

    @Test func walkingRoundACurveFacesTheWay() {
        // A quarter circle of 1.5 m at 0.8 m/s, looking where they go.
        let radius: Float = 1.5, speed: Float = 0.8
        var walker = Walker()
        walker.speed = speed
        walker.walkTo = 1 + (radius * .pi / 2) / speed + 0.15
        func along(_ t: Float) -> (position: SIMD3<Float>, facing: SIMD3<Float>) {
            let angle = walker.distance(t) / radius
            let centre = SIMD3<Float>(-radius, 0, 0)
            let out = SIMD3<Float>(cos(angle), 0, -sin(angle))
            return (centre + out * radius, SIMD3(-sin(angle), 0, -cos(angle)))
        }
        var gait = PerformerGait(calibration: Self.calibration)
        let trace = Self.run(&gait, from: 0, to: walker.walkTo + 2) { t in
            let p = along(t)
            return (p.position + SIMD3<Float>(0, 1.6, 0), Self.looking(p.facing))
        }
        #expect(trace.steps >= 4)
        #expect(trace.slide < 0.002)
        #expect(trace.narrowest > 0.03, "the feet came within \(trace.narrowest) m of crossing")
        // Facing the way the curve ended, both feet too.
        let end = along(walker.walkTo).facing
        #expect(simd_dot(gait.body.forward, end) > cos(10 * Float.pi / 180))
        for foot in [gait.lowerBody.left, gait.lowerBody.right] {
            #expect(simd_dot(foot.rotation.act(SIMD3<Float>(0, 0, 1)), end) > cos(15 * Float.pi / 180))
        }
        #expect(!gait.report.stepping)
    }

    @Test func aLeanIsNotAStep() {
        var gait = PerformerGait(calibration: Self.calibration)
        let trace = Self.run(&gait, from: 0, to: 4, head: { t in
            // Out 20 cm over 0.6 s, held, and back.
            let out: Float = t < 1 ? 0 : t < 1.6 ? (t - 1) / 0.6 : t < 2.6 ? 1 : t < 3.2 ? 1 - (t - 2.6) / 0.6 : 0
            return (SIMD3<Float>(0, 1.6, -0.2 * out), Self.looking(SIMD3(0, 0, -1)))
        })
        #expect(trace.steps == 0)
        #expect(!gait.report.walking)
    }

    @Test func turningOnTheSpotSteps() {
        var gait = PerformerGait(calibration: Self.calibration)
        func facing(_ t: Float) -> SIMD3<Float> {
            let turned = min(max(t - 1, 0), 1) * Float.pi / 2
            return simd_quatf(angle: turned, axis: Self.up).act(SIMD3(0, 0, -1))
        }
        // The head turns about the neck: the eyes swing round in front of it.
        let neck = SIMD3<Float>(0, 1.6, 0) + Self.looking(facing(0)).act(PerformerCalibration.atlasOffset)
        let trace = Self.run(&gait, from: 0, to: 5, head: { t in
            let look = Self.looking(facing(t))
            return (neck - look.act(PerformerCalibration.atlasOffset), look)
        })
        #expect(trace.steps >= 2)
        #expect(trace.slide < 0.002)
        #expect(trace.narrowest > 0.03)
        let now = facing(5)
        for foot in [gait.lowerBody.left, gait.lowerBody.right] {
            let along = foot.rotation.act(SIMD3<Float>(0, 0, 1))
            #expect(simd_dot(along, now) > cos(15 * Float.pi / 180))
        }
        #expect(!gait.report.stepping)
    }

    @Test func walkingBackwardLandsOnTheToes() {
        var walker = Walker()
        walker.travel = SIMD3(0, 0, 1)
        walker.speed = 0.5
        walker.cadence = 1.6
        var gait = PerformerGait(calibration: Self.calibration)
        // The walker's left is the travel's; the body's is the facing's.
        let trace = Self.run(&gait, from: 0, to: 8,
                             head: { (walker.head($0), Self.looking(walker.facing)) })
        let walking = trace.landings.filter { $0.time > walker.walkFrom + 1 && $0.time < walker.walkTo - 0.5 }
        #expect(walking.count >= 4)
        #expect(walking.allSatisfy { $0.pitch < -0.02 })
        #expect(trace.slide < 0.002)
        #expect(trace.narrowest > 0.03)
        #expect(!gait.report.stepping)
    }

    @Test func sideStepsNeverCross() {
        var walker = Walker()
        walker.travel = SIMD3(-1, 0, 0)
        walker.speed = 0.4
        walker.cadence = 1.5
        walker.walkTo = 4
        var gait = PerformerGait(calibration: Self.calibration)
        let trace = Self.run(&gait, from: 0, to: 6,
                             head: { (walker.head($0), Self.looking(walker.facing)) })
        #expect(trace.steps >= 4)
        #expect(trace.slide < 0.002)
        #expect(trace.narrowest > 0.03, "the feet came within \(trace.narrowest) m of crossing")
        // Still facing the way they look.
        #expect(simd_dot(gait.body.forward, SIMD3(0, 0, -1)) > 0.99)
    }

    @Test func aFewStepsAcrossTheRoomEndWithTheWalker() {
        // Two steps, half a metre, slow, with a shallow bob.
        var walker = Walker()
        walker.speed = 0.55
        walker.cadence = 1.5
        walker.bob = 0.003
        walker.sway = 0.006
        walker.walkTo = 2.2
        var gait = PerformerGait(calibration: Self.calibration)
        let trace = Self.run(&gait, from: 0, to: 5) { (walker.head($0), Self.looking(walker.facing)) }
        #expect(trace.steps >= 2)
        let last = trace.landings.last?.time ?? 0
        #expect(last < walker.walkTo + 0.9, "the last foot landed \(last - walker.walkTo) s after the walker stopped")
        #expect(trace.slide < 0.002)
        let body = gait.lowerBody
        #expect(abs(simd_dot(body.left.ankle - body.right.ankle, walker.travel)) < 0.06)
    }

    @Test func aStepBackIsAStep() {
        // Back 20 cm in a second: well inside a lean forward, but people
        // don't lean back that far.
        var gait = PerformerGait(calibration: Self.calibration)
        _ = Self.run(&gait, from: 0, to: 4) { t in
            (SIMD3<Float>(0, 1.6, 0.2 * min(max(t - 1, 0), 1)), Self.looking(SIMD3(0, 0, -1)))
        }
        #expect(gait.report.steps >= 1)
        #expect(abs(gait.body.head.z - 0.2) < 0.03)
    }

    @Test func standingTallerLiftsTheBody() {
        // Recentred stooping, 11 cm low, then standing up straight.
        var gait = PerformerGait(calibration: PerformerCalibration(head: SIMD3(0, 1.48, 0), forward: SIMD3(0, 0, -1),
                                                                   height: 1.7))
        _ = Self.run(&gait, from: 0, to: 3) { t in
            (SIMD3<Float>(0, 1.48 + 0.11 * min(max(t - 1, 0), 1), 0), Self.looking(SIMD3(0, 0, -1)))
        }
        #expect(abs(gait.body.head.y - 1.59) < 0.01)
    }

    @Test func aLeanForwardKeepsTheBodyTall() {
        var gait = PerformerGait(calibration: Self.calibration)
        // 25 cm out over the desk, the head lower as it goes.
        _ = Self.run(&gait, from: 0, to: 3) { t in
            let u = min(max(t - 1, 0), 1)
            return (SIMD3<Float>(0, 1.6 - 0.05 * u, -0.25 * u), Self.looking(SIMD3(0, 0, -1)))
        }
        #expect(gait.report.steps == 0)
        #expect(abs(gait.body.head.y - 1.6) < 0.015)
    }

    @Test func aCrouchLowersThePelvis() {
        var gait = PerformerGait(calibration: Self.calibration)
        let standing = gait.lowerBody.pelvis.y
        let trace = Self.run(&gait, from: 0, to: 3, head: { t in
            (SIMD3<Float>(0, 1.6 - 0.15 * min(max(t - 1, 0), 1), 0), Self.looking(SIMD3(0, 0, -1)))
        })
        #expect(trace.steps == 0)
        #expect(abs(gait.lowerBody.pelvis.y - (standing - 0.15)) < 0.02)
        #expect(gait.lowerBody.left.planted && gait.lowerBody.right.planted)
    }

    @Test func sittingHandsTheLegsBack() {
        var gait = PerformerGait(calibration: Self.calibration)
        _ = Self.run(&gait, from: 0, to: 4, head: { t in
            (SIMD3<Float>(0, 1.6 - 0.45 * min(max(t - 1, 0), 1), 0), Self.looking(SIMD3(0, 0, -1)))
        })
        #expect(gait.report.seated)
        #expect(gait.lowerBody.weight < 0.01)
    }
}

/// `PerformerRig` posing legs from a lower body.
@Suite("PerformerRig legs")
struct PerformerRigLegTests {

    static let calibration = PerformerRigTests.calibration

    static func rig() -> PerformerRig {
        PerformerRig(PerformerRigTests.skeleton(legs: true))!
    }

    static func standing(_ rig: PerformerRig) -> PerformerGait {
        let scale = rig.ownBodyScale(calibration: calibration)
        return PerformerGait(calibration: calibration, foot: rig.footShape(scale: scale),
                             stanceWidth: rig.stanceWidth(scale: scale))
    }

    static func world(_ rig: PerformerRig, _ pose: [JointPose], _ joint: Int,
                      placement: simd_float4x4) -> SIMD3<Float> {
        let model = PoseSolver(parents: rig.skeleton.parents).modelMatrices(of: pose)
        let p = placement * SIMD4<Float>(PoseSolver.translation(of: model[joint]), 1)
        return SIMD3(p.x, p.y, p.z)
    }

    @Test func feetFromTheBindPose() {
        let rig = Self.rig()
        // The test skeleton's ankle is 8 cm over its toe, 10 cm behind it.
        let shape = rig.footShape(scale: 1)!
        #expect(abs(shape.ankleHeight - 0.08) < 1e-4)
        #expect(abs(shape.ball - 0.1) < 1e-4)
        #expect(shape.hasHeel)
        #expect(abs(rig.stanceWidth(scale: 1)! - 0.2) < 1e-4)
    }

    @Test func toesFoundWhereTheyBend() {
        // The Synth's foot: a hub on the ankle every toe hangs off, two toes
        // forward from it and a claw reaching back along the floor.
        var skeleton = PerformerRigTests.skeleton()
        func j(_ x: Float, _ y: Float, _ z: Float) -> JointPose { JointPose(translation: SIMD3(x, y, z)) }
        var toes: [Int] = []
        for side: Float in [1, -1] {
            let thigh = skeleton.rest.count
            skeleton.rest += [j(0.1 * side, -0.05, 0), j(0, -0.45, 0.04), j(0, -0.42, -0.04),
                              j(0, 0, 0.017),
                              j(0.02, -0.01, 0.019), j(0, -0.01, 0.045),
                              j(-0.02, -0.01, 0.019), j(0, -0.01, 0.045),
                              j(0, 0.01, -0.02), j(0, -0.04, -0.06)]
            skeleton.parents += [0, thigh, thigh + 1, thigh + 2,
                                 thigh + 3, thigh + 4, thigh + 3, thigh + 6, thigh + 3, thigh + 8]
            toes += [thigh + 4, thigh + 6]
        }
        let rig = PerformerRig(skeleton)!
        #expect(rig.hasLegs)
        let shape = rig.footShape(scale: 1)!
        #expect(abs(shape.ball - 0.036) < 1e-3, "ball \(shape.ball)")
        #expect(abs(shape.heel - 0.063) < 1e-3, "heel \(shape.heel)")

        // A toe bend bends those two toes, not the hub or the claw.
        let gait = Self.standing(rig)
        var lower = gait.lowerBody
        lower.left.toeBend = 30 * .pi / 180
        var bent = rig
        let flat = bent.solve(base: skeleton.rest, frame: nil, calibration: Self.calibration, mirrored: false,
                              deltaTime: 1 / 90, lowerBody: gait.lowerBody)
        bent.reset()
        let raised = bent.solve(base: skeleton.rest, frame: nil, calibration: Self.calibration, mirrored: false,
                                deltaTime: 1 / 90, lowerBody: lower)
        let solver = PoseSolver(parents: skeleton.parents)
        let a = solver.modelMatrices(of: flat), b = solver.modelMatrices(of: raised)
        func turned(_ joint: Int) -> Float {
            (PoseSolver.rotation(of: b[joint]) * PoseSolver.rotation(of: a[joint]).inverse).angle * 180 / .pi
        }
        let left = 23
        #expect(abs(turned(toes[0]) - 30) < 1 && abs(turned(toes[1]) - 30) < 1)
        #expect(turned(left + 3) < 0.5 && turned(left + 8) < 0.5)
    }

    @Test func legsReachTheFeet() {
        var rig = Self.rig()
        let gait = Self.standing(rig)
        let base = rig.skeleton.rest
        let placement = rig.ownBodyPlacement(calibration: Self.calibration, pose: base)
        let pose = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false, deltaTime: 1 / 90,
                             placement: placement, lowerBody: gait.lowerBody)
        #expect(rig.report.leftFootError < 0.005 && rig.report.rightFootError < 0.005)
        // Feet where the gait put them, give or take the same sink for both.
        let left = Self.world(rig, pose, 25, placement: placement)
        let right = Self.world(rig, pose, 30, placement: placement)
        let sink = left.y - gait.lowerBody.left.ankle.y
        #expect(simd_distance(left - SIMD3(0, sink, 0), gait.lowerBody.left.ankle) < 0.01)
        #expect(simd_distance(right - SIMD3(0, sink, 0), gait.lowerBody.right.ankle) < 0.01)
        // Standing, the legs stay straight: the knee hardly bends.
        let model = PoseSolver(parents: rig.skeleton.parents).modelMatrices(of: pose)
        let hip = PoseSolver.translation(of: model[23]), knee = PoseSolver.translation(of: model[24])
        let ankle = PoseSolver.translation(of: model[25])
        let bend = acos(simd_dot(simd_normalize(knee - hip), simd_normalize(ankle - knee))) * 180 / .pi
        #expect(bend < 8, "the knee bent \(bend)° standing")
    }

    @Test func theSameLegsWithoutAPlacement() {
        var rig = Self.rig()
        let gait = Self.standing(rig)
        let base = rig.skeleton.rest
        let placement = rig.ownBodyPlacement(calibration: Self.calibration, pose: base)
        let placed = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                               deltaTime: 1 / 90, placement: placement, lowerBody: gait.lowerBody)
        rig.reset()
        let unplaced = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                                 deltaTime: 1 / 90, lowerBody: gait.lowerBody)
        for joint in [23, 24, 25, 28, 29, 30] {
            #expect(simd_distance(placed[joint].rotation.vector, unplaced[joint].rotation.vector) < 1e-4)
        }
    }

    @Test func aRaisedHeelTipsTheFootAndBendsTheToes() {
        var rig = Self.rig()
        let gait = Self.standing(rig)
        var lower = gait.lowerBody
        let flat = lower.left.rotation
        let lateral = flat.act(SIMD3<Float>(1, 0, 0))
        // Heel up 30°, toes flat on the floor.
        lower.left.rotation = simd_quatf(angle: 30 * .pi / 180, axis: lateral) * flat
        lower.left.toeBend = 30 * .pi / 180
        let base = rig.skeleton.rest
        let pose = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                             deltaTime: 1 / 90, lowerBody: lower)
        let model = PoseSolver(parents: rig.skeleton.parents).modelMatrices(of: pose)
        let rest = PoseSolver(parents: rig.skeleton.parents).modelMatrices(of: base)
        func toe(_ m: [float4x4]) -> SIMD3<Float> {
            simd_normalize(PoseSolver.translation(of: m[26]) - PoseSolver.translation(of: m[25]))
        }
        let tipped = acos(simd_dot(toe(model), toe(rest))) * 180 / .pi
        #expect(abs(tipped - 30) < 2, "the foot tipped \(tipped)°")
        #expect(toe(model).y < toe(rest).y)
        // The toe joint turned back by as much, so the toes lie as they did.
        let foot = PoseSolver.rotation(of: model[25]), toes = PoseSolver.rotation(of: model[26])
        let restFoot = PoseSolver.rotation(of: rest[25]), restToes = PoseSolver.rotation(of: rest[26])
        let bend = (foot.inverse * toes * (restFoot.inverse * restToes).inverse).angle * 180 / .pi
        #expect(abs(bend - 30) < 2, "the toes bent \(bend)°")
        // So they lie as they do on a flat foot.
        rig.reset()
        let flatPose = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                                 deltaTime: 1 / 90, lowerBody: gait.lowerBody)
        let flatToes = PoseSolver.rotation(of: PoseSolver(parents: rig.skeleton.parents).modelMatrices(of: flatPose)[26])
        let off = (toes * flatToes.inverse).angle * 180 / .pi
        #expect(off < 2, "the toes turned \(off)° from where they lie on a flat foot")
    }

    @Test func aTurnedPelvisLeavesTheChest() {
        var rig = Self.rig()
        let gait = Self.standing(rig)
        var lower = gait.lowerBody
        let base = rig.skeleton.rest
        let straight = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                                 deltaTime: 1 / 90, lowerBody: lower)
        lower.pelvisRotation = simd_normalize(lower.pelvisRotation * simd_quatf(angle: 10 * .pi / 180,
                                                                                axis: SIMD3(0, 1, 0)))
        rig.reset()
        let turned = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                               deltaTime: 1 / 90, lowerBody: lower)
        let solver = PoseSolver(parents: rig.skeleton.parents)
        let a = solver.modelMatrices(of: straight), b = solver.modelMatrices(of: turned)
        let hips = (PoseSolver.rotation(of: b[0]) * PoseSolver.rotation(of: a[0]).inverse).angle * 180 / .pi
        let chest = (PoseSolver.rotation(of: b[2]) * PoseSolver.rotation(of: a[2]).inverse).angle * 180 / .pi
        #expect(abs(hips - 10) < 0.5)
        #expect(chest < 0.5)
    }

    /// A deep collar round the base of the neck, 13 cm out, on the chest.
    static func collar() -> [(joint: Int, position: SIMD3<Float>)] {
        (0..<24).map { i in
            let a = Float(i) / 24 * 2 * .pi
            return (PerformerRigTests.chest, SIMD3<Float>(0.13 * cos(a), 1.42, 0.13 * sin(a)))
        }
    }

    /// Runs the own body for a second with the head pitched down by
    /// `pitch` degrees about the neck, and returns the rig and its last
    /// placement and pose.
    static func lookDown(_ pitch: Float) -> (rig: PerformerRig, placement: simd_float4x4, pose: [JointPose],
                                              eye: SIMD3<Float>) {
        var rig = Self.rig()
        rig.keepClear(of: collar())
        let gait = Self.standing(rig)
        let neutral = PerformerRig.neutralHead(performer: PerformerRig.frame(up: SIMD3(0, 1, 0),
                                                                             forward: calibration.forward))
        let offset = PerformerCalibration.atlasOffset
        let atlas = calibration.head + neutral.act(offset)
        let look = simd_normalize(simd_quatf(angle: -pitch * .pi / 180, axis: SIMD3(1, 0, 0)) * neutral)
        let eye = atlas - look.act(offset)
        let frame = PerformerFrame(head: eye, headRotation: look)
        let base = rig.skeleton.rest
        var placement = matrix_identity_float4x4
        var pose = base
        for _ in 0..<90 {
            placement = rig.cleared(rig.ownBodyPlacement(calibration: calibration, pose: base), calibration: calibration)
            pose = rig.solve(base: base, frame: frame, calibration: calibration, mirrored: false, deltaTime: 1 / 90,
                             placement: placement, lowerBody: gait.lowerBody)
        }
        return (rig, placement, pose, eye)
    }

    @Test func lookingDownKeepsTheCollarOutOfTheEyes() {
        let down = Self.lookDown(60)
        #expect(down.rig.report.clearance > 0.02, "stood back \(down.rig.report.clearance) m")
        // Nothing of the collar within 10 cm of the eye now.
        let model = PoseSolver(parents: down.rig.skeleton.parents).modelMatrices(of: down.pose)
        let nearest = Self.collar().map { point -> Float in
            let local = PoseSolver(parents: down.rig.skeleton.parents).modelMatrices(of: down.rig.skeleton.rest)[point.joint]
                .inverse * SIMD4<Float>(point.position, 1)
            let w = down.placement * model[point.joint] * local
            return simd_distance(SIMD3(w.x, w.y, w.z), down.eye)
        }.min()!
        #expect(nearest > 0.098, "the collar came within \(nearest) m of the eye")
        // The feet stayed where they stood.
        #expect(down.rig.report.leftFootError < 0.005 && down.rig.report.rightFootError < 0.005)

        // Looking ahead, nothing is near: the body stands where it belongs.
        #expect(Self.lookDown(0).rig.report.clearance < 0.001)
    }

    @Test func untrackedArmsSwing() {
        var rig = Self.rig()
        let gait = Self.standing(rig)
        var lower = gait.lowerBody
        // The test skeleton is T-posed; a swing shows on arms that hang.
        var base = rig.skeleton.rest
        base[PerformerRigTests.leftUpper].rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1))
        base[PerformerRigTests.rightUpper].rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let still = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                              deltaTime: 1 / 90, lowerBody: lower)
        lower.armSwing = 1
        rig.reset()
        let swung = rig.solve(base: base, frame: nil, calibration: Self.calibration, mirrored: false,
                              deltaTime: 1 / 90, lowerBody: lower)
        let solver = PoseSolver(parents: rig.skeleton.parents)
        let a = solver.modelMatrices(of: still), b = solver.modelMatrices(of: swung)
        let left = PerformerRigTests.leftHand, right = PerformerRigTests.rightHand
        // The avatar faces +Z: the left hand forward, the right back.
        #expect(PoseSolver.translation(of: b[left]).z > PoseSolver.translation(of: a[left]).z + 0.02)
        #expect(PoseSolver.translation(of: b[right]).z < PoseSolver.translation(of: a[right]).z - 0.02)
    }
}
