/*
 RAVE Engine — the "mouse catcher" rule: when an app should keep an invisible
 window up so visionOS sends it the mouse at all.

 visionOS routes `GCMouse` (and `GCKeyboard`) by window focus: while the
 pointer is in a full immersive space (a CompositorLayer, or a RealityKit
 space) and not over one of the app's windows, the app gets no mouse events,
 and clicks land in its other windows. No API claims the mouse for an
 immersive space (visionOS 26/27). A window still counts when it draws
 nothing, so the workaround is a large plain window with no glass, no content
 and no system controls, kept in front of the user while a mouse is in use.
 Confirmed on device in LambdaVision (2026-10-07): with it up, GCMouse events
 flowed and the mouse drove the game.

 The window itself is SwiftUI and stays in the app (see CLAUDE.md, "Mouse
 catcher", for the wiring). This file is the framework-free half both
 LambdaVision and Longwave need:

 - `RAVEMouseCatcherRule` — should the catcher be up, and why (for logs).
 - `RAVEEventRate` — events in the last second, for a diagnostics counter.
 - `RAVEMouseCatcherWatch` — notices when the catcher isn't catching: the
   pointer moving over it with GCMouse silent, or a pointer event reaching
   the immersive layer while it's up.

 Value types, no clocks: the caller passes `now` (any monotonic seconds).
 */

import Foundation

/// How the host's input-mode setting stands toward the mouse.
public enum RAVEMouseCatcherPolicy: Sendable, Equatable {
    /// The app picks its input mode from the last device used.
    case automatic
    /// The user forced the keyboard-and-mouse mode.
    case mouseForced
    /// The user forced some other mode (hands, gamepad): no catcher.
    case otherForced
}

public struct RAVEMouseCatcherInputs: Sendable, Equatable {
    /// The app's own on/off switch for the catcher.
    public var enabled: Bool
    /// The immersive scene is up and in a state where the mouse plays it
    /// (LambdaVision: space open, engine in a level, not loading).
    public var sceneActive: Bool
    /// Why host UI driven by gaze-and-pinch needs the view clear right now
    /// (a menu, a console), or nil. The catcher would swallow those pinches.
    public var blockedBy: String?
    public var policy: RAVEMouseCatcherPolicy
    public var mouseConnected: Bool
    /// The host's current input mode is its keyboard-and-mouse one. Keeps the
    /// catcher up for a keyboard alone, which is routed by focus too.
    public var mouseModeActive: Bool

    public init(enabled: Bool, sceneActive: Bool, blockedBy: String? = nil,
                policy: RAVEMouseCatcherPolicy, mouseConnected: Bool, mouseModeActive: Bool) {
        self.enabled = enabled
        self.sceneActive = sceneActive
        self.blockedBy = blockedBy
        self.policy = policy
        self.mouseConnected = mouseConnected
        self.mouseModeActive = mouseModeActive
    }
}

public struct RAVEMouseCatcherDecision: Sendable, Equatable {
    public var wanted: Bool
    /// Short and code-defined: safe to log `.public`.
    public var reason: String
}

public enum RAVEMouseCatcherRule {
    /// Up while the scene is active and nothing needs the view clear, when
    /// the mouse mode is forced, or (automatic) whenever a mouse is connected
    /// or the mouse mode is current.
    ///
    /// Automatic deliberately ignores which mode the last hand action
    /// picked: mouse events are what switch an automatic app back to the
    /// mouse, and they only arrive through the catcher. Taking it down on a
    /// pinch trapped LambdaVision in hands mode (2026-10-07). So the host
    /// must forward pinches that land on the catcher to its hand-input path.
    public static func evaluate(_ i: RAVEMouseCatcherInputs) -> RAVEMouseCatcherDecision {
        guard i.enabled else { return .init(wanted: false, reason: "off") }
        guard i.sceneActive else { return .init(wanted: false, reason: "scene inactive") }
        if let blocker = i.blockedBy { return .init(wanted: false, reason: blocker) }
        switch i.policy {
        case .otherForced:
            return .init(wanted: false, reason: "another input mode forced")
        case .mouseForced:
            return .init(wanted: true, reason: "keyboard+mouse forced")
        case .automatic:
            if i.mouseConnected { return .init(wanted: true, reason: "mouse connected") }
            if i.mouseModeActive { return .init(wanted: true, reason: "keyboard+mouse mode") }
            return .init(wanted: false, reason: "no mouse")
        }
    }
}

/// Events in the last second, in tenth-of-a-second buckets. One owner, no
/// locking (the main queue, where `RAVEMouseSource` delivers).
public struct RAVEEventRate: Sendable, Equatable {
    public static let buckets = 10
    public static let bucketSeconds = 0.1

    private var counts = [Int](repeating: 0, count: RAVEEventRate.buckets)
    private var head: Int?
    /// Every event ever recorded.
    public private(set) var total = 0
    /// When the last event was recorded.
    public private(set) var lastAt: Double?

    public init() {}

    public mutating func record(at now: Double, count: Int = 1) {
        advance(to: now)
        counts[Self.slot(Self.bucket(now))] += count
        total += count
        lastAt = now
    }

    /// Events in the second up to `now`.
    public mutating func lastSecond(at now: Double) -> Int {
        advance(to: now)
        return counts.reduce(0, +)
    }

    private mutating func advance(to now: Double) {
        let b = Self.bucket(now)
        guard let h = head else { head = b; return }
        guard b > h else { return }
        for n in (h + 1)...min(b, h + Self.buckets) { counts[Self.slot(n)] = 0 }
        head = b
    }

    private static func bucket(_ t: Double) -> Int { Int((t / bucketSeconds).rounded(.down)) }
    private static func slot(_ b: Int) -> Int { ((b % buckets) + buckets) % buckets }
}

/// Watches an open catcher for signs it isn't catching. Feed it what the
/// host sees, call `check` a few times a second; it answers with a finding
/// at most once per `repeatSeconds` each.
public struct RAVEMouseCatcherWatch: Sendable, Equatable {
    public enum Finding: String, Sendable, Equatable {
        /// The pointer moves over the catcher (SwiftUI hover reports it) but
        /// GCMouse delivers nothing: the window gets the pointer, the app
        /// doesn't get the mouse.
        case pointerOnCatcherMouseSilent
        /// A pointer event reached the immersive layer while the catcher was
        /// up: the pointer went through it or around it. With a fully clear
        /// window, a fill the eye can't see is the thing to try.
        case pointerPassedCatcher
    }

    /// GCMouse quiet this long while the pointer moves on the catcher.
    public var silenceSeconds: Double
    /// Hover moves needed in that window to call it movement.
    public var minimumHoverMoves: Int
    public var repeatSeconds: Double

    private var hoverMoves: [Double] = []
    private var lastMouseAt: Double?
    private var pointerPassedAt: Double?
    private var lastReported: [Finding: Double] = [:]

    public init(silenceSeconds: Double = 2, minimumHoverMoves: Int = 5, repeatSeconds: Double = 30) {
        self.silenceSeconds = silenceSeconds
        self.minimumHoverMoves = minimumHoverMoves
        self.repeatSeconds = repeatSeconds
    }

    /// The pointer moved over the catcher.
    public mutating func hoverMoved(at now: Double) {
        hoverMoves.append(now)
        hoverMoves.removeAll { now - $0 > silenceSeconds }
    }

    /// Any GCMouse event.
    public mutating func mouseEvent(at now: Double) { lastMouseAt = now }

    /// A pointer spatial event reached the immersive layer.
    public mutating func pointerPassed(at now: Double) { pointerPassedAt = now }

    /// The catcher (re)opened: forget what was seen before.
    public mutating func reset() {
        hoverMoves.removeAll()
        pointerPassedAt = nil
    }

    public mutating func check(now: Double, catcherOpen: Bool) -> Finding? {
        guard catcherOpen else { return nil }
        hoverMoves.removeAll { now - $0 > silenceSeconds }
        if let passed = pointerPassedAt {
            pointerPassedAt = nil
            if now - passed <= silenceSeconds, report(.pointerPassedCatcher, now) { return .pointerPassedCatcher }
        }
        if hoverMoves.count >= minimumHoverMoves,
           lastMouseAt.map({ now - $0 > silenceSeconds }) ?? true,
           report(.pointerOnCatcherMouseSilent, now) {
            return .pointerOnCatcherMouseSilent
        }
        return nil
    }

    private mutating func report(_ finding: Finding, _ now: Double) -> Bool {
        if let last = lastReported[finding], now - last < repeatSeconds { return false }
        lastReported[finding] = now
        return true
    }
}
