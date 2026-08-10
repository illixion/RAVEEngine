/*
 RAVE Engine — "no data" as a thing a readout can say.

 Only one of the four HUDs had this, and every other one wants it.

 Longwave's PCVR panel showed a steady 33 fps at 29.9 ms for as long as it was
 looked at — an entirely plausible thing for a PC to be doing, and the number
 was minutes old. The feed had stopped; the last packet stayed on screen. **A
 frozen readout is worse than an empty one**, because it is indistinguishable
 from a working one, and the whole point of a glanceable panel is that it can
 be trusted at a glance.

 So every reading gated by one of these is nil once its feed goes quiet, and
 the view renders "—" instead of a number it can no longer stand behind. The
 gate also distinguishes *stopped* from *never started*: those are different
 faults with different causes, and they deserve different words.
 */

import Foundation

/// Tracks when a data feed was last heard from, and refuses to vouch for it
/// after `timeout`.
public struct RAVEFeedGate: Sendable, Equatable {
    /// How quiet the feed must go before its readings stop counting. Size this
    /// as *several missed updates*, not one late one — a 10 Hz feed wants
    /// something like 1.5 s, so a single dropped packet doesn't blank the panel.
    public var timeout: TimeInterval
    /// When the last update arrived, on the same monotonic clock passed to
    /// `isLive(now:)`. Zero means nothing has ever arrived.
    public private(set) var lastUpdate: TimeInterval = 0

    public init(timeout: TimeInterval = 1.5) {
        self.timeout = timeout
    }

    /// Note that data arrived.
    public mutating func markUpdated(at now: TimeInterval) {
        lastUpdate = now
    }

    /// True if anything has ever arrived, whether or not it is still current.
    public var hasEverReceived: Bool { lastUpdate > 0 }

    /// Whether readings may still be shown.
    public func isLive(now: TimeInterval) -> Bool {
        hasEverReceived && (now - lastUpdate) < timeout
    }

    /// Seconds since the last update, or nil if there has never been one.
    public func age(now: TimeInterval) -> TimeInterval? {
        hasEverReceived ? Swift.max(0, now - lastUpdate) : nil
    }

    /// Pass a reading through the gate: the value while the feed is live, nil
    /// once it is not. The call site then has one thing to render "—" for.
    public func gated<T>(_ value: T?, now: TimeInterval) -> T? {
        isLive(now: now) ? value : nil
    }

    /// Why there is no data, for a status line.
    ///
    /// "Lost" and "never arrived" are separated on purpose: one is a transport
    /// that stopped mid-session, the other one that never started, and they
    /// call for opposite investigations.
    public func status(now: TimeInterval) -> RAVEFeedStatus {
        guard hasEverReceived else { return .neverStarted }
        let age = now - lastUpdate
        return age < timeout ? .live : .stopped(secondsAgo: age)
    }
}

public enum RAVEFeedStatus: Sendable, Equatable {
    /// Data is current; readings may be shown.
    case live
    /// Nothing has ever arrived.
    case neverStarted
    /// Data arrived once and then stopped.
    case stopped(secondsAgo: TimeInterval)

    public var isLive: Bool { self == .live }
}
