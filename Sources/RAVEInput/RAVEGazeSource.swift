/*
 RAVE Engine — where the wearer is looking, from any provider.

 The seam is deliberately blind to who produces the gaze. A provider yields
 `RAVEGazeSample`s: a unit direction in the wearer's *head space* (-z is
 straight ahead, +x right, +y up). Head space is the one frame every provider
 can agree on, so a consumer never has to reconcile a provider's world origin
 with ARKit's: it brings the thing it cares about into head space with its own
 head pose and asks `RAVEGazeTarget`.

 `RAVEHTTPGazeSource` polls any endpoint that answers `{"latest": {...}}`
 with `seq`, `t`, `pivot` and `direction`.
 */

import Foundation
import simd

/// One gaze reading.
public struct RAVEGazeSample: Equatable, Sendable {
    /// Monotonic counter from the provider; a repeat means no new reading.
    public var sequence: Int
    /// Unit vector in head space (-z ahead, +x right, +y up).
    public var direction: SIMD3<Float>
    /// Gaze point in the eye image, 0...1, y down (0.5/0.5 = centre).
    public var pivot: SIMD2<Float>
    /// When this app received it.
    public var receivedAt: Date

    public init(sequence: Int, direction: SIMD3<Float>, pivot: SIMD2<Float> = SIMD2(0.5, 0.5), receivedAt: Date = Date()) {
        self.sequence = sequence
        self.direction = direction
        self.pivot = pivot
        self.receivedAt = receivedAt
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

    public var latest: RAVEGazeSample? {
        lock.lock(); defer { lock.unlock() }
        return sample
    }

    public init() {}
    deinit { task?.cancel() }

    /// Starts polling `url` every `interval` seconds; replaces a running poll.
    public func start(url: URL, interval: TimeInterval = 1.0 / 30) {
        task?.cancel()
        task = Task { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            while !Task.isCancelled {
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let parsed = Self.parse(data) {
                    self?.store(parsed)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func store(_ new: RAVEGazeSample) {
        lock.lock(); defer { lock.unlock() }
        // A repeated sequence is the same reading: keep its original arrival
        // time, so a stalled provider ages out.
        if let old = sample, old.sequence == new.sequence { return }
        sample = new
    }

    /// Parses the endpoint's JSON. Nil when it has no usable reading.
    public static func parse(_ data: Data, receivedAt: Date = Date()) -> RAVEGazeSample? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = root["latest"] as? [String: Any],
              let seq = latest["seq"] as? Int,
              let d = latest["direction"] as? [Double], d.count == 3 else { return nil }
        let p = (latest["pivot"] as? [Double]).flatMap { $0.count == 2 ? $0 : nil } ?? [0.5, 0.5]
        return RAVEGazeSample(
            sequence: seq,
            direction: SIMD3(Float(d[0]), Float(d[1]), Float(d[2])),
            pivot: SIMD2(Float(p[0]), Float(p[1])),
            receivedAt: receivedAt)
    }
}
