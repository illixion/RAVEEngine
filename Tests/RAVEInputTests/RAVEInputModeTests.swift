import Foundation
import Testing
@testable import RAVEInput

@Suite("Input mode")
struct RAVEInputModeTests {

    @Test("Starts with hands")
    func startsWithHands() {
        #expect(RAVEInputModeSelector().mode == .hands)
    }

    @Test("A device used takes the mode at once")
    func deviceTakesOver() {
        var selector = RAVEInputModeSelector()
        selector.deviceUsed(.keyboardMouse, now: 10)
        #expect(selector.mode == .keyboardMouse)
        selector.deviceUsed(.gamepad, now: 11)
        #expect(selector.mode == .gamepad)
    }

    @Test("A pinch right after a key is a slip, not a request for hands")
    func slipDoesNotFlip() {
        var selector = RAVEInputModeSelector()
        selector.deviceUsed(.keyboardMouse, now: 10)
        selector.handsUsed(now: 10.5)
        #expect(selector.mode == .keyboardMouse)
    }

    @Test("A deliberate hand action after the reclaim time takes hands back")
    func handsReclaim() {
        var selector = RAVEInputModeSelector()
        selector.deviceUsed(.gamepad, now: 10)
        selector.handsUsed(now: 10 + RAVEInputModeSelector.handsReclaimSeconds)
        #expect(selector.mode == .hands)
    }

    @Test("Resting idle never flips the mode")
    func idleKeepsMode() {
        var selector = RAVEInputModeSelector()
        selector.deviceUsed(.keyboardMouse, now: 10)
        // Nothing reported for a long time: the mode stays.
        #expect(selector.mode == .keyboardMouse)
    }

    @Test("The device in use going away hands control back; another going away does not")
    func deviceGone() {
        var selector = RAVEInputModeSelector()
        selector.deviceUsed(.gamepad, now: 1)
        selector.deviceGone(.keyboardMouse)
        #expect(selector.mode == .gamepad)
        selector.deviceGone(.gamepad)
        #expect(selector.mode == .hands)
    }

    @Test("A setting pins its mode; Auto pins none")
    func settingForces() {
        #expect(RAVEInputModeSetting.auto.forced == nil)
        #expect(RAVEInputModeSetting.hands.forced == .hands)
        #expect(RAVEInputModeSetting.keyboardMouse.forced == .keyboardMouse)
        #expect(RAVEInputModeSetting.gamepad.forced == .gamepad)
    }

    // MARK: Handoff

    @Test("No handoff on the first frame or when nothing changed")
    func noHandoff() {
        #expect(RAVEInputHandoff.between(nil, .hands) == nil)
        #expect(RAVEInputHandoff.between(.gamepad, .gamepad) == nil)
    }

    @Test("Everything but the new owner lets go, and the axes zero")
    func handoffReleasesOthers() throws {
        let toPad = try #require(RAVEInputHandoff.between(.hands, .gamepad))
        #expect(toPad.releaseHands && toPad.releaseKeyboardMouse && !toPad.releaseGamepad)
        #expect(toPad.zeroAxes)
        #expect(toPad.unstickKeyboardMoves)

        let toHands = try #require(RAVEInputHandoff.between(.keyboardMouse, .hands))
        #expect(!toHands.releaseHands && toHands.releaseGamepad && toHands.releaseKeyboardMouse)
    }

    @Test("The keyboard taking over does not unstick its own movement keys")
    func keyboardTakeoverKeepsItsKeys() throws {
        let toKeys = try #require(RAVEInputHandoff.between(.hands, .keyboardMouse))
        #expect(!toKeys.unstickKeyboardMoves)
        #expect(!toKeys.releaseKeyboardMouse)
    }

    // MARK: Held commands

    @Test("A held command reports its press and its release once each")
    func heldCommandEdges() {
        var held = RAVEHeldCommands()
        #expect(held.update("jump", pressed: false) == nil)
        #expect(held.update("jump", pressed: true) == "+jump")
        #expect(held.update("jump", pressed: true) == nil)
        #expect(held.update("jump", pressed: false) == "-jump")
        #expect(held.update("jump", pressed: false) == nil)
    }

    @Test("Release-all lets go of everything held, in a stable order")
    func releaseAll() {
        var held = RAVEHeldCommands()
        _ = held.update("duck", pressed: true)
        _ = held.update("attack", pressed: true)
        #expect(held.releaseAll() == ["-attack", "-duck"])
        #expect(held.held.isEmpty)
    }

    @Test("A button still down after a release-all stays quiet until it is let go")
    func latchedAfterRelease() {
        var held = RAVEHeldCommands()
        _ = held.update("attack", pressed: true)
        _ = held.releaseAll()
        #expect(held.update("attack", pressed: true) == nil)    // still physically down
        #expect(held.update("attack", pressed: false) == nil)   // the real release is swallowed
        #expect(held.update("attack", pressed: true) == "+attack")
    }

    // MARK: Arbiter

    @Test("The arbiter reports the automatic pick, and an override beats it")
    func arbiterOverride() {
        let arbiter = RAVEInputModeArbiter()
        #expect(arbiter.current == .hands)
        arbiter.deviceUsed(.gamepad, now: 5)
        #expect(arbiter.current == .gamepad)
        arbiter.override = .keyboardMouse
        #expect(arbiter.current == .keyboardMouse)
        arbiter.override = .auto
        #expect(arbiter.current == .gamepad)
        arbiter.deviceGone(.gamepad)
        #expect(arbiter.current == .hands)
    }

    @Test("The diagnostic line names the mode and when each device last spoke")
    func diagnosticLine() {
        let arbiter = RAVEInputModeArbiter()
        arbiter.deviceUsed(.keyboardMouse, now: 100)
        let line = arbiter.diagnosticLine(now: 104)
        #expect(line.contains("keyboard+mouse"))
        #expect(line.contains("(auto)"))
        #expect(line.contains("last kb/mouse 4s"))
        #expect(line.contains("pad —"))
    }
}
