import Foundation
import GameController
import Testing
@testable import RAVEInput

@Suite("Keyboard characters")
struct RAVEKeyCharactersTests {

    @Test("Letters map to lowercase ASCII, and shift gives uppercase")
    func letters() {
        #expect(RAVEKeyCharacters.base(for: .keyA) == 97)
        #expect(RAVEKeyCharacters.base(for: .keyZ) == 122)
        #expect(RAVEKeyCharacters.shifted(for: .keyA) == 65)
        #expect(RAVEKeyCharacters.shifted(for: .keyZ) == 90)
    }

    @Test("Every letter's shifted form is its lowercase minus 32")
    func letterRange() {
        let letters: [GCKeyCode] = [
            .keyA, .keyB, .keyC, .keyD, .keyE, .keyF, .keyG, .keyH, .keyI, .keyJ, .keyK, .keyL, .keyM,
            .keyN, .keyO, .keyP, .keyQ, .keyR, .keyS, .keyT, .keyU, .keyV, .keyW, .keyX, .keyY, .keyZ,
        ]
        for (i, code) in letters.enumerated() {
            #expect(RAVEKeyCharacters.base(for: code) == 97 + i)
            #expect(RAVEKeyCharacters.shifted(for: code) == 65 + i)
        }
    }

    @Test("Digits, space and punctuation use US-layout ASCII")
    func digitsAndPunctuation() {
        #expect(RAVEKeyCharacters.base(for: .zero) == 48)
        #expect(RAVEKeyCharacters.base(for: .nine) == 57)
        #expect(RAVEKeyCharacters.base(for: .spacebar) == 32)
        #expect(RAVEKeyCharacters.base(for: .slash) == 47)
        #expect(RAVEKeyCharacters.shifted(for: .one) == 33)       // !
        #expect(RAVEKeyCharacters.shifted(for: .two) == 64)       // @
        #expect(RAVEKeyCharacters.shifted(for: .slash) == 63)     // ?
        #expect(RAVEKeyCharacters.shifted(for: .graveAccentAndTilde) == 126)
    }

    @Test("A key with no printable form has no character")
    func nonPrintable() {
        #expect(RAVEKeyCharacters.base(for: .escape) == nil)
        #expect(RAVEKeyCharacters.base(for: .leftShift) == nil)
        #expect(RAVEKeyCharacters.base(for: .F1) == nil)
        #expect(RAVEKeyCharacters.shifted(for: .upArrow) == nil)
    }

    @Test("The character for a press follows the shift state")
    func characterFollowsShift() {
        #expect(RAVEKeyCharacters.character(for: .keyQ, shift: false) == 113)
        #expect(RAVEKeyCharacters.character(for: .keyQ, shift: true) == 81)
        #expect(RAVEKeyCharacters.character(for: .spacebar, shift: true) == 32)   // no shifted form: base
        #expect(RAVEKeyCharacters.character(for: .escape, shift: true) == nil)
    }
}

@Suite("Keyboard source")
struct RAVEKeyboardSourceTests {

    /// A source driven by hand, with a clock the test moves.
    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    private func make() -> (RAVEKeyboardSource, Clock) {
        let clock = Clock()
        return (RAVEKeyboardSource(clock: { clock.now }), clock)
    }

    @Test("Held keys come and go with presses and releases")
    func heldKeys() {
        let (source, _) = make()
        source.record(.keyW, pressed: true)
        source.record(.keyA, pressed: true)
        #expect(source.isDown(.keyW))
        #expect(source.heldKeys == [.keyW, .keyA])
        source.record(.keyW, pressed: false)
        #expect(!source.isDown(.keyW))
        #expect(source.heldKeys == [.keyA])
    }

    @Test("Shift is held while either shift key is")
    func shiftTracking() {
        let (source, _) = make()
        source.record(.leftShift, pressed: true)
        source.record(.rightShift, pressed: true)
        #expect(source.shiftHeld)
        source.record(.leftShift, pressed: false)
        #expect(source.shiftHeld)          // the other is still down
        source.record(.rightShift, pressed: false)
        #expect(!source.shiftHeld)
    }

    @Test("The keyboard is in use while a key is held, and for a few seconds after")
    func inUse() {
        let (source, clock) = make()
        #expect(!source.isInUse(now: clock.now))
        source.record(.keyW, pressed: true)
        clock.now += 60
        #expect(source.isInUse(now: clock.now))        // still held, however long
        source.record(.keyW, pressed: false)
        clock.now += RAVEKeyboardSource.idleSeconds - 0.5
        #expect(source.isInUse(now: clock.now))
        clock.now += 1
        #expect(!source.isInUse(now: clock.now))
    }

    @Test("Releasing everything forgets held keys and shift")
    func releaseAll() {
        let (source, _) = make()
        source.record(.keyW, pressed: true)
        source.record(.leftShift, pressed: true)
        source.releaseAll()
        #expect(source.heldKeys.isEmpty)
        #expect(!source.shiftHeld)
    }

    @Test("Stopping an unstarted source is harmless, and start is idempotent")
    func lifecycle() {
        let (source, _) = make()
        source.stop()
        source.start()
        source.start()
        source.stop()
    }
}
