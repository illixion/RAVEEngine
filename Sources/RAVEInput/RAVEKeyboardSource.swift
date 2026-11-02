/*
 RAVE Engine — a hardware keyboard through GameController, as plain key events.

 `GCKeyboard` is how a hardware keyboard reaches a visionOS app that draws into
 an immersive space (UIKit key events need a focused view, and a full immersive
 space has none). It reports `GCKeyCode`s; most consumers want one of two other
 things: the key as a character (a text field, a console) or "is the keyboard
 in use right now".

 `RAVEKeyboardSource` attaches to whichever keyboards are connected, fans each
 key change out as `(GCKeyCode, pressed)`, and tracks what is held and when a
 key last moved. `RAVEKeyCharacters` is the US-layout ASCII table that two apps
 both wrote out by hand. What a key *means* to a game — an engine's own key
 numbers, a snap-turn on Z and X — stays in the app, which reads the events.

 **Why `isInUse` exists.** Hands resting on a keyboard read as pinches, fists
 and pokes to a hand tracker (a phantom use, a crouch). A consumer that also
 reads hands stands them down while the keyboard is in use: a key is held, or
 one moved within `idleSeconds`.

 **Threading.** GameController delivers key changes on its handler queue (the
 main queue by default). The held state and the clock are guarded by a lock, so
 `isInUse`, `isDown` and `shiftHeld` can be read from a render thread. The
 handlers you install run on the delivering queue.

 Needs `.handlesGameControllerEvents` / a window under the pointer on visionOS
 to receive anything; see the mouse catcher notes in `RAVEMouseCatcher.swift`.
 */

import Foundation
import GameController

/// US-layout ASCII for a key: unshifted for a game's key numbers, shifted for
/// text entry. Pure lookup, so it runs under `swift test`.
public enum RAVEKeyCharacters {
    /// The unshifted printable ASCII value (lowercase letters, digits,
    /// punctuation, space), or nil for a key with no printable form.
    public static func base(for code: GCKeyCode) -> Int? {
        switch code {
        case .keyA: 97; case .keyB: 98; case .keyC: 99; case .keyD: 100
        case .keyE: 101; case .keyF: 102; case .keyG: 103; case .keyH: 104
        case .keyI: 105; case .keyJ: 106; case .keyK: 107; case .keyL: 108
        case .keyM: 109; case .keyN: 110; case .keyO: 111; case .keyP: 112
        case .keyQ: 113; case .keyR: 114; case .keyS: 115; case .keyT: 116
        case .keyU: 117; case .keyV: 118; case .keyW: 119; case .keyX: 120
        case .keyY: 121; case .keyZ: 122
        case .one: 49; case .two: 50; case .three: 51; case .four: 52
        case .five: 53; case .six: 54; case .seven: 55; case .eight: 56
        case .nine: 57; case .zero: 48
        case .spacebar: 32
        case .hyphen: 45; case .equalSign: 61
        case .openBracket: 91; case .closeBracket: 93; case .backslash: 92
        case .semicolon: 59; case .quote: 39; case .graveAccentAndTilde: 96
        case .comma: 44; case .period: 46; case .slash: 47
        default: nil
        }
    }

    /// The character with Shift held, for text entry, or nil if the key has none.
    public static func shifted(for code: GCKeyCode) -> Int? {
        if let base = base(for: code), base >= 97, base <= 122 { return base - 32 }
        switch code {
        case .one: return 33            // !
        case .two: return 64            // @
        case .three: return 35          // #
        case .four: return 36           // $
        case .five: return 37           // %
        case .six: return 94            // ^
        case .seven: return 38          // &
        case .eight: return 42          // *
        case .nine: return 40           // (
        case .zero: return 41           // )
        case .hyphen: return 95         // _
        case .equalSign: return 43      // +
        case .openBracket: return 123   // {
        case .closeBracket: return 125  // }
        case .backslash: return 124     // |
        case .semicolon: return 58      // :
        case .quote: return 34          // "
        case .graveAccentAndTilde: return 126 // ~
        case .comma: return 60          // <
        case .period: return 62         // >
        case .slash: return 63          // ?
        default: return nil
        }
    }

    /// The character a press produces given the Shift state, or nil.
    public static func character(for code: GCKeyCode, shift: Bool) -> Int? {
        shift ? (shifted(for: code) ?? base(for: code)) : base(for: code)
    }
}

/// Attaches to every connected `GCKeyboard` and reports key changes.
public final class RAVEKeyboardSource: @unchecked Sendable {
    /// How long after the last key change the keyboard still counts as in use.
    public static let idleSeconds: TimeInterval = 4

    /// A key changed: its code and whether it is now down. Delivered on
    /// GameController's handler queue. Set before `start()`.
    public var onKey: (@Sendable (GCKeyCode, Bool) -> Void)?
    /// A keyboard connected or disconnected; the flag is whether any is
    /// connected now. Set before `start()`.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var down = Set<GCKeyCode>()
    private var lastKeyTime: TimeInterval = -.infinity
    private var shift = false
    private var observers: [NSObjectProtocol] = []

    /// `clock` is monotonic seconds; the default is the system uptime.
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    deinit { stop() }

    /// True while any keyboard is connected.
    public var isConnected: Bool { GCKeyboard.coalesced != nil }

    /// The keys held right now.
    public var heldKeys: Set<GCKeyCode> {
        lock.lock(); defer { lock.unlock() }
        return down
    }

    public func isDown(_ code: GCKeyCode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return down.contains(code)
    }

    public var shiftHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return shift
    }

    /// A key is held, or one moved within `idleSeconds` of `now`.
    public func isInUse(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !down.isEmpty || now - lastKeyTime < Self.idleSeconds
    }

    /// Forget what is held (the input mode moved away from the keyboard). A key
    /// still physically down stays out of `heldKeys` until it is released and
    /// pressed again, so a stale press is not re-reported.
    public func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        down.removeAll()
        shift = false
    }

    /// Begin listening. Idempotent.
    public func start() {
        guard observers.isEmpty else { return }
        if let keyboard = GCKeyboard.coalesced { attach(keyboard) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) {
            [weak self] note in
            guard let self else { return }
            if let keyboard = note.object as? GCKeyboard { self.attach(keyboard) }
            self.onConnectionChange?(true)
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            if GCKeyboard.coalesced == nil { self.releaseAll() }
            self.onConnectionChange?(GCKeyboard.coalesced != nil)
        })
    }

    public func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func attach(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] _, _, code, pressed in
            guard let self else { return }
            self.record(code, pressed: pressed)
            self.onKey?(code, pressed)
        }
    }

    /// Fold one key change into the held state. Split out so it can be driven
    /// without a connected keyboard.
    func record(_ code: GCKeyCode, pressed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if pressed { down.insert(code) } else { down.remove(code) }
        if code == .leftShift || code == .rightShift {
            shift = down.contains(.leftShift) || down.contains(.rightShift)
        }
        lastKeyTime = clock()
    }
}
