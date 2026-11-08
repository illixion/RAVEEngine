/*
 RAVE Engine — where the wearer is looking, from any provider.

 Consumers share geometry across sources, while export policy follows each
 reading's origin. A provider yields
 `RAVEGazeSample`s: a unit direction in the wearer's *head space* (-z is
 straight ahead, +x right, +y up). Head space is the one frame every provider
 can agree on, so a consumer never has to reconcile a provider's world origin
 with ARKit's: it brings the thing it cares about into head space with its own
 head pose and asks `RAVEGazeTarget`.

 `RAVEHTTPGazeSource` polls any endpoint that answers `{"latest": {...}}`
 with `seq`, `t`, `pivot` and `direction`, plus `captureNs` when the endpoint
 runs on this device and knows when the reading was captured. `RAVEPushGazeSource` takes samples
 a transport hands it, in `RAVEGazeWire`'s bytes or as values; the
 `RAVEFoveatedGaze` target feeds one from Apple's foveated streaming provider.
 */

import Foundation
import simd

/// Where a reading originated, independent of its transport or presenter.
/// Unknown/legacy readings are usable for foveation but never exported to apps.
public enum RAVEGazeOrigin: UInt8, Equatable, Sendable {
    case unknown = 0
    case foveatedStreamingProvider = 1
    case externalSensor = 2

    public var allowsApplicationExport: Bool { self == .externalSensor }
}

/// One gaze reading.
public struct RAVEGazeSample: Equatable, Sendable {
    /// Preserved by relays; converting coordinates must not change this.
    public let origin: RAVEGazeOrigin
    /// Monotonic counter from the provider; a repeat means no new reading.
    public var sequence: Int
    /// Unit vector in head space (-z ahead, +x right, +y up).
    public var direction: SIMD3<Float>
    /// Gaze point in the eye image, 0...1, y down (0.5/0.5 = centre).
    public var pivot: SIMD2<Float>
    /// When this app received it.
    public var receivedAt: Date
    /// Capture time in this device's CACurrentMediaTime clock, when established
    /// by a local provider. Remote/unknown clock domains must leave this nil.
    /// Receipt time must never be substituted for capture time.
    public var localCaptureTime: TimeInterval?
    /// Estimated distance to what the wearer focuses on, in metres, when the
    /// provider knows it (Apple's focus region does).
    public var distance: Float?

    public init(sequence: Int, direction: SIMD3<Float>, pivot: SIMD2<Float> = SIMD2(0.5, 0.5),
                distance: Float? = nil, receivedAt: Date = Date(), localCaptureTime: TimeInterval? = nil,
                origin: RAVEGazeOrigin = .unknown) {
        self.origin = origin
        self.sequence = sequence
        self.direction = direction
        self.pivot = pivot
        self.distance = distance
        self.receivedAt = receivedAt
        self.localCaptureTime = localCaptureTime
    }
}

/// Anything that can say where the wearer is looking.
public protocol RAVEGazeSource: AnyObject {
    /// The newest sample, or nil when none has arrived.
    var latest: RAVEGazeSample? { get }
}

/// Whether a point in head space is being looked at.
public enum RAVEGazeTarget {

    /// Angle in degrees between the gaze and the direction to `point`
    /// (head space). Nil when the point is at the head's origin.
    public static func angleDegrees(gaze: SIMD3<Float>, to point: SIMD3<Float>) -> Float? {
        let pl = simd_length(point), gl = simd_length(gaze)
        guard pl > 1e-6, gl > 1e-6 else { return nil }
        let c = max(-1, min(1, simd_dot(gaze / gl, point / pl)))
        return acos(c) * 180 / .pi
    }

    /// True when `point` lies within `cone` degrees of the gaze. A sample
    /// older than `maxAge` seconds counts as not looking, so a dropped
    /// provider never leaves a stale "being looked at".
    public static func isLookedAt(
        _ sample: RAVEGazeSample?, point: SIMD3<Float>, cone: Float = 8,
        maxAge: TimeInterval = 0.5, now: Date = Date()
    ) -> Bool {
        guard let sample, now.timeIntervalSince(sample.receivedAt) <= maxAge,
              let angle = angleDegrees(gaze: sample.direction, to: point) else { return false }
        return angle <= cone
    }
}

/// Polls a JSON gaze endpoint (`GET <url>` → `{"latest": {seq, pivot, direction}}`).
public final class RAVEHTTPGazeSource: RAVEGazeSource, @unchecked Sendable {

    private let lock = NSLock()
    private var sample: RAVEGazeSample?
    private var task: Task<Void, Never>?
    private var localClock = false
    private var stampOffsets: (uptime: TimeInterval, continuous: TimeInterval?)?

    /// Diagnostics for a local endpoint: how long before now (positive) or after
    /// it (negative) the last `captureNs` lay on the uptime and continuous clocks,
    /// whether or not it was believed. Nil until a stamped reading arrives.
    public var lastStampOffsets: (uptime: TimeInterval, continuous: TimeInterval?)? {
        lock.lock(); defer { lock.unlock() }
        return stampOffsets
    }

    public var latest: RAVEGazeSample? {
        lock.lock(); defer { lock.unlock() }
        return sample
    }

    /// Whether the endpoint runs on this device, so its `captureNs` (if any) is
    /// this device's uptime clock and becomes `localCaptureTime`. Off by default:
    /// a remote endpoint's clock says nothing about ours. Set before `start`.
    public var usesLocalCaptureClock: Bool {
        get { lock.lock(); defer { lock.unlock() }; return localClock }
        set { lock.lock(); localClock = newValue; sample = nil; lock.unlock() }
    }

    private let origin: RAVEGazeOrigin
    public init(origin: RAVEGazeOrigin = .unknown) { self.origin = origin }
    deinit { task?.cancel() }

    /// Starts polling `url` every `interval` seconds; replaces a running poll.
    public func start(url: URL, interval: TimeInterval = 1.0 / 30) {
        task?.cancel()
        task = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            while !Task.isCancelled {
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let self,
                   self.noteStamp(data),
                   let parsed = Self.parse(data, localClockNow: self.usesLocalCaptureClock
                                           ? ProcessInfo.processInfo.systemUptime : nil,
                                           localContinuousNow: self.usesLocalCaptureClock
                                           ? Self.continuousNow() : nil, origin: self.origin) {
                    self.store(parsed)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lock.lock(); sample = nil; lock.unlock()
    }

    /// Records `lastStampOffsets`; always true, so it can sit in a condition list.
    private func noteStamp(_ data: Data) -> Bool {
        guard usesLocalCaptureClock,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = root["latest"] as? [String: Any],
              let ns = (latest["captureNs"] as? NSNumber)?.uint64Value, ns > 0 else { return true }
        let seconds = TimeInterval(ns) / 1_000_000_000
        let offsets = (ProcessInfo.processInfo.systemUptime - seconds, Self.continuousNow().map { $0 - seconds })
        lock.lock(); stampOffsets = offsets; lock.unlock()
        return true
    }

    private func store(_ new: RAVEGazeSample) {
        lock.lock(); defer { lock.unlock() }
        // A repeated sequence is the same reading: keep its original arrival
        // time, so a stalled provider ages out.
        if let old = sample, old.sequence == new.sequence { return }
        sample = new
    }

    /// How far a local `captureNs` may lie before `localClockNow` and still be
    /// believed. Anything older, or later than now, means the endpoint is not on
    /// this clock after all, and the sample gets no capture time.
    public static let localCaptureWindow: ClosedRange<TimeInterval> = -0.005...1.0

    /// This device's continuous clock (uptime including sleep), in seconds.
    public static func continuousNow() -> TimeInterval? {
        #if canImport(Darwin)
        return TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        #else
        return nil
        #endif
    }

    /// `ns` as a time on the uptime clock, or nil when it fits neither local
    /// clock. A stamp on the continuous clock (which also counts sleep) is
    /// moved back by the sleep since boot, the two clocks' difference now.
    public static func localCaptureTime(ns: UInt64, uptimeNow: TimeInterval,
                                        continuousNow: TimeInterval?) -> TimeInterval? {
        let seconds = TimeInterval(ns) / 1_000_000_000
        if localCaptureWindow.contains(uptimeNow - seconds) { return seconds }
        if let continuousNow, localCaptureWindow.contains(continuousNow - seconds) {
            return seconds - (continuousNow - uptimeNow)
        }
        return nil
    }

    /// Parses the endpoint's JSON. Nil when it has no usable reading.
    /// - Parameters:
    ///   - localClockNow: This device's uptime (`systemUptime`, the clock
    ///     `CACurrentMediaTime` reads) when the endpoint is local; then a
    ///     plausible `captureNs` becomes `localCaptureTime`. Nil for a remote one.
    ///   - localContinuousNow: The continuous clock at the same moment, so a
    ///     stamp taken on that clock is recognised too.
    public static func parse(_ data: Data, receivedAt: Date = Date(),
                             localClockNow: TimeInterval? = nil,
                             localContinuousNow: TimeInterval? = nil,
                             origin: RAVEGazeOrigin = .unknown) -> RAVEGazeSample? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = root["latest"] as? [String: Any],
              let seq = latest["seq"] as? Int,
              let d = latest["direction"] as? [Double], d.count == 3 else { return nil }
        let p = (latest["pivot"] as? [Double]).flatMap { $0.count == 2 ? $0 : nil } ?? [0.5, 0.5]
        var capture: TimeInterval?
        if let now = localClockNow, let ns = (latest["captureNs"] as? NSNumber)?.uint64Value, ns > 0 {
            capture = localCaptureTime(ns: ns, uptimeNow: now, continuousNow: localContinuousNow)
        }
        return RAVEGazeSample(
            sequence: seq,
            direction: SIMD3(Float(d[0]), Float(d[1]), Float(d[2])),
            pivot: SIMD2(Float(p[0]), Float(p[1])),
            receivedAt: receivedAt,
            localCaptureTime: capture, origin: origin)
    }
}
