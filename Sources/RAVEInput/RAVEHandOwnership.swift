/*
 RAVE Engine — per-hand gesture arbitration.

 One hand can only mean one thing at a time, and every app enforced that with
 its own flags: Lambda's `gunHandBusy` (a swinging arm is not a gun hand, plus a
 0.2 s holdoff so opening the fists does not fire), the weapon wheel forcing
 fire and reload off, a held clutch resetting the arm swinger; Longwave's
 `suppressedHands` while its wrist panel is up; Oneiros's system-pinch gate.
 Each is the same rule: a gesture *claims* a hand; while it holds the claim, a
 gesture of lower (or equal) priority cannot take that hand; a higher-priority
 one may pre-empt it; after a release, other gestures wait out a holdoff so the
 release motion itself does not read as their input.

 This type holds only that rule. It knows nothing about what the gestures are
 — `Gesture` is the app's own enum. Pure value type, no isolation, timestamps
 passed in, and no allocation per frame (two stored optionals, not a map).
 */

import Foundation

/// The result of a claim.
public enum RAVEHandClaimResult<Gesture: Hashable & Sendable>: Sendable, Equatable {
    /// The hand was free and is now owned by the claimant.
    case granted
    /// The claimant already owned the hand.
    case alreadyOwned
    /// The claimant out-ranked the previous owner and took the hand.
    case preempted(Gesture)
    /// Another gesture of equal or higher priority owns the hand.
    case denied(owner: Gesture)
    /// The hand was just released by another gesture and is in its holdoff.
    case holdoff(remaining: TimeInterval)

    /// True when the claimant owns the hand after the call.
    public var isGranted: Bool {
        switch self {
        case .granted, .alreadyOwned, .preempted: return true
        case .denied, .holdoff: return false
        }
    }
}

/// Per-hand arbiter.
public struct RAVEHandOwnership<Gesture: Hashable & Sendable>: Sendable, Equatable {
    public struct Claim: Sendable, Equatable {
        public let gesture: Gesture
        public let priority: Int
        public let since: TimeInterval
    }

    private struct Released: Sendable, Equatable {
        let gesture: Gesture
        let priority: Int
        let at: TimeInterval
    }

    /// How long, after a gesture releases a hand, other gestures of equal or
    /// lower priority than it are refused that hand. A higher-priority gesture
    /// is never held off.
    public var releaseHoldoff: TimeInterval

    private var leftClaim: Claim?
    private var rightClaim: Claim?
    private var leftReleased: Released?
    private var rightReleased: Released?

    public init(releaseHoldoff: TimeInterval = 0) {
        self.releaseHoldoff = releaseHoldoff
    }

    /// The current claim on a hand, if any.
    public func claim(on hand: RAVEHandChirality) -> Claim? {
        hand == .left ? leftClaim : rightClaim
    }

    /// The gesture owning a hand, if any.
    public func owner(of hand: RAVEHandChirality) -> Gesture? {
        claim(on: hand)?.gesture
    }

    public func owns(_ gesture: Gesture, _ hand: RAVEHandChirality) -> Bool {
        owner(of: hand) == gesture
    }

    /// Whether `claim` would succeed, without changing anything.
    public func canClaim(_ hand: RAVEHandChirality, for gesture: Gesture,
                         priority: Int, now: TimeInterval) -> Bool {
        evaluate(hand, gesture, priority, now).isGranted
    }

    /// Try to take a hand.
    @discardableResult
    public mutating func claim(_ hand: RAVEHandChirality, for gesture: Gesture,
                               priority: Int, now: TimeInterval) -> RAVEHandClaimResult<Gesture> {
        let result = evaluate(hand, gesture, priority, now)
        switch result {
        case .granted, .preempted:
            set(hand, Claim(gesture: gesture, priority: priority, since: now))
        case .alreadyOwned, .denied, .holdoff:
            break
        }
        return result
    }

    /// Give a hand up. No-op unless `gesture` owns it — a gesture that was
    /// pre-empted cannot release its successor's claim.
    public mutating func release(_ hand: RAVEHandChirality, for gesture: Gesture, now: TimeInterval) {
        guard let current = claim(on: hand), current.gesture == gesture else { return }
        set(hand, nil)
        let released = Released(gesture: gesture, priority: current.priority, at: now)
        if hand == .left { leftReleased = released } else { rightReleased = released }
    }

    /// Release every hand `gesture` owns.
    public mutating func releaseAll(for gesture: Gesture, now: TimeInterval) {
        release(.left, for: gesture, now: now)
        release(.right, for: gesture, now: now)
    }

    /// Forget everything, holdoffs included.
    public mutating func reset() {
        leftClaim = nil
        rightClaim = nil
        leftReleased = nil
        rightReleased = nil
    }

    private mutating func set(_ hand: RAVEHandChirality, _ claim: Claim?) {
        if hand == .left { leftClaim = claim } else { rightClaim = claim }
    }

    private func evaluate(_ hand: RAVEHandChirality, _ gesture: Gesture,
                          _ priority: Int, _ now: TimeInterval) -> RAVEHandClaimResult<Gesture> {
        if let current = claim(on: hand) {
            if current.gesture == gesture { return .alreadyOwned }
            return priority > current.priority ? .preempted(current.gesture)
                                               : .denied(owner: current.gesture)
        }
        let released = hand == .left ? leftReleased : rightReleased
        if let released, released.gesture != gesture, priority <= released.priority {
            let remaining = releaseHoldoff - (now - released.at)
            if remaining > 0 { return .holdoff(remaining: remaining) }
        }
        return .granted
    }
}
