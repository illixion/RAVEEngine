/*
 RAVE Engine — press/release edge detection over polled button state.

 Polling gives you held state; almost every consumer wants edges. Spatialcraft
 and Lambda each reinvented this independently. This is that, once, keyed by
 whatever the caller finds natural.

 A value type with no isolation, so it sits inside a `@MainActor` input manager
 and a render-thread poll loop equally well.
 */

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
public struct RAVEEdgeTracker<Key: Hashable & Sendable>: Sendable {
    private var held: Set<Key> = []

    public init() {}

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
    }
}
