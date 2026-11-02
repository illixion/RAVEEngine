import Foundation
import Testing
import simd
@testable import RAVEInput

private typealias Entry = RAVERadialEntry<String>

private func entries(_ names: String...) -> [Entry] {
    names.map { Entry(action: $0, label: $0.uppercased()) }
}

private let right = SIMD3<Float>(1, 0, 0)
private let up = SIMD3<Float>(0, 1, 0)

/// A point `radius` out, `turns` clockwise from 12 o'clock.
private func offset(turns: Float, radius: Float) -> SIMD3<Float> {
    let angle = turns * 2 * .pi
    return SIMD3(sinf(angle) * radius, cosf(angle) * radius, 0)
}

/// The middle of a sector, `radius` out. Aiming at a middle (never a boundary) keeps the
/// tests off floating-point edges.
private func center(_ sector: Int, of count: Int = 4, radius: Float) -> SIMD3<Float> {
    offset(turns: RAVERadial.sectorCenterTurns(sector, count: count), radius: radius)
}

private func stick(_ sector: Int, of count: Int = 4) -> SIMD2<Float> {
    let p = center(sector, of: count, radius: 0.9)
    return SIMD2(p.x, p.y)
}

@Suite("Radial geometry")
struct RAVERadialGeometryTests {

    @Test("Turns run clockwise from 12 o'clock")
    func turnsClockwise() {
        #expect(abs(RAVERadial.turns(dx: 0, dy: 1) - 0) < 1e-6)
        #expect(abs(RAVERadial.turns(dx: 1, dy: 0) - 0.25) < 1e-6)
        #expect(abs(RAVERadial.turns(dx: 0, dy: -1) - 0.5) < 1e-6)
        #expect(abs(RAVERadial.turns(dx: -1, dy: 0) - 0.75) < 1e-6)
    }

    @Test("Inside the deadzone nothing is armed")
    func deadzone() {
        #expect(RAVERadial.sector(dx: 0.01, dy: 0.01, count: 4, deadzone: 0.04) == -1)
        #expect(RAVERadial.sector(dx: 0, dy: 0.1, count: 0, deadzone: 0.04) == -1)
    }

    @Test("Four sectors: up, right, down, left")
    func fourSectors() {
        // Sector 0 spans 0…0.25 turns clockwise from 12, so aim at each middle.
        func at(_ index: Int) -> Int {
            let turns = RAVERadial.sectorCenterTurns(index, count: 4) * 2 * .pi
            return RAVERadial.sector(dx: sinf(turns) * 0.1, dy: cosf(turns) * 0.1, count: 4, deadzone: 0.04)
        }
        #expect((0..<4).map(at) == [0, 1, 2, 3])
    }

    @Test("An armed sector stays armed just past its edge, and changes well past it")
    func stickiness() {
        // Four sectors; sector 0's edge with sector 1 is at 0.25 turns (3 o'clock).
        let past = (0.25 + 0.05 / 4) * 2 * Float.pi          // 5% of a sector into sector 1
        let dx = sinf(past) * 0.1, dy = cosf(past) * 0.1
        #expect(RAVERadial.sector(dx: dx, dy: dy, count: 4, deadzone: 0.04, current: -1) == 1)
        #expect(RAVERadial.sector(dx: dx, dy: dy, count: 4, deadzone: 0.04, current: 0) == 0)
        let far = (0.25 + 0.5 / 4) * 2 * Float.pi            // half a sector in
        #expect(RAVERadial.sector(dx: sinf(far) * 0.1, dy: cosf(far) * 0.1, count: 4,
                                  deadzone: 0.04, current: 0) == 1)
    }

    @Test("Stickiness wraps around 12 o'clock")
    func stickinessWraps() {
        // Last sector of four, just past 12 o'clock into sector 0, sticky to sector 3.
        let turns = 0.02 * 2 * Float.pi
        #expect(RAVERadial.sector(dx: sinf(turns) * 0.1, dy: cosf(turns) * 0.1, count: 4,
                                  deadzone: 0.04, current: 3) == 3)
    }

    @Test("A member arc is centred on its entry and never narrower than the minimum")
    func memberArc() {
        let wide = RAVERadial.memberArc(entry: 1, count: 4, items: 2)
        #expect(abs(wide.item - 0.125) < 1e-6)
        #expect(abs(wide.start + wide.item - RAVERadial.sectorCenterTurns(1, count: 4)) < 1e-6)
        let narrow = RAVERadial.memberArc(entry: 0, count: 12, items: 4)
        #expect(narrow.item == RAVERadial.minMemberTurns)
    }

    @Test("The member under an offset is clamped to the arc's ends")
    func memberClamps() {
        // Entry 1 of 4 is centred at 0.375 turns; its two members cover 0.25–0.375 and 0.375–0.5.
        func pick(_ turns: Float, items: Int = 2) -> Int {
            let p = offset(turns: turns, radius: 0.1)
            return RAVERadial.member(dx: p.x, dy: p.y, entry: 1, count: 4, items: items)
        }
        #expect(pick(0.30) == 0)
        #expect(pick(0.45) == 1)
        #expect(pick(0.10) == 0)      // overshoot past the start keeps the first
        #expect(pick(0.60) == 1)      // overshoot past the end keeps the last
        #expect(pick(0.30, items: 0) == -1)
    }

    @Test("A confirm hold fills over time and gates the commit")
    func confirmHold() throws {
        var list = entries("a", "b")
        list[1].confirmSeconds = 0.6
        #expect(RAVERadial.confirmProgress(list, selected: 0, armedAt: 0, now: 5) == nil)
        #expect(RAVERadial.confirmProgress(list, selected: -1, armedAt: 0, now: 5) == nil)
        let half = try #require(RAVERadial.confirmProgress(list, selected: 1, armedAt: 10, now: 10.3))
        #expect(abs(half - 0.5) < 1e-5)
        #expect(RAVERadial.commits(list, selected: 1, armedAt: 10, now: 10.3) == nil)
        #expect(RAVERadial.commits(list, selected: 1, armedAt: 10, now: 10.7)?.action == "b")
        #expect(RAVERadial.commits(list, selected: 0, armedAt: 10, now: 10)?.action == "a")
        #expect(RAVERadial.commits(list, selected: -1, armedAt: 10, now: 20) == nil)
    }
}

@Suite("Radial hand menu")
struct RAVERadialHandMenuTests {
    private let tuning = RAVERadialHandMenu<String>.Tuning()
    private let origin = SIMD3<Float>(0.2, 1.2, -0.4)

    /// A closed pinch (all tips at the thumb), middle finger not clenched.
    private func pinched(_ menu: inout RAVERadialHandMenu<String>, at grip: SIMD3<Float>, now: Double,
                         list: [Entry]? = nil) -> Entry? {
        menu.update(live: true, spread: 0.03, middleCurl: 0.08, blocked: false, grip: grip,
                    right: right, up: up, now: now, tuning: tuning) { list ?? entries("a", "b", "c", "d") }
    }

    private func released(_ menu: inout RAVERadialHandMenu<String>, at grip: SIMD3<Float>, now: Double) -> Entry? {
        menu.update(live: true, spread: 0.12, middleCurl: 0.08, blocked: false, grip: grip,
                    right: right, up: up, now: now, tuning: tuning) { entries("a", "b", "c", "d") }
    }

    @Test("Pinching opens it where the hand is, with nothing armed")
    func opens() {
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0)
        #expect(menu.isOpen)
        #expect(menu.anchor == origin)
        #expect(menu.selected == -1)
        #expect(menu.entries.count == 4)
    }

    @Test("A clenched fist, an open hand and a blocked hand do not open it")
    func gates() {
        var fist = RAVERadialHandMenu<String>()
        _ = fist.update(live: true, spread: 0.03, middleCurl: 0.02, blocked: false, grip: origin,
                        right: right, up: up, now: 0, tuning: tuning) { entries("a") }
        #expect(!fist.isOpen)

        var open = RAVERadialHandMenu<String>()
        _ = open.update(live: true, spread: 0.12, middleCurl: 0.08, blocked: false, grip: origin,
                        right: right, up: up, now: 0, tuning: tuning) { entries("a") }
        #expect(!open.isOpen)

        var blocked = RAVERadialHandMenu<String>()
        _ = blocked.update(live: true, spread: 0.03, middleCurl: 0.08, blocked: true, grip: origin,
                           right: right, up: up, now: 0, tuning: tuning) { entries("a") }
        #expect(!blocked.isOpen)
    }

    @Test("An empty list keeps it closed")
    func emptyStaysClosed() {
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0, list: [])
        #expect(!menu.isOpen)
    }

    @Test("Moving toward a sector arms it, and releasing picks it")
    func picks() {
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0)
        _ = pinched(&menu, at: origin + center(1, radius: 0.08), now: 0.1)      // right → sector 1
        #expect(menu.selected == 1)
        let picked = released(&menu, at: origin + center(1, radius: 0.08), now: 0.2)
        #expect(picked?.action == "b")
        #expect(!menu.isOpen)
    }

    @Test("Releasing inside the deadzone picks nothing")
    func deadzoneCancels() {
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0)
        _ = pinched(&menu, at: origin + center(1, radius: 0.01), now: 0.1)
        #expect(released(&menu, at: origin, now: 0.2) == nil)
        #expect(!menu.isOpen)
    }

    @Test("Losing the hand or the gesture cancels without a pick")
    func lossCancels() {
        var lostHand = RAVERadialHandMenu<String>()
        _ = pinched(&lostHand, at: origin, now: 0)
        _ = pinched(&lostHand, at: origin + center(1, radius: 0.08), now: 0.1)
        #expect(lostHand.update(sample: nil, live: true, blocked: false, grip: origin, right: right, up: up,
                                now: 0.2, tuning: tuning, makeEntries: { entries("a") }) == nil)
        #expect(!lostHand.isOpen)

        var gestureOff = RAVERadialHandMenu<String>()
        _ = pinched(&gestureOff, at: origin, now: 0)
        #expect(gestureOff.update(live: false, spread: 0.03, middleCurl: 0.08, blocked: false, grip: origin,
                                  right: right, up: up, now: 0.1, tuning: tuning,
                                  makeEntries: { entries("a") }) == nil)
        #expect(!gestureOff.isOpen)
    }

    @Test("A risky entry commits only after its confirm hold")
    func confirmHoldGatesPick() {
        var list = entries("a", "b", "c", "d")
        list[1].confirmSeconds = 0.6
        var early = RAVERadialHandMenu<String>()
        _ = pinched(&early, at: origin, now: 0, list: list)
        _ = pinched(&early, at: origin + center(1, radius: 0.08), now: 0.1, list: list)
        let progress = early.confirmProgress(now: 0.4)
        #expect(progress != nil && progress! > 0.4 && progress! < 0.6)
        #expect(released(&early, at: origin + center(1, radius: 0.08), now: 0.4) == nil)

        var held = RAVERadialHandMenu<String>()
        _ = pinched(&held, at: origin, now: 0, list: list)
        _ = pinched(&held, at: origin + center(1, radius: 0.08), now: 0.1, list: list)
        #expect(released(&held, at: origin + center(1, radius: 0.08), now: 0.8)?.action == "b")
    }

    @Test("Pushing past the rim opens a multi-member entry; releasing picks that member")
    func membersOpenAndPick() {
        var list = entries("a", "b", "c", "d")
        list[1].members = entries("b1", "b2")
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0, list: list)
        _ = pinched(&menu, at: origin + center(1, radius: 0.08), now: 0.1, list: list)
        #expect(!menu.expanded)
        // Out past the expand radius, on the second member's part of the arc (0.45 turns).
        let onSecond = origin + offset(turns: 0.45, radius: 0.14)
        _ = pinched(&menu, at: onSecond, now: 0.2, list: list)
        #expect(menu.expanded)
        #expect(menu.memberSelected == 1)
        let view = menu.view(right: right, up: up, now: 0.2)
        #expect(view?.expansion == .init(entry: 1, selected: 1))
        let picked = released(&menu, at: onSecond, now: 0.3)
        #expect(picked?.action == "b2")
    }

    @Test("Coming back inside the rim folds the arc")
    func collapses() {
        var list = entries("a", "b", "c", "d")
        list[1].members = entries("b1", "b2")
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0, list: list)
        _ = pinched(&menu, at: origin + center(1, radius: 0.08), now: 0.1, list: list)
        _ = pinched(&menu, at: origin + center(1, radius: 0.14), now: 0.2, list: list)
        #expect(menu.expanded)
        _ = pinched(&menu, at: origin + center(1, radius: 0.07), now: 0.3, list: list)
        #expect(!menu.expanded)
        #expect(menu.memberSelected == -1)
        #expect(menu.selected == 1)
    }

    @Test("An entry with a single member never opens")
    func singleMemberDoesNotOpen() {
        var list = entries("a", "b", "c", "d")
        list[1].members = entries("b1")
        var menu = RAVERadialHandMenu<String>()
        _ = pinched(&menu, at: origin, now: 0, list: list)
        _ = pinched(&menu, at: origin + center(1, radius: 0.08), now: 0.1, list: list)
        _ = pinched(&menu, at: origin + center(1, radius: 0.16), now: 0.2, list: list)
        #expect(!menu.expanded)
    }
}

@Suite("Radial stick menu")
struct RAVERadialStickMenuTests {
    private func update(_ menu: inout RAVERadialStickMenu<String>, held: Bool, stick: SIMD2<Float> = .zero,
                        now: Double, list: [Entry]? = nil) -> Entry? {
        menu.update(held: held, stick: stick, now: now) { list ?? entries("a", "b", "c", "d") }
    }

    @Test("Pressing the button opens it, with nothing armed")
    func opens() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0)
        #expect(menu.isOpen)
        #expect(menu.selected == -1)
    }

    @Test("Pointing the stick arms a sector and releasing picks it")
    func picks() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0)
        _ = update(&menu, held: true, stick: stick(1), now: 0.1)      // right → sector 1
        #expect(menu.selected == 1)
        #expect(update(&menu, held: false, now: 0.2)?.action == "b")
        #expect(!menu.isOpen)
    }

    @Test("Flick and release: the sector stays armed when the stick springs back")
    func flickAndRelease() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0)
        _ = update(&menu, held: true, stick: stick(2), now: 0.1)     // lower left → sector 2
        _ = update(&menu, held: true, stick: .zero, now: 0.15)
        #expect(menu.selected == 2)
        #expect(update(&menu, held: false, now: 0.2)?.action == "c")
    }

    @Test("Releasing with nothing armed cancels")
    func nothingArmed() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0)
        #expect(update(&menu, held: false, now: 0.2) == nil)
        #expect(!menu.isOpen)
    }

    @Test("A weak stick push inside the deadzone arms nothing")
    func weakStick() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0)
        _ = update(&menu, held: true, stick: SIMD2(0.3, 0), now: 0.1)
        #expect(menu.selected == -1)
    }

    @Test("A risky entry waits out its confirm hold")
    func confirmHold() {
        var list = entries("a", "b", "c", "d")
        list[1].confirmSeconds = 0.6
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0, list: list)
        _ = update(&menu, held: true, stick: stick(1), now: 0.1, list: list)
        #expect(menu.confirmProgress(now: 0.4) != nil)
        #expect(update(&menu, held: false, now: 0.4, list: list) == nil)

        var held = RAVERadialStickMenu<String>()
        _ = update(&held, held: true, now: 0, list: list)
        _ = update(&held, held: true, stick: stick(1), now: 0.1, list: list)
        #expect(update(&held, held: false, now: 0.8, list: list)?.action == "b")
    }

    @Test("A cancelled menu stays closed until the button is pressed again")
    func cancelStaysClosed() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0)
        menu.cancel()
        _ = update(&menu, held: true, stick: stick(1), now: 0.1)   // still held
        #expect(!menu.isOpen)
        _ = update(&menu, held: false, now: 0.2)
        _ = update(&menu, held: true, now: 0.3)
        #expect(menu.isOpen)
    }

    @Test("An empty list keeps it closed, and the view is nil while closed")
    func emptyAndView() {
        var menu = RAVERadialStickMenu<String>()
        _ = update(&menu, held: true, now: 0, list: [])
        #expect(!menu.isOpen)
        #expect(menu.view(center: .zero, right: right, up: up, now: 0) == nil)
        var open = RAVERadialStickMenu<String>()
        _ = update(&open, held: true, now: 0)
        #expect(open.view(center: SIMD3(0, 0, -1), right: right, up: up, now: 0)?.entries.count == 4)
    }
}
