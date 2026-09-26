/*
 RAVE Engine — aligning a desk Quest's tracking space to the ARKit world.

 A Quest parked on a desk streams Touch controller poses in ITS stage space;
 the app needs them in the ARKit world. The old answer was a ritual (hold a
 controller against the headset while a driver samples). This can do better,
 because the app already knows something that ritual never did: the user's
 actual hands, from ARKit, in ARKit space — and the user is already holding the
 controllers with those hands. So every frame where both are tracked is a free
 (Quest controller, ARKit hand) pair, and calibration is just "hold the
 controllers and move your arms" with live progress.

 The solve is deliberately 4-DoF — yaw + translation — not full 6-DoF: both
 spaces are gravity-aligned by their own IMUs, so roll and pitch between them
 are zero by construction, and solving for them anyway would only let
 hand-vs-grip noise leak into two axes that cannot be wrong. Yaw comes from the
 closed-form 2D Kabsch on the floor plane, translation from the centroids.

 On top of the rigid transform, a constant PER-HAND offset in the controller's
 own frame absorbs the geometry the pairs cannot avoid: the ARKit reference is
 a point on the hand, the Quest pose is the Touch controller's grip origin, and
 the two differ by a few rigid centimetres that rotate with the hand.
 Estimating it drops the residual from "a grip's width" to millimetres, which
 is what makes an "aligned ±N mm" readout honest.

 The calibration is CONTINUOUS: the ring keeps re-solving for as long as pairs
 arrive, which tracks a desk headset that settles or a tracking origin that
 drifts. Three things keep that honest:
   - samples carry a WEIGHT (the reference's tracking confidence). A hand
     wrapped around a controller is always somewhat occluded, so this is a
     weight and never a gate — a strict gate would starve the solve, whereas
     weighting still converges on mediocre data and trusts clean frames more;
   - the solve is ROBUST: one pass, then residual-based downweighting past 3×
     the median, then more passes — so a few wrong pairs (a controller paired
     with a hand that was not really holding it) cannot drag yaw for everyone;
   - samples carry a TIMESTAMP and age out after `sampleMaxAgeMs`, so the ring
     tracks drift instead of averaging the whole session into a stale mean.

 Ported from the Longwave PCVR host's C++ solver, constants and all; the unit
 tests are ported with it. Pure arithmetic, an isolation-free value type: the
 owner calls it from whatever thread samples the hands.

 Rotation convention, everywhere in this file: yaw is a right-handed rotation
 about +Y, x' = x·cos + z·sin, z' = −x·sin + z·cos — the same rotation as
 simd_quatf(angle: yaw, axis: +Y). The tests pin the two against each other; a
 flipped sign doubles the yaw error instead of cancelling it.
 */

import simd

public struct RAVEQuestCalibration: Sendable {

    // MARK: Constants

    /// Ring size per hand; ~30 s of gated sampling.
    public static let maxSamplesPerHand = 120
    /// Minimum kept pairs, across both hands, before the first solve.
    public static let minSamples = 24
    /// Diagonal floor-plane extent of the references needed to condition yaw.
    public static let spreadTargetMeters: Float = 0.25
    /// A new pair must be this far from its hand's previous kept one — a
    /// resting hand must not fill the ring with one point.
    public static let minSpacingMeters: Float = 0.03
    /// New pairs between re-solves once calibrated.
    public static let resolveEverySamples = 12
    /// Samples older than this are dropped at the next `maybeSolve`, so the
    /// transform follows drift over roughly a minute rather than averaging the
    /// session. Only enforced when the caller supplies timestamps (nowMs != 0).
    public static let sampleMaxAgeMs: UInt64 = 60_000
    /// Floor for a sample's weight: even a fully occluded pair keeps a vote,
    /// because starving the ring is worse than a noisy contribution the robust
    /// pass can still demote.
    public static let minWeight: Float = 0.05
    /// Robust pass: residuals beyond this many medians are downweighted by
    /// (threshold/residual)⁴.
    public static let outlierMedians: Float = 3.0
    /// Floor on that threshold, so ultra-clean rings do not eat their own tail
    /// — with sub-centimetre residuals, 3× the median is still normal tracking
    /// noise, not an outlier.
    public static let outlierFloorMeters: Float = 0.02

    // MARK: Solved transform

    /// The solved transform, restorable across launches.
    public struct Transform: Sendable, Equatable, Codable {
        /// Radians about +Y, Quest → reference.
        public var yaw: Float
        /// Metres, reference space.
        public var translation: SIMD3<Float>
        /// Per-hand constant offset in the controller's own frame, metres.
        public var leftOffset: SIMD3<Float>
        public var rightOffset: SIMD3<Float>

        public init(yaw: Float, translation: SIMD3<Float>,
                    leftOffset: SIMD3<Float> = .zero, rightOffset: SIMD3<Float> = .zero) {
            self.yaw = yaw
            self.translation = translation
            self.leftOffset = leftOffset
            self.rightOffset = rightOffset
        }
    }

    // MARK: State

    struct Sample: Sendable {
        var quest: SIMD3<Float>
        var questRot: simd_quatf
        var ref: SIMD3<Float>
        var weight: Float
        /// `addSample`'s nowMs; 0 = untimestamped (never ages out).
        var ms: UInt64
    }

    private static let emptySample = Sample(quest: .zero, questRot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                            ref: .zero, weight: 0, ms: 0)

    private var samples: [[Sample]] = Array(
        repeating: Array(repeating: emptySample, count: maxSamplesPerHand), count: 2)
    private var count: [Int] = [0, 0]
    private var next: [Int] = [0, 0]                // ring cursor
    private var lastKept: [SIMD3<Float>] = [.zero, .zero]   // spacing gate, valid when count > 0
    private var samplesSinceSolve = 0

    public private(set) var isCalibrated = false
    private var yaw: Float = 0
    private var translation = SIMD3<Float>.zero
    private var handOffset: [SIMD3<Float>] = [.zero, .zero]
    private var residualMmValue: Float = 0

    public init() {}

    // MARK: Queries

    public var sampleCount: Int { count[0] + count[1] }

    /// RMS pair error after the full transform (yaw + translation + hand
    /// offsets), millimetres. 0 until solved, and 0 after a restore until fresh
    /// pairs re-solve.
    public var residualMm: Float { isCalibrated ? residualMmValue : 0 }

    /// The solved transform, or nil before the first solve.
    public var transform: Transform? {
        guard isCalibrated else { return nil }
        return Transform(yaw: yaw, translation: translation,
                         leftOffset: handOffset[0], rightOffset: handOffset[1])
    }

    /// Diagonal extent of the reference positions on the floor plane. Spread,
    /// not count, is what conditions the yaw — this is the number a HUD nags
    /// about.
    public var spreadMeters: Float {
        var any = false
        var minX: Float = 0, maxX: Float = 0, minZ: Float = 0, maxZ: Float = 0
        for hand in 0..<2 {
            for i in 0..<count[hand] {
                let s = samples[hand][i]
                if !any {
                    minX = s.ref.x; maxX = s.ref.x
                    minZ = s.ref.z; maxZ = s.ref.z
                    any = true
                    continue
                }
                minX = min(minX, s.ref.x); maxX = max(maxX, s.ref.x)
                minZ = min(minZ, s.ref.z); maxZ = max(maxZ, s.ref.z)
            }
        }
        guard any else { return 0 }
        let dx = maxX - minX, dz = maxZ - minZ
        return (dx * dx + dz * dz).squareRoot()
    }

    // MARK: Sampling

    /// Offer a pair for `chirality`: the Quest controller pose in Quest space
    /// and the reference (ARKit hand) position for the same hand. Kept only if
    /// far enough from that hand's previous kept sample. `weight` in (0, 1] is
    /// how much this pair counts; `nowMs` timestamps it for age-out (0 = never
    /// ages). Returns whether the pair was kept.
    @discardableResult
    public mutating func addSample(_ chirality: RAVEHandChirality, questPosition: SIMD3<Float>,
                                   questRotation: simd_quatf, reference: SIMD3<Float>,
                                   weight: Float = 1, nowMs: UInt64 = 0) -> Bool {
        let hand = Self.index(chirality)
        if count[hand] > 0,
           simd_distance_squared(reference, lastKept[hand]) < Self.minSpacingMeters * Self.minSpacingMeters {
            return false
        }
        samples[hand][next[hand]] = Sample(
            quest: questPosition, questRot: questRotation, ref: reference,
            weight: min(max(weight, Self.minWeight), 1), ms: nowMs)
        lastKept[hand] = reference
        next[hand] = (next[hand] + 1) % Self.maxSamplesPerHand
        if count[hand] < Self.maxSamplesPerHand { count[hand] += 1 }
        samplesSinceSolve += 1
        return true
    }

    /// Re-solve when enough new material has arrived, evicting samples older
    /// than `sampleMaxAgeMs` first (when nowMs != 0). Returns true when the
    /// transform (re)computed this call. Cheap to call every frame. An aged-out
    /// ring never un-solves: the last transform stands until fresh pairs
    /// replace it.
    @discardableResult
    public mutating func maybeSolve(nowMs: UInt64 = 0) -> Bool {
        evictStale(nowMs: nowMs)
        if sampleCount < Self.minSamples { return false }
        if isCalibrated && samplesSinceSolve < Self.resolveEverySamples { return false }
        if spreadMeters < Self.spreadTargetMeters { return false }
        solveNow()
        samplesSinceSolve = 0
        return true
    }

    // MARK: Applying

    /// Quest pose → reference space. Identity until calibrated.
    public func apply(_ chirality: RAVEHandChirality, position: SIMD3<Float>,
                      rotation: simd_quatf) -> (position: SIMD3<Float>, rotation: simd_quatf) {
        guard isCalibrated else { return (position, rotation) }
        return Self.place(position: position, rotation: rotation, yaw: yaw,
                          translation: translation, offset: handOffset[Self.index(chirality)])
    }

    /// Instantaneous transformed-pair distance, positions only, for a
    /// moved-desk watchdog: a calibrated transform whose fresh pairs suddenly
    /// disagree by decimetres means the desk headset moved, and the right
    /// response is `reset()`, not a slow blend. The hand offset is left out —
    /// it is orientation-dependent and this check runs when nothing may be
    /// trusted — so thresholds must absorb a grip's width. 0 until calibrated.
    public func pairErrorMeters(_ chirality: RAVEHandChirality, questPosition: SIMD3<Float>,
                                reference: SIMD3<Float>) -> Float {
        guard isCalibrated else { return 0 }
        let placed = Self.rotateYaw(yaw, questPosition) + translation
        return simd_distance(placed, reference)
    }

    // MARK: Lifecycle

    public mutating func reset() {
        count = [0, 0]
        next = [0, 0]
        samplesSinceSolve = 0
        isCalibrated = false
        yaw = 0
        translation = .zero
        handOffset = [.zero, .zero]
        residualMmValue = 0
    }

    /// Restore a solved state with zero samples — a warm start: applied
    /// immediately, and the first fresh pairs either confirm it or a watchdog
    /// resets it.
    public mutating func restore(_ transform: Transform) {
        reset()
        yaw = transform.yaw
        translation = transform.translation
        handOffset = [transform.leftOffset, transform.rightOffset]
        isCalibrated = true
        residualMmValue = 0           // unknown until fresh pairs confirm it
    }

    // MARK: Solver

    private mutating func evictStale(nowMs: UInt64) {
        guard nowMs != 0 else { return }
        for hand in 0..<2 where count[hand] > 0 {
            // Walk the ring oldest-first so the compacted array keeps age order
            // and `next` lands back on the oldest slot when full.
            let start = count[hand] == Self.maxSamplesPerHand ? next[hand] : 0
            var kept: [Sample] = []
            kept.reserveCapacity(count[hand])
            for i in 0..<count[hand] {
                let s = samples[hand][(start + i) % Self.maxSamplesPerHand]
                if s.ms != 0 && s.ms + Self.sampleMaxAgeMs < nowMs { continue }
                kept.append(s)
            }
            if kept.count == count[hand] { continue }
            for (i, s) in kept.enumerated() { samples[hand][i] = s }
            count[hand] = kept.count
            next[hand] = kept.count % Self.maxSamplesPerHand
        }
    }

    /// One weighted alternating solve (rigid + per-hand offsets) using
    /// weight × robust[hand][i] per sample.
    private mutating func solvePass(robust: [[Float]]) {
        // The rigid solve and the per-hand offsets are coupled: the offsets are
        // baked into the reference positions the Kabsch sees, and because they
        // DIFFER between hands they do not cancel at the centroid — a one-shot
        // solve leaves a few millimetres of structured error. So alternate:
        // rigid solve against offset-corrected references, re-estimate the
        // offsets from the leftovers, repeat. The offsets are centimetres
        // against a solve spread of decimetres, so three rounds land within
        // float noise of exact on clean data (pinned by the unit tests).
        func effW(_ hand: Int, _ i: Int) -> Float { samples[hand][i].weight * robust[hand][i] }

        handOffset = [.zero, .zero]
        for _ in 0..<3 {
            // Centroids over every kept pair, both hands together — one desk
            // headset, one transform, the second hand only adds constraint.
            // References are corrected by the current offset estimate (zero on
            // the first round).
            let yawQ = Self.yawQuat(yaw)
            let offsets = handOffset
            func correctedRef(_ hand: Int, _ s: Sample) -> SIMD3<Float> {
                s.ref - (yawQ * s.questRot).act(offsets[hand])
            }

            // Closed-form WEIGHTED 2D Kabsch on the floor plane — centred PER
            // HAND, not globally: each hand carries its own roughly constant
            // grip offset, and against a global centroid those offsets do not
            // cancel, they lean the yaw. Against its own hand's weighted
            // centroid a constant offset vanishes exactly.
            var cq = SIMD3<Float>.zero, cr = SIMD3<Float>.zero   // weighted global sums
            var totalW: Float = 0
            var dot: Float = 0, cross: Float = 0
            for hand in 0..<2 where count[hand] > 0 {
                var hq = SIMD3<Float>.zero, hr = SIMD3<Float>.zero
                var handW: Float = 0
                for i in 0..<count[hand] {
                    let w = effW(hand, i)
                    hq += w * samples[hand][i].quest
                    hr += w * correctedRef(hand, samples[hand][i])
                    handW += w
                }
                if handW <= 0 { continue }
                cq += hq
                cr += hr
                hq /= handW
                hr /= handW
                totalW += handW
                for i in 0..<count[hand] {
                    let w = effW(hand, i)
                    let ref = correctedRef(hand, samples[hand][i])
                    let qx = samples[hand][i].quest.x - hq.x
                    let qz = samples[hand][i].quest.z - hq.z
                    let rx = ref.x - hr.x
                    let rz = ref.z - hr.z
                    dot += w * (qx * rx + qz * rz)
                    cross += w * (qz * rx - qx * rz)
                }
            }
            if totalW <= 0 { return }
            yaw = atan2(cross, dot)
            cq /= totalW
            cr /= totalW
            translation = cr - Self.rotateYaw(yaw, cq)

            // Per-hand constant offset in the controller's own frame: the
            // weighted mean leftover vector against the UNCORRECTED references,
            // carried into local coordinates so it rotates with the hand. Hands
            // with no samples keep a zero offset.
            let solvedYawQ = Self.yawQuat(yaw)
            for hand in 0..<2 {
                var acc = SIMD3<Float>.zero
                var handW: Float = 0
                for i in 0..<count[hand] {
                    let w = effW(hand, i)
                    let s = samples[hand][i]
                    let placed = Self.rotateYaw(yaw, s.quest) + translation
                    let leftoverWorld = s.ref - placed
                    let placedRot = solvedYawQ * s.questRot
                    acc += w * placedRot.inverse.act(leftoverWorld)
                    handW += w
                }
                handOffset[hand] = handW > 0 ? acc / handW : .zero
            }
        }
    }

    private mutating func solveNow() {
        guard sampleCount > 0 else { return }

        // Pass 1: every sample votes with its own confidence weight.
        var robust = Array(repeating: Array(repeating: Float(1), count: Self.maxSamplesPerHand), count: 2)
        solvePass(robust: robust)
        isCalibrated = true

        // Robust rounds: residual per pair against the current transform,
        // downweight everything beyond `outlierMedians` × the median, solve
        // again — iterated, because each cleaner fit shrinks the median and
        // demotes the outliers harder. This is what lets a stray pairing — a
        // controller that was not really in that hand — cost millimetres
        // instead of degrees: no confidence value can flag it, because both
        // poses were genuinely tracked, just not describing the same object.
        // Weights are recomputed from scratch each round, so a pair demoted by
        // an early bad fit is rehabilitated once the fit says it was fine.
        //
        // Five rounds and a 4th-power demotion are empirical, pinned by the
        // unit test: at 15% contamination (half-metre wrong pairs at full
        // confidence), squared demotion over three rounds still left ~2° of
        // yaw, because the first dragged fit inflates the clean median and the
        // threshold with it — each round only halves the damage. The harder
        // ramp converges the same case to sub-millimetre.
        for _ in 0..<5 {
            var residual = Array(repeating: Array(repeating: Float(0), count: Self.maxSamplesPerHand), count: 2)
            var sorted: [Float] = []
            sorted.reserveCapacity(sampleCount)
            for hand in 0..<2 {
                for i in 0..<count[hand] {
                    let s = samples[hand][i]
                    let placed = placeSample(hand, s)
                    residual[hand][i] = simd_distance(placed, s.ref)
                    sorted.append(residual[hand][i])
                }
            }
            // nth_element(n/2) in the original: the upper median.
            sorted.sort()
            let median = sorted[sorted.count / 2]
            let threshold = max(Self.outlierMedians * median, Self.outlierFloorMeters)
            var anyOutlier = false
            for hand in 0..<2 {
                for i in 0..<count[hand] {
                    if residual[hand][i] > threshold {
                        let ratio = threshold / residual[hand][i]
                        robust[hand][i] = (ratio * ratio) * (ratio * ratio)
                        anyOutlier = true
                    } else {
                        robust[hand][i] = 1
                    }
                }
            }
            if !anyOutlier { break }
            solvePass(robust: robust)
        }

        // Residual AFTER the offsets — the figure a HUD shows has to describe
        // the transform the app actually gets. Weighted by the same effective
        // weights the solve used, so a demoted outlier does not smear the
        // number describing the transform it barely influenced.
        var sumSq: Float = 0, sumW: Float = 0
        for hand in 0..<2 {
            for i in 0..<count[hand] {
                let s = samples[hand][i]
                let placed = placeSample(hand, s)
                let w = s.weight * robust[hand][i]
                sumSq += w * simd_distance_squared(placed, s.ref)
                sumW += w
            }
        }
        residualMmValue = sumW > 0 ? (sumSq / sumW).squareRoot() * 1000 : 0
    }

    private func placeSample(_ hand: Int, _ s: Sample) -> SIMD3<Float> {
        Self.place(position: s.quest, rotation: s.questRot, yaw: yaw,
                   translation: translation, offset: handOffset[hand]).position
    }

    // MARK: Math

    static func index(_ chirality: RAVEHandChirality) -> Int { chirality == .left ? 0 : 1 }

    /// Rotation about +Y by `yaw`: x' = x·cos + z·sin, z' = −x·sin + z·cos.
    static func rotateYaw(_ yaw: Float, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z)
    }

    /// The quaternion matching `rotateYaw`: x' = x·cos + z·sin is the
    /// canonical right-handed rotation about +Y (check: (0,0,1) → (sin,0,cos)
    /// both ways), so the half-angle carries yaw's own sign.
    static func yawQuat(_ yaw: Float) -> simd_quatf {
        simd_quatf(ix: 0, iy: sin(yaw * 0.5), iz: 0, r: cos(yaw * 0.5))
    }

    static func place(position: SIMD3<Float>, rotation: simd_quatf, yaw: Float,
                      translation: SIMD3<Float>, offset: SIMD3<Float>)
        -> (position: SIMD3<Float>, rotation: simd_quatf) {
        let placed = rotateYaw(yaw, position) + translation
        let placedRot = yawQuat(yaw) * rotation
        return (placed + placedRot.act(offset), placedRot)
    }
}
