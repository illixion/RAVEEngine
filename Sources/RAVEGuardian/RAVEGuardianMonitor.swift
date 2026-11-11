/*
 RAVE Engine — the guardian's judgement: for each tracked part (head, hands,
 controllers), how close is the nearest wall and how fast is it heading
 there, and from that, how strongly each nearby chunk of wall should show.

 Two terms, the larger wins:
 - proximity: inside the warning distance the alert ramps from 0 at the
   margin to 1 at a quarter of it;
 - approach: a part moving toward the wall faster than the minimum speed is
   judged by where it will be `lookahead` seconds from now. A punch at 2 m/s
   with the defaults warns from about 1.35 m away; a slow lean only at the
   margin.

 Each probe lights the chunks around it (within the reveal radius, softening
 to nothing at twice that), scaled by its alert. The head reveals a wider
 area than a hand: when your body is about to meet a wall you want to see the
 wall, not a hand-sized patch of it. Opacity rises fast and falls slowly, so a
 warning appears within a frame or two and does not flicker off between
 swings.

 Isolation-free value type (RAVEEngine's isolation rule). Time is passed in.
 */

import Foundation
import simd

/// A tracked point to keep off the walls.
public struct RAVEGuardianProbe: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case head, hand, controller

        /// How far the real thing reaches around its tracked point: the head
        /// anchor sits between the eyes but the visor sticks out ~10 cm; a
        /// controller's ring and a hand's fingers past the palm point.
        public var radius: Float {
            switch self {
            case .head: 0.14
            case .hand: 0.05
            case .controller: 0.08
            }
        }

        /// Chunks this close to an alerting probe show at its full alert.
        public var revealRadius: Float {
            switch self {
            case .head: 1.6
            case .hand, .controller: 0.8
            }
        }
    }

    /// Stable per tracked point ("head", "hand.left.palm"); velocity is
    /// tracked per id.
    public var id: String
    public var kind: Kind
    /// ARKit world space, metres.
    public var position: SIMD3<Float>

    public init(id: String, kind: Kind, position: SIMD3<Float>) {
        self.id = id; self.kind = kind; self.position = position
    }
}

public struct RAVEGuardianProbeState: Sendable, Equatable {
    public var probe: RAVEGuardianProbe
    /// Gap between the part's surface and the nearest barrier, metres
    /// (never negative), or nil when nothing is within reach.
    public var clearance: Float?
    /// Speed toward that barrier, m/s (negative = moving away).
    public var approachSpeed: Float
    /// Seconds to contact at this speed, when approaching.
    public var timeToContact: Float?
    /// 0...1.
    public var alert: Float
    public var nearest: RAVEGuardianHit?
}

public struct RAVEGuardianFrame: Sendable {
    public var probes: [RAVEGuardianProbeState] = []
    /// Smoothed opacity per chunk, 0...1 (already scaled by the appearance's
    /// max/resting opacity). Chunks absent here are invisible.
    public var chunkOpacity: [RAVEGuardianChunkID: Float] = [:]
    /// The strongest alert this frame, 0...1.
    public var peakAlert: Float = 0
}

public struct RAVEGuardianMonitor: Sendable {

    /// Seconds for the opacity to rise / fall most of the way.
    public static let riseTime: Double = 0.05
    public static let fallTime: Double = 0.45
    /// Velocity smoothing (exponential, per second-ish): enough to steady
    /// ARKit's jitter, little enough that a punch registers within ~2 frames.
    public static let velocityTime: Double = 0.04
    /// Probe samples further apart than this restart its velocity: a hand that
    /// drops out and reappears elsewhere did not teleport at 50 m/s.
    public static let maxSampleGap: Double = 0.25
    /// In `.always`, chunks within this distance of the head rest visible.
    public static let alwaysRadius: Float = 4.0

    private struct Track {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var time: Double
    }

    private var tracks: [String: Track] = [:]
    private var opacity: [RAVEGuardianChunkID: Float] = [:]
    private var lastTime: Double?

    public init() {}

    /// Drop all history (session restart, tracking reset).
    public mutating func reset() {
        tracks.removeAll()
        opacity.removeAll()
        lastTime = nil
    }

    /// The alert for one measurement, the formula in the header.
    public static func alert(clearance: Float, approachSpeed: Float,
                             settings: RAVEGuardianSettings) -> Float {
        let margin = settings.warningDistance
        let full = margin * 0.25
        func ramp(_ gap: Float) -> Float {
            if gap <= full { return 1 }
            if gap >= margin { return 0 }
            let t = (margin - gap) / (margin - full)
            return t * t * (3 - 2 * t)
        }
        var a = ramp(clearance)
        if settings.lookahead > 0, approachSpeed > settings.minimumApproachSpeed {
            let predicted = clearance - approachSpeed * settings.lookahead
            a = max(a, ramp(predicted))
        }
        return a
    }

    public mutating func update(probes: [RAVEGuardianProbe], time: Double,
                                map: RAVEGuardianMap,
                                settings: RAVEGuardianSettings) -> RAVEGuardianFrame {
        let dt = lastTime.map { max(0, min(time - $0, 0.1)) } ?? 0
        lastTime = time
        var frame = RAVEGuardianFrame()

        guard settings.isEnabled else {
            opacity.removeAll()
            tracks.removeAll()
            return frame
        }

        // Probe velocities and alerts.
        var seen = Set<String>()
        // Look as far as a fast part could close in the lookahead window, so
        // a hit exists to judge the approach against.
        let reach = settings.warningDistance + max(settings.lookahead, 0) * 3.0 + 0.2
        for probe in probes where settings.watches(probe.kind) {
            seen.insert(probe.id)
            var velocity = SIMD3<Float>.zero
            if var track = tracks[probe.id], time - track.time <= Self.maxSampleGap, time > track.time {
                let raw = (probe.position - track.position) / Float(time - track.time)
                let k = Float(1 - exp(-(time - track.time) / Self.velocityTime))
                track.velocity += (raw - track.velocity) * k
                track.position = probe.position
                track.time = time
                tracks[probe.id] = track
                velocity = track.velocity
            } else {
                tracks[probe.id] = Track(position: probe.position, velocity: .zero, time: time)
            }

            let hit = map.nearest(to: probe.position, within: reach + probe.kind.radius,
                                  includeObstacles: settings.includesFurniture)
            var state = RAVEGuardianProbeState(probe: probe, clearance: nil, approachSpeed: 0,
                                               timeToContact: nil, alert: 0, nearest: hit)
            if let hit {
                let clearance = max(0, hit.distance - probe.kind.radius)
                let toward: SIMD3<Float> = hit.distance > 1e-4
                    ? (hit.point - probe.position) / hit.distance
                    : -hit.normal
                let speed = simd_dot(velocity, toward)
                state.clearance = clearance
                state.approachSpeed = speed
                state.timeToContact = speed > 1e-3 ? clearance / speed : nil
                state.alert = Self.alert(clearance: clearance, approachSpeed: speed, settings: settings)
            }
            frame.peakAlert = max(frame.peakAlert, state.alert)
            frame.probes.append(state)
        }
        tracks = tracks.filter { seen.contains($0.key) }

        // Chunk targets.
        let appearance = settings.appearance
        var target: [RAVEGuardianChunkID: Float] = [:]
        let head = frame.probes.first { $0.probe.kind == .head }?.probe.position
        for chunk in map.chunks.values {
            if chunk.id.isObstacle && !settings.includesFurniture { continue }
            var t: Float = 0
            for state in frame.probes where state.alert > 0 {
                let r = state.probe.kind.revealRadius
                let d = chunk.bounds.distance(to: state.probe.position)
                guard d < 2 * r else { continue }
                let falloff: Float = d <= r ? 1 : 1 - (d - r) / r
                t = max(t, state.alert * falloff)
            }
            t *= appearance.maxOpacity
            if settings.visibility == .always, let head,
               chunk.bounds.distance(to: head) <= Self.alwaysRadius {
                t = max(t, appearance.restingOpacity)
            }
            if t > 0 { target[chunk.id] = t }
        }

        // Smooth toward the targets; drop chunks that faded out or vanished.
        let rise = dt > 0 ? Float(1 - exp(-dt / Self.riseTime)) : 1
        let fall = dt > 0 ? Float(1 - exp(-dt / Self.fallTime)) : 1
        var next: [RAVEGuardianChunkID: Float] = [:]
        for id in Set(target.keys).union(opacity.keys) where map.chunks[id] != nil {
            let current = opacity[id] ?? 0
            let goal = target[id] ?? 0
            let k = goal > current ? rise : fall
            let value = current + (goal - current) * k
            if value > 0.005 || goal > 0 { next[id] = value }
        }
        opacity = next
        frame.chunkOpacity = next
        return frame
    }
}
