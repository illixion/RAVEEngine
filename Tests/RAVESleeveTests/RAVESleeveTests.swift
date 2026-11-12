import Foundation
import RAVEInput
import RAVEModuleBus
import Testing
import simd
@testable import RAVESleeve

/// An arm with its outer face pointing along `back`, running along `along`
/// from the wrist to the elbow.
private func makeArm(_ side: RAVESleeveSide = .left, wrist: SIMD3<Float> = [0, 1.2, -0.4],
                     along: SIMD3<Float> = [-1, 0, 0], back: SIMD3<Float> = [0, 1, 0],
                     elbow: Bool = true) -> RAVESleeveArm {
    RAVESleeveArm(side: side, wrist: wrist, elbow: elbow ? wrist + along * 0.26 : nil,
                  palm: RAVEPalmPose(position: wrist - along * 0.05, palmNormalOut: -back,
                                     fingersDirection: -along))
}

private func column(_ m: simd_float4x4, _ i: Int) -> SIMD3<Float> {
    let c = m[i]
    return SIMD3(c.x, c.y, c.z)
}

private let above = SIMD3<Float>(-0.1, 1.8, -0.4)

private func deck() -> RAVESleeveLayout {
    RAVESleeveLayout(
        outer: [
            RAVESleevePage("main", rows: [
                [RAVESleeveTile("a", .button(RAVESleeveAction("act.a"))),
                 RAVESleeveTile("b", .toggle(RAVESleeveAction("act.b"))),
                 RAVESleeveTile("c", .hold(RAVESleeveAction("act.panic"), seconds: 0.5), role: .destructive)],
                [RAVESleeveTile("vol", .slider(RAVESleeveAction("act.vol")), span: 2),
                 RAVESleeveTile("more", .page("second"))],
                [RAVESleeveTile("wheel", .radial("tools")),
                 RAVESleeveTile("web", .dock("chat")),
                 RAVESleeveTile("hp", .gauge(segments: 10))],
            ]),
            RAVESleevePage("second", rows: [[RAVESleeveTile("back", .page("main"))]]),
        ],
        inner: [RAVESleevePage("palm", rows: [[RAVESleeveTile("p", .button(RAVESleeveAction("act.p")))]])],
        radials: [RAVESleeveRadialMenu("tools", entries: [
            RAVESleeveRadialEntry("n", label: "North", action: RAVESleeveAction("tool.n")),
            RAVESleeveRadialEntry("e", label: "East", members: [
                RAVESleeveRadialEntry("e1", label: "East one", action: RAVESleeveAction("tool.e1")),
                RAVESleeveRadialEntry("e2", label: "East two", action: RAVESleeveAction("tool.e2")),
            ]),
            RAVESleeveRadialEntry("s", label: "South", action: RAVESleeveAction("tool.s"), confirmSeconds: 0.4),
            RAVESleeveRadialEntry("w", label: "West", action: RAVESleeveAction("tool.w")),
        ])],
        docks: [RAVESleeveDock("chat", kind: "web", argument: "https://example.com")])
}

/// Runs the sleeve for `seconds` at 90 Hz and returns the last snapshot.
@discardableResult
private func run(_ sleeve: inout RAVESleeve, arm: RAVESleeveArm?, head: SIMD3<Float> = above,
                 from start: TimeInterval, seconds: TimeInterval, showAllowed: Bool = true,
                 fingertip: ((RAVESleeveSnapshot) -> SIMD3<Float>?)? = nil) -> RAVESleeveSnapshot {
    var t = start
    var last = sleeve.update(arm: arm, head: head, now: t, showAllowed: showAllowed)
    while t < start + seconds {
        t += 1.0 / 90
        last = sleeve.update(arm: arm, head: head, now: t, showAllowed: showAllowed)
        if let fingertip { sleeve.touch(fingertip: fingertip(last), now: t) }
    }
    return last
}

private func over(_ snapshot: RAVESleeveSnapshot, _ id: String, x: Float = 0, height: Float) -> SIMD3<Float>? {
    guard let tile = snapshot.tiles.first(where: { $0.tile.id == id }) else { return nil }
    let p = tile.transform * SIMD4(x, 0, height, 1)
    return SIMD3(p.x, p.y, p.z)
}

@Suite struct RAVESleeveFrameTests {
    @Test func thumbSideDependsOnTheArm() throws {
        // Palm down, fingers ahead (-z), so the elbow is toward +z.
        let right = try #require(RAVESleeveFrame(arm: makeArm(.right, along: [0, 0, 1])))
        let left = try #require(RAVESleeveFrame(arm: makeArm(.left, along: [0, 0, 1])))
        #expect(simd_distance(right.back, [0, 1, 0]) < 1e-5)
        #expect(simd_distance(right.thumbward, [-1, 0, 0]) < 1e-5)
        #expect(simd_distance(left.thumbward, [1, 0, 0]) < 1e-5)
        #expect(abs(right.length - 0.26) < 1e-5)
        #expect(!right.isEstimated)
    }

    @Test func anglesGoRoundTowardTheThumb() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm(.right, along: [0, 0, 1])))
        #expect(simd_distance(frame.normal(angle: 0), frame.back) < 1e-5)
        #expect(simd_distance(frame.normal(angle: .pi / 2), frame.thumbward) < 1e-5)
        #expect(simd_distance(frame.normal(angle: .pi), -frame.back) < 1e-5)
        let p = frame.point(distance: 0.1, angle: 0, radius: 0.05)
        #expect(simd_distance(p, frame.origin + [0, 0.05, 0.1]) < 1e-5)
    }

    @Test func aWatchTileReadsWithTheArmAcrossTheBody() throws {
        // Left arm across the body: hand to the reader's right, elbow left.
        let left = try #require(RAVESleeveFrame(arm: makeArm(.left, along: [-1, 0, 0])))
        let tile = left.tile(distance: 0.1, angle: 0, radius: 0.05)
        #expect(simd_distance(column(tile, 0), [1, 0, 0]) < 1e-5)    // text runs to the reader's right
        #expect(simd_distance(column(tile, 1), [0, 0, -1]) < 1e-5)   // its top is away from the body
        #expect(simd_distance(column(tile, 2), [0, 1, 0]) < 1e-5)    // facing out of the arm
        // Right arm across the body: hand to the reader's left.
        let right = try #require(RAVESleeveFrame(arm: makeArm(.right, along: [1, 0, 0])))
        let other = right.tile(distance: 0.1, angle: 0, radius: 0.05)
        #expect(simd_distance(column(other, 0), [1, 0, 0]) < 1e-5)
        #expect(simd_distance(column(other, 1), [0, 0, -1]) < 1e-5)
    }

    @Test func aLengthwiseTileHasItsTopTowardTheHand() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm(.left, along: [0, 0, 1])))
        let tile = frame.tile(distance: 0.1, angle: 0, radius: 0.05, reading: .lengthwise)
        #expect(simd_distance(column(tile, 1), [0, 0, -1]) < 1e-5)
        #expect(simd_distance(column(tile, 2), [0, 1, 0]) < 1e-5)
        #expect(abs(simd_determinant(simd_float3x3(column(tile, 0), column(tile, 1), column(tile, 2))) - 1) < 1e-5)
    }

    @Test func withoutAnElbowTheArmRunsBackFromTheFingers() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm(along: [0, 0, 1], elbow: false)))
        #expect(frame.isEstimated)
        #expect(simd_distance(frame.along, [0, 0, 1]) < 1e-5)
        #expect(frame.length == RAVESleeveFrame.defaultLength)
    }

    @Test func aHandBentAlongTheArmGivesNoFrame() {
        // The back of the hand points along the arm: no way to tell the roll.
        #expect(RAVESleeveFrame(arm: makeArm(along: [0, 1, 0], back: [0, 1, 0])) == nil)
    }

    @Test func twistBlendsTowardTheElbow() throws {
        var arm = makeArm(.right, along: [0, 0, 1])
        arm.elbowBack = [-1, 0, 0]   // the elbow end is turned 90° toward the thumb
        let frame = try #require(RAVESleeveFrame(arm: arm))
        #expect(simd_distance(frame.normal(angle: 0, distance: 0), [0, 1, 0]) < 1e-5)
        #expect(simd_distance(frame.normal(angle: 0, distance: frame.length), [-1, 0, 0]) < 1e-4)
    }

    @Test func facingIsOneSquareOnAndNegativeBehind() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm()))
        let head = frame.point(distance: 0.1, angle: 0, radius: 0.5)
        #expect(frame.facing(angle: 0, distance: 0.1, radius: 0.05, toward: head) > 0.999)
        #expect(frame.facing(angle: .pi, distance: 0.1, radius: 0.05, toward: head) < -0.9)
    }
}

@Suite struct RAVESleeveFollowerTests {
    @Test func aStillArmLosesItsJitter() {
        var follower = RAVESleeveFollower()
        var worst: Float = 0
        for i in 0..<180 {
            // 2 mm of alternating tracking noise on the wrist.
            let noise = SIMD3<Float>(i % 2 == 0 ? 0.002 : -0.002, 0, 0)
            let frame = follower.update(arm: makeArm(wrist: [0, 1.2, -0.4] + noise), now: Double(i) / 90)
            if i > 90, let frame { worst = max(worst, abs(frame.origin.x)) }
        }
        #expect(worst < 0.0006)
    }

    @Test func aMovingArmIsNotLeftBehind() throws {
        var follower = RAVESleeveFollower()
        var lag: Float = 0
        for i in 0..<180 {
            let t = Double(i) / 90
            let x = Float(t) * 0.8   // 0.8 m/s
            let updated = follower.update(arm: makeArm(wrist: [x, 1.2, -0.4]), now: t)
            let frame = try #require(updated)
            if i > 45 { lag = max(lag, x - frame.origin.x) }
        }
        // The palm panels' 0.06 s ease trails by 4.8 cm at this speed.
        #expect(lag < 0.006)
    }

    @Test func aDropoutKeepsTheFrameAndALongGapStartsAfresh() throws {
        var follower = RAVESleeveFollower()
        follower.update(arm: makeArm(), now: 0)
        let dropped = follower.update(arm: nil, now: 0.1)
        let kept = try #require(dropped)
        #expect(!follower.isTracked)
        #expect(simd_distance(kept.origin, [0, 1.2, -0.4]) < 1e-5)
        // Back a second later somewhere else: there at once, no sweep.
        let back = follower.update(arm: makeArm(wrist: [0.5, 1, -0.3]), now: 1.1)
        let moved = try #require(back)
        #expect(follower.isTracked)
        #expect(simd_distance(moved.origin, [0.5, 1, -0.3]) < 1e-5)
    }
}

@Suite struct RAVESleeveLayoutTests {
    @Test func aLayoutSurvivesJSON() throws {
        let layout = deck()
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(RAVESleeveLayout.self, from: data) == layout)
    }

    @Test func problemsNameWhatIsMissing() {
        #expect(deck().problems().isEmpty)
        var broken = deck()
        broken.radials = []
        broken.outer[1].rows[0].append(RAVESleeveTile("a", .page("nowhere")))
        let problems = broken.problems()
        #expect(problems.count == 3)
        #expect(problems.contains { $0.contains("\"a\" is used more than once") })
        #expect(problems.contains { $0.contains("radial menu \"tools\"") })
        #expect(problems.contains { $0.contains("page \"nowhere\"") })
    }

    @Test func theMediaRemoteSpeaksTheBusVocabulary() {
        #expect(RAVESleevePresets.MediaAction.play == RAVEMediaActionID.play)
        #expect(RAVESleevePresets.MediaAction.pause == RAVEMediaActionID.pause)
        #expect(RAVESleevePresets.MediaAction.skip == RAVEMediaActionID.skip)
        #expect(RAVESleevePresets.MediaAction.next == RAVEMediaActionID.next)
        let page = RAVESleevePresets.mediaRemote()
        #expect(page.columns == 4)
        #expect(RAVESleeveLayout(outer: [page]).problems().isEmpty)
    }
}

@Suite struct RAVESleevePlacementTests {
    let metrics = RAVESleeveMetrics()

    @Test func tilesSitOnTheArmAndFaceOut() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm()))
        let placed = RAVESleeve.place(page: deck().outer[0], face: .outer, frame: frame, metrics: metrics,
                                      reading: .watch)
        #expect(placed.count == 8)
        for item in placed {
            let centre = column(item.transform, 3)
            let offset = centre - frame.origin
            let alongArm = simd_dot(offset, frame.along)
            let fromAxis = offset - frame.along * alongArm
            #expect(abs(simd_length(fromAxis) - metrics.radius) < 1e-5)
            #expect(simd_dot(column(item.transform, 2), simd_normalize(fromAxis)) > 0.9999)
            #expect(alongArm > metrics.start)
        }
    }

    @Test func aRowRunsAlongTheArmAndRowsGoRoundIt() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm(.left)))
        let placed = RAVESleeve.place(page: deck().outer[0], face: .outer, frame: frame, metrics: metrics,
                                      reading: .watch)
        func centre(_ id: String) -> SIMD3<Float> { column(placed.first { $0.tile.id == id }!.transform, 3) }
        let pitch = metrics.cell + metrics.gap
        // a, b, c read left to right: on a left arm that is from the elbow toward the hand.
        #expect(abs(simd_dot(centre("b") - centre("a"), -frame.along) - pitch) < 1e-5)
        #expect(abs(simd_dot(centre("c") - centre("b"), -frame.along) - pitch) < 1e-5)
        // The middle row is on the face's centre line; the top row is away from the body.
        #expect(abs(simd_dot(centre("more") - frame.origin, frame.thumbward)) < 1e-5)
        #expect(simd_dot(centre("a") - centre("wheel"), -frame.thumbward) > pitch)
        // A two-cell tile is two cells and a gap wide.
        #expect(abs(placed.first { $0.tile.id == "vol" }!.size.x - (2 * metrics.cell + metrics.gap)) < 1e-6)
    }

    @Test func theInnerFaceIsOnTheOtherSide() throws {
        let frame = try #require(RAVESleeveFrame(arm: makeArm()))
        let placed = RAVESleeve.place(page: deck().inner[0], face: .inner, frame: frame, metrics: metrics,
                                      reading: .watch)
        #expect(simd_distance(column(placed[0].transform, 2), -frame.back) < 1e-5)
    }
}

@Suite struct RAVESleeveBehaviourTests {
    @Test func theFaceTurnedToTheEyesShowsAfterADwell() {
        var sleeve = RAVESleeve(layout: deck())
        let first = sleeve.update(arm: makeArm(), head: above, now: 0)
        #expect(!first.isVisible)
        let shown = run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        #expect(shown.outerOpacity == 1)
        #expect(shown.innerOpacity == 0)
        #expect(shown.tiles.count == 8)
        #expect(shown.tiles.allSatisfy { $0.face == .outer })
        // Turn the arm over: the palm side takes its place.
        let turned = run(&sleeve, arm: makeArm(back: [0, -1, 0]), from: 0.4, seconds: 1)
        #expect(turned.outerOpacity == 0)
        #expect(turned.innerOpacity == 1)
        #expect(turned.tiles.map(\.tile.id) == ["p"])
    }

    @Test func theHostCanRefuse() {
        var sleeve = RAVESleeve(layout: deck())
        #expect(!run(&sleeve, arm: makeArm(), from: 0, seconds: 0.5, showAllowed: false).isVisible)
    }

    @Test func aLostArmFadesWhereItWas() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        let lingering = run(&sleeve, arm: nil, from: 0.4, seconds: 0.2)
        #expect(lingering.outerOpacity == 1)   // inside the linger
        #expect(run(&sleeve, arm: nil, from: 0.6, seconds: 0.6).outerOpacity == 0)
    }

    @Test func tilesHaveStableTargets() {
        var sleeve = RAVESleeve(layout: deck())
        let shown = run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        #expect(shown.tiles.map(\.target) == Array(1...8))
        sleeve.showPage("second", on: .outer)
        #expect(sleeve.update(arm: makeArm(), head: above, now: 0.5).tiles.map(\.target) == [9])
    }

    @Test func aButtonFiresOnThePressAndLocksOutBriefly() {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.tap("a", now: 1)
        sleeve.tap("a", now: 1.05)   // a bounce
        sleeve.tap("a", now: 1.3)
        let events = sleeve.takeEvents()
        #expect(events.count == 2)
        #expect(events[0] == RAVESleeveEvent(tile: "a", action: RAVESleeveAction("act.a"), kind: .fired,
                                             source: .indirect))
        #expect(sleeve.takeEvents().isEmpty)
    }

    @Test func aToggleSaysWhatItShouldBecome() {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.tap("b", now: 1)
        sleeve.states["b"] = RAVESleeveTileState(isOn: true)
        sleeve.tap("b", now: 2)
        #expect(sleeve.takeEvents().map(\.kind) == [.toggled(true), .toggled(false)])
    }

    @Test func aDisabledOrHiddenTileDoesNothing() {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.states["a"] = RAVESleeveTileState(disabled: true)
        sleeve.tap("a", now: 1)
        sleeve.tap("hp", now: 1)   // a gauge is not pressable
        #expect(sleeve.takeEvents().isEmpty)
        sleeve.states["a"] = RAVESleeveTileState(hidden: true)
        #expect(run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4).tiles.count == 7)
    }

    @Test func aHoldFiresOnceWhenItRunsOut() {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.pressBegan("c", now: 0)
        let half = run(&sleeve, arm: makeArm(), from: 0, seconds: 0.25)
        #expect(sleeve.takeEvents().isEmpty)
        let progress = half.tiles.first { $0.tile.id == "c" }?.holdProgress ?? 0
        #expect(progress > 0.4 && progress < 0.6)
        run(&sleeve, arm: makeArm(), from: 0.25, seconds: 0.5)
        let events = sleeve.takeEvents()
        #expect(events.map(\.kind) == [.fired])
        #expect(events.first?.action == RAVESleeveAction("act.panic"))
        sleeve.pressEnded("c", now: 0.8)
        run(&sleeve, arm: makeArm(), from: 0.8, seconds: 0.3)
        #expect(sleeve.takeEvents().isEmpty)
    }

    @Test func aHoldLetGoEarlyDoesNotFire() {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.pressBegan("c", now: 0)
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.2)
        sleeve.pressEnded("c", now: 0.2)
        let after = run(&sleeve, arm: makeArm(), from: 0.2, seconds: 0.8)
        #expect(sleeve.takeEvents().isEmpty)
        #expect(after.tiles.first { $0.tile.id == "c" }?.holdProgress == nil)
    }

    @Test func aPageTileTurnsThePage() {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.tap("more", now: 1)
        #expect(sleeve.currentPage(.outer)?.id == "second")
        #expect(sleeve.takeEvents().map(\.kind) == [.page("second")])
        #expect(run(&sleeve, arm: makeArm(), from: 1, seconds: 0.4).tiles.map(\.tile.id) == ["back"])
    }

    @Test func aDockStandsOffTheArmFacingTheEyes() throws {
        var sleeve = RAVESleeve(layout: deck())
        sleeve.tap("web", now: 0)
        #expect(sleeve.takeEvents().map(\.kind) == [.dock("chat", open: true)])
        let shown = run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        let dock = try #require(shown.docks.first)
        let transform = try #require(dock.transform)
        let frame = try #require(shown.frame)
        let centre = column(transform, 3)
        // Its long edge runs along the arm and it faces the eyes.
        #expect(abs(simd_dot(column(transform, 0), frame.along)) > 0.999)
        #expect(simd_dot(column(transform, 2), simd_normalize(above - centre)) > 0.8)
        // Clear of the arm.
        let offset = centre - frame.origin
        let fromAxis = simd_length(offset - frame.along * simd_dot(offset, frame.along))
        #expect(fromAxis > sleeve.metrics.radius + dock.dock.height / 2)
        sleeve.tap("web", now: 1)
        #expect(sleeve.takeEvents().map(\.kind) == [.dock("chat", open: false)])
    }
}

@Suite struct RAVESleeveTouchTests {
    /// A fingertip that comes down over `id` from 3 cm to the skin and back up.
    private func poke(_ sleeve: inout RAVESleeve, _ id: String, from start: TimeInterval, x: Float = 0) {
        run(&sleeve, arm: makeArm(), from: start, seconds: 0.2) { over($0, id, x: x, height: 0.03) }
        run(&sleeve, arm: makeArm(), from: start + 0.2, seconds: 0.1) { over($0, id, x: x, height: -0.003) }
        run(&sleeve, arm: makeArm(), from: start + 0.3, seconds: 0.2) { over($0, id, x: x, height: 0.03) }
    }

    @Test func aFingerComingDownPressesOnce() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        poke(&sleeve, "a", from: 0.4)
        let events = sleeve.takeEvents()
        #expect(events.map(\.kind) == [.fired])
        #expect(events.first?.source == .touch)
    }

    @Test func aFingerArrivingFromTheSideOrBehindPressesNothing() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        // Already below the press height when it reaches the tile.
        run(&sleeve, arm: makeArm(), from: 0.4, seconds: 0.3) { over($0, "a", height: -0.002) }
        // Far behind the tile: a hand under the arm.
        run(&sleeve, arm: makeArm(), from: 0.7, seconds: 0.3) { over($0, "a", height: -0.08) }
        #expect(sleeve.takeEvents().isEmpty)
    }

    @Test func aPressedTileShowsItAndHoverRisesOnTheWayDown() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        let high = run(&sleeve, arm: makeArm(), from: 0.4, seconds: 0.1) { over($0, "b", height: 0.03) }
        let low = run(&sleeve, arm: makeArm(), from: 0.5, seconds: 0.1) { over($0, "b", height: 0.008) }
        let hoverHigh = high.tiles.first { $0.tile.id == "b" }?.hover ?? 0
        let hoverLow = low.tiles.first { $0.tile.id == "b" }?.hover ?? 0
        #expect(hoverHigh > 0 && hoverLow > hoverHigh)
        let down = run(&sleeve, arm: makeArm(), from: 0.6, seconds: 0.1) { over($0, "b", height: 0) }
        #expect(down.tiles.first { $0.tile.id == "b" }?.isPressed == true)
    }

    @Test func aHoldSurvivesAShortTrackingDropout() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        run(&sleeve, arm: makeArm(), from: 0.4, seconds: 0.1) { over($0, "c", height: 0.02) }
        run(&sleeve, arm: makeArm(), from: 0.5, seconds: 0.2) { over($0, "c", height: 0) }
        run(&sleeve, arm: makeArm(), from: 0.7, seconds: 0.1) { _ in nil }   // the finger is lost
        run(&sleeve, arm: makeArm(), from: 0.8, seconds: 0.4) { over($0, "c", height: 0) }
        #expect(sleeve.takeEvents().map(\.kind) == [.fired])
    }

    @Test func aLostFingerLetsGo() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        run(&sleeve, arm: makeArm(), from: 0.4, seconds: 0.1) { over($0, "c", height: 0.02) }
        run(&sleeve, arm: makeArm(), from: 0.5, seconds: 0.1) { over($0, "c", height: 0) }
        let gone = run(&sleeve, arm: makeArm(), from: 0.6, seconds: 0.8) { _ in nil }
        #expect(sleeve.takeEvents().isEmpty)
        #expect(gone.tiles.first { $0.tile.id == "c" }?.isPressed == false)
    }

    @Test func aSliderTakesItsValueFromWhereItIsTouched() {
        var sleeve = RAVESleeve(layout: deck())
        let shown = run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        let width = shown.tiles.first { $0.tile.id == "vol" }!.size.x
        poke(&sleeve, "vol", from: 0.4, x: width * 0.25)
        let values = sleeve.takeEvents().compactMap { event -> Float? in
            if case let .value(v) = event.kind { return v }
            return nil
        }
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { abs($0 - 0.75) < 0.01 })
    }
}

@Suite struct RAVESleeveRadialTests {
    private func menu() -> RAVESleeveRadial {
        RAVESleeveRadial(menu: deck().radials[0])
    }

    @Test func travelArmsAWedgeAndAReleasePicksIt() {
        var radial = menu()
        radial.point(local: [0, 0.01], now: 0)
        #expect(radial.armed == -1)                       // inside the centre
        radial.point(local: [0.03, 0.03], now: 0.1)       // up and right: the first quarter
        #expect(radial.armed == 0)
        radial.point(local: [-0.04, 0.001], now: 0.2)     // left: the last quarter
        #expect(radial.armed == 3)
        guard case let .pick(pick) = radial.release(now: 0.3) else {
            Issue.record("expected a pick")
            return
        }
        #expect(pick.entry.id == "w")
        #expect(pick.path == [3])
    }

    @Test func aReleaseAtTheCentreCloses() {
        var radial = menu()
        #expect(radial.release(now: 0) == .close)
        radial.point(local: [0.03, 0.03], now: 0)
        radial.press(path: [], now: 0.1)
        #expect(radial.release(now: 0.1) == .close)
    }

    @Test func aConfirmEntryNeedsItsHold() {
        var radial = menu()
        radial.point(local: [-0.03, -0.03], now: 0)       // down and left: South
        #expect(radial.armed == 2)
        #expect(radial.release(now: 0.2) == .stay)
        #expect(radial.armed == -1)                       // let go early: start over
        radial.press(path: [2], now: 1)
        let confirm = radial.view(now: 1.2).wedges[2].confirm ?? 0
        #expect(abs(confirm - 0.5) < 0.01)
        guard case let .pick(pick) = radial.release(now: 1.5) else {
            Issue.record("expected a pick")
            return
        }
        #expect(pick.entry.id == "s")
    }

    @Test func pushingPastTheRimOpensAnEntryAndPicksAMember() {
        var radial = menu()
        radial.point(local: [0.04, -0.03], now: 0)        // right and down: East
        #expect(radial.armed == 1 && !radial.expanded)
        radial.point(local: [0.07, -0.04], now: 0.1)      // past the rim
        #expect(radial.expanded)
        let view = radial.view(now: 0.1)
        #expect(view.wedges.count == 6)
        #expect(view.wedges.map(\.target) == [1, 2, 3, 4, 5, 6])
        // Point at the second member's wedge.
        let second = view.wedges[5]
        radial.point(local: second.center, now: 0.2)
        #expect(radial.member == 1)
        #expect(radial.hit(local: second.center) == [1, 1])
        guard case let .pick(pick) = radial.release(now: 0.3) else {
            Issue.record("expected a pick")
            return
        }
        #expect(pick.entry.id == "e2")
        #expect(pick.path == [1, 1])
    }

    @Test func aPressOnAnEntryWithMembersOpensItAndStays() {
        var radial = menu()
        radial.press(path: [1], now: 0)
        #expect(radial.expanded)
        #expect(radial.release(now: 0) == .stay)
        #expect(radial.expanded)
        radial.press(path: [1, 0], now: 0.5)
        guard case let .pick(pick) = radial.release(now: 0.5) else {
            Issue.record("expected a pick")
            return
        }
        #expect(pick.entry.id == "e1")
    }

    @Test func aStickKeepsItsWedgeWhenItSpringsBack() {
        var radial = menu()
        radial.stick([0.9, 0.3], now: 0)
        #expect(radial.armed == 0)
        radial.stick([0, 0], now: 0.1)
        #expect(radial.armed == 0)
    }

    @Test func hitFindsTheCentreTheWedgesAndNothingOutside() {
        let radial = menu()
        #expect(radial.hit(local: [0, 0.005]) == [])
        #expect(radial.hit(local: [0.03, 0.03]) == [0])
        #expect(radial.hit(local: [0.2, 0]) == nil)
    }

    @Test func aSleeveTileOpensTheMenuAndAFingerPicksFromIt() throws {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        sleeve.tap("wheel", now: 0.4)
        #expect(sleeve.takeEvents().map(\.kind) == [.radialOpened("tools")])
        let open = run(&sleeve, arm: makeArm(), from: 0.4, seconds: 0.1)
        let view = try #require(open.radial)
        // The wheel floats off the tiles, and the tiles under it are not pressable.
        sleeve.tap("a", now: 0.5)
        #expect(sleeve.takeEvents().isEmpty)
        func tip(_ snapshot: RAVESleeveSnapshot, height: Float) -> SIMD3<Float>? {
            guard let radial = snapshot.radial else { return nil }
            let c = view.wedges[3].center
            let p = radial.transform * SIMD4(c.x, c.y, height, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        run(&sleeve, arm: makeArm(), from: 0.5, seconds: 0.1) { tip($0, height: 0.02) }
        run(&sleeve, arm: makeArm(), from: 0.6, seconds: 0.1) { tip($0, height: 0) }
        let lifted = run(&sleeve, arm: makeArm(), from: 0.7, seconds: 0.1) { tip($0, height: 0.03) }
        let events = sleeve.takeEvents()
        #expect(events.count == 1)
        #expect(events.first?.action == RAVESleeveAction("tool.w"))
        #expect(events.first?.source == .touch)
        #expect(lifted.radial == nil)
    }

    @Test func theMenuClosesWhenItsFaceTurnsAway() {
        var sleeve = RAVESleeve(layout: deck())
        run(&sleeve, arm: makeArm(), from: 0, seconds: 0.4)
        sleeve.tap("wheel", now: 0.4)
        _ = sleeve.takeEvents()
        let turned = run(&sleeve, arm: makeArm(back: [0, -1, 0]), from: 0.4, seconds: 1)
        #expect(turned.radial == nil)
        #expect(sleeve.takeEvents().map(\.kind) == [.radialClosed])
    }
}
