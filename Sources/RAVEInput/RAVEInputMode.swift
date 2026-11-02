/*
 RAVE Engine — which input device owns the player right now, and what the
 others let go of when it changes.

 A game that takes hands, a keyboard and mouse, and a gamepad has to pick one
 owner at a time. With a keyboard and mouse or a gamepad it plays like the
 flat game; with hands, the tracked hands drive everything. Mixing them is how
 you get a phantom pinch while your hands rest on the keys.

 **Auto picks the last device used.** A key, a mouse move or click, or a
 gamepad button or stick switches at once. Hands come back on a deliberate
 hand action (a look-and-pinch) once no device has been touched for a moment,
 or when the device in use disconnects. Resting idle never flips the mode, so
 a keyboard player who stops to look around keeps their setup.

 **A handoff releases everything the old owner held.** Found on device: moving
 with a hand stick, then picking up a controller, left the player walking
 forward for a while. `RAVEInputHandoff` says what to let go of, and
 `RAVEHeldCommands` remembers which named commands a device pressed so they
 can all be released.

 Pure logic with injected time, no frameworks. `RAVEInputModeArbiter` is the
 lock-guarded holder for the one place threads meet (input threads write, the
 render thread reads).
 */

import Foundation

public enum RAVEInputMode: String, Sendable, CaseIterable {
    case hands, keyboardMouse, gamepad

    public var label: String {
        switch self {
        case .hands: "hands"
        case .keyboardMouse: "keyboard+mouse"
        case .gamepad: "gamepad"
        }
    }
}

/// The player's override: pin one mode, or let the arbiter pick.
public enum RAVEInputModeSetting: String, Sendable, CaseIterable, Identifiable {
    case auto, hands, keyboardMouse, gamepad

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .hands: "Hands"
        case .keyboardMouse: "Keyboard + mouse"
        case .gamepad: "Gamepad"
        }
    }

    /// The mode this setting pins, or nil for Auto.
    public var forced: RAVEInputMode? {
        switch self {
        case .auto: nil
        case .hands: .hands
        case .keyboardMouse: .keyboardMouse
        case .gamepad: .gamepad
        }
    }
}

/// The auto-selection rule, free of clocks and globals.
public struct RAVEInputModeSelector: Sendable, Equatable {
    /// How long after the last keyboard, mouse or gamepad input a pinch still
    /// counts as a slip rather than a request for hands.
    public static let handsReclaimSeconds: TimeInterval = 1.0

    public private(set) var mode: RAVEInputMode = .hands
    public private(set) var lastDeviceTime: TimeInterval = -.infinity

    public init() {}

    /// A device was used. Hands count as a deliberate action; see `handsUsed`.
    public mutating func deviceUsed(_ device: RAVEInputMode, now: TimeInterval) {
        guard device != .hands else { return handsUsed(now: now) }
        mode = device
        lastDeviceTime = now
    }

    /// A deliberate hand action. Takes hands back unless a device was used
    /// within the last `handsReclaimSeconds`.
    public mutating func handsUsed(now: TimeInterval) {
        if now - lastDeviceTime >= Self.handsReclaimSeconds { mode = .hands }
    }

    /// The last device of a kind went away: back to hands if it was in use.
    public mutating func deviceGone(_ device: RAVEInputMode) {
        if mode == device { mode = .hands }
    }
}

/// What a change of input mode lets go of. Every device that isn't the new
/// owner releases whatever it holds.
public struct RAVEInputHandoff: Sendable, Equatable {
    public var releaseHands = false
    public var releaseGamepad = false
    public var releaseKeyboardMouse = false
    /// Zero the analog movement axes outright, whoever wrote them last.
    public var zeroAxes = false
    /// Send a bare "stop moving" for each movement direction, so a keyboard key
    /// whose release went to another window cannot keep the player walking.
    /// Not when the keyboard itself takes over: the key that switched the mode
    /// may be one of them. Which commands that means is the game's to say.
    public var unstickKeyboardMoves = false

    public init(releaseHands: Bool = false, releaseGamepad: Bool = false,
                releaseKeyboardMouse: Bool = false, zeroAxes: Bool = false,
                unstickKeyboardMoves: Bool = false) {
        self.releaseHands = releaseHands
        self.releaseGamepad = releaseGamepad
        self.releaseKeyboardMouse = releaseKeyboardMouse
        self.zeroAxes = zeroAxes
        self.unstickKeyboardMoves = unstickKeyboardMoves
    }

    /// The handoff from `old` to `new`, or nil when nothing changed (or on the
    /// very first frame, when nothing was held yet).
    public static func between(_ old: RAVEInputMode?, _ new: RAVEInputMode) -> RAVEInputHandoff? {
        guard let old, old != new else { return nil }
        return RAVEInputHandoff(
            releaseHands: new != .hands,
            releaseGamepad: new != .gamepad,
            releaseKeyboardMouse: new != .keyboardMouse,
            zeroAxes: true,
            unstickKeyboardMoves: new != .keyboardMouse)
    }
}

/// The named commands one device holds, so a handoff can let go of all of them.
///
/// Feed it each button's level every poll; it answers with the command to send
/// on a change. After `releaseAll()`, a button still physically down stays
/// quiet until it is let go — the new owner has the controls, and a held
/// trigger shouldn't press again the moment it switches back.
public struct RAVEHeldCommands: Sendable, Equatable {
    public private(set) var held: Set<String> = []
    private var latched: Set<String> = []

    public init() {}

    /// `"+name"` on press, `"-name"` on release, nil otherwise.
    public mutating func update(_ name: String, pressed: Bool) -> String? {
        if latched.contains(name) {
            if !pressed { latched.remove(name) }
            return nil
        }
        if pressed, !held.contains(name) { held.insert(name); return "+" + name }
        if !pressed, held.contains(name) { held.remove(name); return "-" + name }
        return nil
    }

    /// `"-name"` for everything held, in a stable order.
    public mutating func releaseAll() -> [String] {
        let out = held.sorted().map { "-" + $0 }
        latched.formUnion(held)
        held.removeAll()
        return out
    }
}

/// The one shared owner of the mode: input threads report devices, the render
/// thread reads `current`. Guarded by a lock; the selector itself stays pure.
public final class RAVEInputModeArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var selector = RAVEInputModeSelector()
    private var setting: RAVEInputModeSetting = .auto
    private var lastUsed: [RAVEInputMode: TimeInterval] = [:]

    public init() {}

    /// The mode in force: the override, else the automatic pick.
    public var current: RAVEInputMode {
        lock.lock(); defer { lock.unlock() }
        return setting.forced ?? selector.mode
    }

    public var override: RAVEInputModeSetting {
        get { lock.lock(); defer { lock.unlock() }; return setting }
        set { lock.lock(); defer { lock.unlock() }; setting = newValue }
    }

    public func deviceUsed(_ device: RAVEInputMode, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        selector.deviceUsed(device, now: now)
        lastUsed[device] = now
    }

    public func deviceGone(_ device: RAVEInputMode) {
        lock.lock(); defer { lock.unlock() }
        selector.deviceGone(device)
    }

    /// A diagnostics line: the mode, whether it is set or automatic, and when
    /// each device last spoke.
    public func diagnosticLine(now: TimeInterval) -> String {
        lock.lock(); defer { lock.unlock() }
        func ago(_ mode: RAVEInputMode) -> String {
            guard let time = lastUsed[mode] else { return "—" }
            return String(format: "%.0fs", max(now - time, 0))
        }
        let mode = setting.forced ?? selector.mode
        return "input mode: \(mode.label) (\(setting == .auto ? "auto" : "set"))"
            + "  last kb/mouse \(ago(.keyboardMouse)) pad \(ago(.gamepad)) hands \(ago(.hands))"
    }
}
