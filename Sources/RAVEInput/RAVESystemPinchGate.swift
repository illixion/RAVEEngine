/*
 RAVE Engine — arbitration between the two deliveries of one physical pinch.

 Lifted from Oneiros (`Engine/SystemPinchGate.swift`), where it was written
 after a HUD button press held past the hand tracker's debounce also placed or
 broke a block behind the panel.

 visionOS delivers a pinch as a **system gesture** routed by gaze to exactly
 one target — a SwiftUI window, a RealityView attachment, a world tap catcher,
 a Compositor layer — and, independently, ARKit hand tracking reports the same
 fingers closing as a raw pinch the app maps to an action. The raw path has no
 idea a UI element was the real target.

 Rule: the system gesture owns thumb+index. Every host that receives system
 pinch phases registers them here (`begin`/`end`), and hand-derived world
 actions are refused while any system pinch is active and for `grace`
 afterwards. A thumb+middle pinch is never a system pinch, so hand-path
 bindings on other fingers keep working.

 Generic over the app's own `Source` enum (which surface reported the pinch —
 diagnostics only). Pure value type, timestamps passed in.
 */

import Foundation

public struct RAVESystemPinchGate<Source: Hashable & Sendable>: Sendable, Equatable {
    /// One in-flight system pinch. `key` is the host's event identity (a
    /// `SpatialEventCollection.Event.ID` hash, or a per-view counter).
    public struct Token: Hashable, Sendable {
        public let source: Source
        public let key: Int

        public init(source: Source, key: Int) {
            self.source = source
            self.key = key
        }
    }

    /// Seconds after the last system pinch ends during which hand world actions
    /// stay refused — covers a hand-tracker rising edge that lands after a very
    /// short system tap (the tracker's own debounce puts its edge ~100 ms late).
    public var grace: TimeInterval
    /// A `begin` with no matching `end` (a missed `.cancelled`, or the owner
    /// swapped mid-gesture) expires after this long.
    public var staleTimeout: TimeInterval

    public private(set) var active: [Token: TimeInterval] = [:]
    public private(set) var lastEndedAt: TimeInterval = -.infinity
    public private(set) var suppressedCount: Int = 0
    public private(set) var lastSuppressedFinger: String = ""
    public private(set) var lastSuppressedAction: String = ""

    public init(grace: TimeInterval = 0.30, staleTimeout: TimeInterval = 2.0) {
        self.grace = grace
        self.staleTimeout = staleTimeout
    }

    // MARK: Producers

    public mutating func begin(_ token: Token, now: TimeInterval) {
        active[token] = now
    }

    /// No-op for an unknown token so a stray `.ended` cannot open a grace window.
    public mutating func end(_ token: Token, now: TimeInterval) {
        guard active.removeValue(forKey: token) != nil else { return }
        lastEndedAt = max(lastEndedAt, now)
    }

    /// A host that only observes the completed tap (no phases) still opens the
    /// grace window, so the hand tracker's late rising edge is refused.
    public mutating func noteTap(now: TimeInterval) {
        lastEndedAt = max(lastEndedAt, now)
    }

    /// Drop entries older than `staleTimeout`, stamping the grace clock so the
    /// hand path resumes cleanly rather than staying blocked forever.
    public mutating func expireStale(now: TimeInterval) {
        for (token, began) in active where now - began > staleTimeout {
            active.removeValue(forKey: token)
            lastEndedAt = max(lastEndedAt, now)
        }
    }

    public func isTracking(_ token: Token) -> Bool { active[token] != nil }

    // MARK: Consumers

    public func isActive(now: TimeInterval) -> Bool {
        active.values.contains { now - $0 <= staleTimeout }
    }

    /// True when a hand-tracker-derived world action may run.
    public func allowsHandWorldAction(now: TimeInterval) -> Bool {
        !isActive(now: now) && now - lastEndedAt >= grace
    }

    /// Seconds of grace still to run, 0 when the hand path is open.
    public func graceRemaining(now: TimeInterval) -> TimeInterval {
        max(0, grace - (now - lastEndedAt))
    }

    public mutating func recordSuppressed(finger: String, action: String) {
        suppressedCount += 1
        lastSuppressedFinger = finger
        lastSuppressedAction = action
    }

    public var activeCount: Int { active.count }

    /// The distinct sources with a pinch in flight, oldest first.
    public var activeSources: [Source] {
        var seen = Set<Source>()
        var out: [Source] = []
        for (token, _) in active.sorted(by: { $0.value < $1.value }) where seen.insert(token.source).inserted {
            out.append(token.source)
        }
        return out
    }
}

extension RAVESystemPinchGate where Source: RawRepresentable, Source.RawValue: Comparable {
    /// The distinct active sources sorted by raw value — a stable order for
    /// logs and debug JSON.
    public var activeSourcesSorted: [Source] {
        Array(Set(active.keys.map(\.source))).sorted { $0.rawValue < $1.rawValue }
    }
}
