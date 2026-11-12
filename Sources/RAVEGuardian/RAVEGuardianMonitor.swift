/*
 RAVE Engine — the guardian's judgement. A wall warning is a short cue for a
 hand or controller accelerating toward a wall; distance alone never shows
 the grid. Nearby furniture has a separate translucent hologram treatment.

 Warnings are rate-limited per probe and rearm only after the hand or
 controller slows or moves away. At very close range, the prediction horizon
 shortens so small tracking changes do not keep retriggering the cue.

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
    /// Acceleration toward that barrier, m/s² (negative = slowing down).
    public var approachAcceleration: Float
    /// Seconds to contact at this speed, when approaching.
    public var timeToContact: Float?
    /// 0...1.
    public var alert: Float
    public var nearest: RAVEGuardianHit?
}

public struct RAVEGuardianFrame: Sendable {
    public var probes: [RAVEGuardianProbeState] = []
    /// Smoothed opacity per chunk, 0...1. Chunks absent here are invisible.
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
    /// Smooth the second derivative more heavily than velocity to reject
    /// hand-tracking jitter without hiding a deliberate swing.
    public static let accelerationTime: Double = 0.08
    /// Probe samples further apart than this restart its velocity: a hand that
    /// drops out and reappears elsewhere did not teleport at 50 m/s.
    public static let maxSampleGap: Double = 0.25
    /// One cue per distinct motion, even if tracking noise crosses the
    /// acceleration threshold repeatedly.
    public static let warningCooldown: Double = 0.85
    /// Keep the single cue visible long enough to read before it fades.
    public static let warningPulseDuration: Double = 0.2
    /// A probe must nearly stop or move away before another swing can warn.
    public static let rearmApproachSpeed: Float = 0.2
    /// Furniture is visible as a hologram within this hand/controller reach.
    public static let obstacleHologramRadius: Float = 1.4

    private struct Track {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var acceleration: SIMD3<Float>
        var rawVelocity: SIMD3<Float>?
        var time: Double
    }

    private struct WarningPulse: Sendable {
        var expiresAt: Double
        var strength: Float
    }

    private var tracks: [String: Track] = [:]
    private var warningLatched: Set<String> = []
    private var warningPulses: [String: WarningPulse] = [:]
    private var lastWarningTime: [String: Double] = [:]
    private var opacity: [RAVEGuardianChunkID: Float] = [:]
    private var lastTime: Double?

    public init() {}

    /// Drop all history (session restart, tracking reset).
    public mutating func reset() {
        tracks.removeAll()
        warningLatched.removeAll()
        warningPulses.removeAll()
        lastWarningTime.removeAll()
        opacity.removeAll()
        lastTime = nil
    }

    /// Legacy distance/velocity envelope retained for callers that gate it
    /// with their own intent signal. The live Guardian uses acceleratedAlert.
    public static func alert(clearance: Float, approachSpeed: Float,
                             settings: RAVEGuardianSettings) -> Float {
        let current = rampedAlert(clearance: clearance, margin: settings.warningDistance)
        let predicted = approachSpeed > settings.minimumApproachSpeed
            ? rampedAlert(clearance: clearance - approachSpeed * settings.lookahead,
                          margin: settings.warningDistance)
            : 0
        return max(current, predicted)
    }

    /// A warning for a deliberate accelerating approach. Mere proximity and
    /// steady movement return zero.
    public static func acceleratedAlert(clearance: Float, approachSpeed: Float,
                                        approachAcceleration: Float,
                                        settings: RAVEGuardianSettings) -> Float {
        guard approachSpeed > settings.minimumApproachSpeed,
              approachAcceleration > settings.minimumApproachAcceleration else { return 0 }
        let horizon = clearance < 0.3 ? min(settings.lookahead, 0.12) : settings.lookahead
        let predicted = clearance - approachSpeed * horizon
            - 0.5 * approachAcceleration * horizon * horizon
        return rampedAlert(clearance: predicted,
                           margin: settings.warningDistance)
    }

    private static func rampedAlert(clearance: Float, margin: Float) -> Float {
        let full = margin * 0.25
        if clearance <= full { return 1 }
        if clearance >= margin { return 0 }
        let t = (margin - clearance) / (margin - full)
        return t * t * (3 - 2 * t)
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
            warningLatched.removeAll()
            warningPulses.removeAll()
            lastWarningTime.removeAll()
            return frame
        }

        // Probe velocity, acceleration and alert cues.
        var seen = Set<String>()
        // Look as far as a fast part could close in the lookahead window, so
        // a hit exists to judge the approach against.
        let reach = settings.warningDistance + max(settings.lookahead, 0) * 3.0 + 0.2
        for probe in probes where probe.kind != .head && settings.watches(probe.kind) {
            seen.insert(probe.id)
            var velocity = SIMD3<Float>.zero
            var acceleration = SIMD3<Float>.zero
            if var track = tracks[probe.id], time - track.time <= Self.maxSampleGap, time > track.time {
                let sampleDT = time - track.time
                let raw = (probe.position - track.position) / Float(sampleDT)
                let k = Float(1 - exp(-sampleDT / Self.velocityTime))
                track.velocity += (raw - track.velocity) * k
                if let previousRawVelocity = track.rawVelocity {
                    let rawAcceleration = (raw - previousRawVelocity) / Float(sampleDT)
                    let accelerationK = Float(1 - exp(-sampleDT / Self.accelerationTime))
                    track.acceleration += (rawAcceleration - track.acceleration) * accelerationK
                } else {
                    // The first valid displacement establishes current motion;
                    // it cannot tell us whether that motion is accelerating.
                    track.acceleration = .zero
                }
                track.rawVelocity = raw
                track.position = probe.position
                track.time = time
                tracks[probe.id] = track
                velocity = track.velocity
                acceleration = track.acceleration
            } else {
                tracks[probe.id] = Track(position: probe.position, velocity: .zero,
                                         acceleration: .zero, rawVelocity: nil, time: time)
            }

            let hit = map.nearest(to: probe.position, within: reach + probe.kind.radius,
                                  includeObstacles: false)
            var state = RAVEGuardianProbeState(probe: probe, clearance: nil, approachSpeed: 0,
                                               approachAcceleration: 0, timeToContact: nil,
                                               alert: 0, nearest: hit)
            if let hit {
                let clearance = max(0, hit.distance - probe.kind.radius)
                let toward: SIMD3<Float> = hit.distance > 1e-4
                    ? (hit.point - probe.position) / hit.distance
                    : -hit.normal
                let speed = simd_dot(velocity, toward)
                let accelerationToward = simd_dot(acceleration, toward)
                state.clearance = clearance
                state.approachSpeed = speed
                state.approachAcceleration = accelerationToward
                state.timeToContact = speed > 1e-3 ? clearance / speed : nil
                if speed <= Self.rearmApproachSpeed { warningLatched.remove(probe.id) }
                let candidate = Self.acceleratedAlert(clearance: clearance, approachSpeed: speed,
                                                      approachAcceleration: accelerationToward,
                                                      settings: settings)
                let cooldownElapsed = lastWarningTime[probe.id].map {
                    time - $0 >= Self.warningCooldown
                } ?? true
                if candidate > 0, !warningLatched.contains(probe.id), cooldownElapsed {
                    warningLatched.insert(probe.id)
                    lastWarningTime[probe.id] = time
                    warningPulses[probe.id] = WarningPulse(
                        expiresAt: time + Self.warningPulseDuration, strength: candidate)
                }
                if let pulse = warningPulses[probe.id], time <= pulse.expiresAt {
                    state.alert = max(candidate, pulse.strength)
                } else {
                    warningPulses[probe.id] = nil
                }
            } else {
                // Leaving the mapped reach counts as ending the current swing.
                warningLatched.remove(probe.id)
                warningPulses[probe.id] = nil
            }
            frame.peakAlert = max(frame.peakAlert, state.alert)
            frame.probes.append(state)
        }
        tracks = tracks.filter { seen.contains($0.key) }
        lastWarningTime = lastWarningTime.filter { time - $0.value < 5 }
        warningLatched.formIntersection(seen)
        warningPulses = warningPulses.filter { seen.contains($0.key) }

        // Chunk targets.
        let appearance = settings.appearance
        var target: [RAVEGuardianChunkID: Float] = [:]
        for chunk in map.chunks.values {
            if chunk.id.isObstacle {
                guard settings.includesFurniture else { continue }
                let radius = Self.obstacleHologramRadius
                let proximity = frame.probes.lazy
                    .filter { $0.probe.kind != .head }
                    .map { chunk.bounds.distance(to: $0.probe.position) }
                    .filter { $0 < radius }
                    .map { 1 - $0 / radius }
                    .max() ?? 0
                if proximity > 0 { target[chunk.id] = proximity * appearance.obstacleOpacity }
                continue
            }
            var t: Float = 0
            for state in frame.probes where state.alert > 0 {
                let r = state.probe.kind.revealRadius
                let d = chunk.bounds.distance(to: state.probe.position)
                guard d < 2 * r else { continue }
                let falloff: Float = d <= r ? 1 : 1 - (d - r) / r
                t = max(t, state.alert * falloff)
            }
            t *= appearance.maxOpacity
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
