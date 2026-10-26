import Foundation

/// Maps the hub's monotonic clock to the consumer's. Keep the lowest-RTT
/// exchange in a rolling window; queueing must not look like clock drift.
/// No wall clock, actor or network dependency, so render-thread callers and
/// recorded streams use the same rules.
public struct RAVEBodyClock: Sendable {
    private struct Sample: Sendable {
        var at: Double
        var offset: Double
        var roundTrip: Double
    }
    private var samples: [Sample] = []
    public init() {}

    public mutating func record(sent: Double, received: Double, hubReceived: Double, hubSent: Double) {
        guard [sent, received, hubReceived, hubSent].allSatisfy(\.isFinite),
              received >= sent, received - sent <= 1, hubSent >= hubReceived else { return }
        let roundTrip = received - sent - (hubSent - hubReceived)
        guard roundTrip >= -0.000001 else { return }
        samples.removeAll { received - $0.at > 10 }
        samples.append(Sample(at: received, offset: ((sent - hubReceived) + (received - hubSent)) / 2,
                              roundTrip: max(0, roundTrip)))
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
    }

    private func best(now: Double) -> Sample? {
        samples.filter { now >= $0.at && now - $0.at <= 10 }.min { $0.roundTrip < $1.roundTrip }
    }

    public func localTime(_ hubTime: Double, now: Double) -> Double? {
        best(now: now).map { hubTime + $0.offset }
    }

    public func hubTime(_ localTime: Double, now: Double) -> Double? {
        best(now: now).map { localTime - $0.offset }
    }

    /// Half RTT is the uncertainty bound under asymmetric network delay.
    public func uncertainty(now: Double) -> Double? { best(now: now).map { $0.roundTrip / 2 } }
}
