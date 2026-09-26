/*
 RAVE Engine — press/release edge detection over polled button state.

 Polling gives you held state; almost every consumer wants edges. Spatialcraft
 and Lambda each reinvented this independently. This is that, once, keyed by
 whatever the caller finds natural.

 A value type with no isolation, so it sits inside a `@MainActor` input manager
 and a render-thread poll loop equally well.
 */

import Foundation

/// What happened to a button between the previous poll and this one.
public enum RAVEEdge: Sendable, Equatable {
    /// State unchanged since the last poll.
    case steady
    /// Pressed this poll.
    case began
    /// Released this poll.
    case ended

    public var isBegan: Bool { self == .began }
    public var isEnded: Bool { self == .ended }
}

/// Tracks held state for a set of keys and reports transitions.
///
/// Optionally debounced: with a non-zero `debounce`, a change of state must
/// persist for that long before it is reported, which rejects contact bounce
/// on a worn button and a stick hovering on a digital threshold. Debouncing
/// needs a clock, so it applies only through the `now:`-taking calls; the
/// original calls stay immediate.
public struct RAVEEdgeTracker<Key: Hashable & Sendable>: Sendable {
    private var held: Set<Key> = []
    /// Keys whose raw state disagrees with `held`, and since when.
    private var pending: [Key: TimeInterval] = [:]

    /// How long a change must persist before it is reported (seconds).
    public var debounce: TimeInterval

    public init() {
        self.debounce = 0
    }

    public init(debounce: TimeInterval) {
        self.debounce = max(0, debounce)
    }

    /// Debounced `update`: `pressed` is this poll's raw state, `now` a
    /// monotonic time in seconds.
    @discardableResult
    public mutating func update(_ key: Key, pressed: Bool, now: TimeInterval) -> RAVEEdge {
        let wasHeld = held.contains(key)
        guard pressed != wasHeld else {
            pending.removeValue(forKey: key)
            return .steady
        }
        if debounce > 0 {
            guard let since = pending[key] else {
                pending[key] = now
                return .steady
            }
            guard now - since >= debounce else { return .steady }
        }
        pending.removeValue(forKey: key)
        return update(key, pressed: pressed)
    }

    /// Debounced `pressed`.
    @discardableResult
    public mutating func pressed(_ key: Key, _ isDown: Bool, now: TimeInterval) -> Bool {
        update(key, pressed: isDown, now: now) == .began
    }

    /// Record this poll's state for `key` and return the transition.
    @discardableResult
    public mutating func update(_ key: Key, pressed: Bool) -> RAVEEdge {
        let wasHeld = held.contains(key)
        guard pressed != wasHeld else { return .steady }
        if pressed {
            held.insert(key)
            return .began
        } else {
            held.remove(key)
            return .ended
        }
    }

    /// `update`, reduced to the rising edge — the common case.
    @discardableResult
    public mutating func pressed(_ key: Key, _ isDown: Bool) -> Bool {
        update(key, pressed: isDown) == .began
    }

    public func isHeld(_ key: Key) -> Bool {
        held.contains(key)
    }

    /// Forget all state. The next poll of a still-held button reports `.began`
    /// again, which is what a mode change usually wants.
    public mutating func reset() {
        held.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }
}
