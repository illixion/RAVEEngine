/*
 RAVE Engine — fitting the body stream's space to the headset's world.

 The cameras' world and the headset's are both gravity-aligned (the hub levels
 its cameras by their accelerometers, ARKit by the headset's), so what is left
 between them is a turn about +Y and an offset: 4 degrees of freedom, as for
 `RAVEQuestCalibration`, and solved the same way: the closed-form 2D Kabsch on
 the floor plane for yaw, centroids for the translation, then robust passes.

 The pairs are free. The headset knows where its wearer's head and wrists are,
 and the cameras see the same head and wrists, so every frame both have gives
 a pair: no ritual, just "move your arms about". Wrists carry most of the fit,
 since arms sweep a wide spread quickly and the two trackers agree on where a
 wrist is to a centimetre or two. The head anchors it as the wearer walks,
 with a lower weight: the cameras put it between the ears, the headset between
 the eyes, and the fixed offset bridging the two (`headOffset`) is an
 anthropometric estimate. Its vertical error, if any, lands in the floor's
 height.

 Unlike the Quest calibration there is no per-anchor offset to solve: a
 BlazePose wrist and an ARKit wrist are the same anatomical point, near
 enough, and a free offset per wrist would trade against the translation.

 Timing matters more here than there: a camera frame is 50–90 ms old when it
 arrives, so the source pairs it with where the headset had the head and
 wrists *then*, and leaves out pairs taken while an anchor moved fast.

 Rotation convention: yaw is right-handed about +Y, the rotation of
 `simd_quatf(angle: yaw, axis: +Y)`, x' = x·cos + z·sin, z' = −x·sin + z·cos.
 Pure arithmetic, an isolation-free value type.
 */

import simd

public struct RAVEBodyAlignment: Sendable {

    /// What a pair measures.
    public enum Anchor: Int, CaseIterable, Sendable {
        case head, leftWrist, rightWrist
    }

    // MARK: Constants

    /// Ring size across all anchors: about 20 s of moving arms.
    public static let maxSamples = 360
    /// Kept pairs before the first solve.
    public static let minSamples = 40
    /// Diagonal floor-plane extent of the world points needed for yaw to be
    /// trusted. Arms out and a step to the side reach it.
    public static let spreadTargetMeters: Float = 0.6
    /// A pair must be this far from its anchor's previous kept one: a still
    /// performer must not fill the ring with one point.
    public static let minSpacingMeters: Float = 0.04
    /// New pairs between re-solves once aligned.
    public static let resolveEverySamples = 20
    /// Pairs older than this drop out, so the fit follows drift.
    public static let sampleMaxAge: Double = 60
    public static let minWeight: Float = 0.05
    /// Robust passes: residuals beyond this many medians are downweighted by
    /// (threshold/residual)⁴, but never below the floor, which is normal
    /// disagreement between two trackers of a wrist.
    public static let outlierMedians: Float = 3.0
    public static let outlierFloorMeters: Float = 0.04
    public static let robustPasses = 3
    public static let maxResidualMeters: Float = 0.08
    public static let minConfidence: Float = 0.3
    /// Where the headset's origin sits in the stream's head frame (+X left,
    /// +Y up, +Z forward), measured from between the ears: the eyes are about
    /// 8.5 cm in front of the ear canals and 2 cm above them.
    public static let headOffset = SIMD3<Float>(0, 0.02, 0.085)
    /// The head's weight relative to a wrist's.
    public static let headWeight: Float = 0.5

    public struct Transform: Sendable, Equatable, Codable {
        /// Radians about +Y, stream → world.
        public var yaw: Float
        /// Metres, world space. Its y is the stream's floor in the world.
        public var translation: SIMD3<Float>

        public init(yaw: Float, translation: SIMD3<Float>) {
            self.yaw = yaw
            self.translation = translation
        }

        public func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
            RAVEBodyAlignment.rotateYaw(yaw, point) + translation
        }

        /// A direction (a camera's forward) carried into the world: turned,
        /// not moved.
        public func rotate(_ direction: SIMD3<Float>) -> SIMD3<Float> {
            RAVEBodyAlignment.rotateYaw(yaw, direction)
        }
    }

    struct Sample: Sendable {
        var anchor: Anchor
        var stream: SIMD3<Float>
        var world: SIMD3<Float>
        var weight: Float
        var time: Double
    }

    // MARK: State

    private var samples: [Sample] = []
    private var lastKept: [Anchor: SIMD3<Float>] = [:]
    private var samplesSinceSolve = 0
    public private(set) var transform: Transform?
    /// RMS pair distance after the fit, metres; 0 before it.
    public private(set) var residual: Float = 0

    public init() {}

    public var isAligned: Bool { transform != nil }
    public var sampleCount: Int { samples.count }

    /// Diagonal extent of the world points on the floor plane.
    public var spreadMeters: Float {
        guard let first = samples.first else { return 0 }
        var lo = SIMD2(first.world.x, first.world.z), hi = lo
        for s in samples {
            let p = SIMD2(s.world.x, s.world.z)
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return simd_length(hi - lo)
    }

    // MARK: Sampling

    /// Offer a pair: the same point in the stream's space and in the world.
    /// Kept only when its anchor has moved `minSpacingMeters` since the last
    /// one kept. Returns whether it was kept.
    @discardableResult
    public mutating func addSample(_ anchor: Anchor, stream: SIMD3<Float>, world: SIMD3<Float>,
                                   weight: Float = 1, time: Double) -> Bool {
        guard stream.isFinite, world.isFinite, time.isFinite, weight.isFinite,
              weight >= Self.minConfidence else { return false }
        if let last = lastKept[anchor], simd_distance_squared(world, last) < Self.minSpacingMeters * Self.minSpacingMeters {
            return false
        }
        lastKept[anchor] = world
        samples.append(Sample(anchor: anchor, stream: stream, world: world,
                              weight: min(max(weight, Self.minWeight), 1), time: time))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        samplesSinceSolve += 1
        return true
    }

    /// Re-solves once enough new pairs have come in, dropping old ones first.
    /// Cheap to call every frame. Returns whether it solved.
    @discardableResult
    public mutating func maybeSolve(now: Double) -> Bool {
        samples.removeAll { now - $0.time > Self.sampleMaxAge }
        guard samples.count >= Self.minSamples, spreadMeters >= Self.spreadTargetMeters else { return false }
        if transform != nil, samplesSinceSolve < Self.resolveEverySamples { return false }
        solve()
        samplesSinceSolve = 0
        return true
    }

    public mutating func reset() {
        samples.removeAll()
        lastKept.removeAll()
        samplesSinceSolve = 0
        transform = nil
        residual = 0
    }

    /// How far a pair lands from its world point under the current fit,
    /// metres: nil before one. A fit whose fresh pairs disagree by decimetres
    /// is stale (a camera moved, the headset recentred) and wants `reset()`.
    public func error(stream: SIMD3<Float>, world: SIMD3<Float>) -> Float? {
        transform.map { simd_distance($0.apply(stream), world) }
    }

    // MARK: Solver

    private mutating func solve() {
        var robust = [Float](repeating: 1, count: samples.count)
        var fit = Transform(yaw: 0, translation: .zero)
        for pass in 0..<Self.robustPasses {
            fit = Self.fit(samples, robust)
            let errors = samples.map { simd_distance(fit.apply($0.stream), $0.world) }
            if pass == Self.robustPasses - 1 { break }
            let median = errors.sorted()[errors.count / 2]
            let threshold = max(median * Self.outlierMedians, Self.outlierFloorMeters)
            robust = errors.map { $0 > threshold ? pow(threshold / $0, 4) : 1 }
        }
        var sum: Float = 0, weights: Float = 0
        for (s, r) in zip(samples, robust) {
            sum += s.weight * r * simd_distance_squared(fit.apply(s.stream), s.world)
            weights += s.weight * r
        }
        residual = weights > 0 ? (sum / weights).squareRoot() : 0
        // A tiny cluster of inliers must not certify a mostly wrong fit.
        let inliers = samples.filter { simd_distance(fit.apply($0.stream), $0.world) <= Self.maxResidualMeters * 1.5 }.count
        transform = residual.isFinite && residual <= Self.maxResidualMeters && inliers * 10 >= samples.count * 7
            ? fit : nil
        if transform == nil {
            // Do not make a moved camera wait sixty seconds for old pairs
            // to age out. Keep the residual for diagnostics, collect afresh.
            samples.removeAll()
            lastKept.removeAll()
        }
    }

    static func fit(_ samples: [Sample], _ robust: [Float]) -> Transform {
        var total: Float = 0
        var cs = SIMD3<Float>.zero, cw = SIMD3<Float>.zero
        for (s, r) in zip(samples, robust) {
            let w = s.weight * r
            total += w
            cs += w * s.stream
            cw += w * s.world
        }
        guard total > 0 else { return Transform(yaw: 0, translation: .zero) }
        cs /= total
        cw /= total
        var dot: Float = 0, cross: Float = 0
        for (s, r) in zip(samples, robust) {
            let w = s.weight * r
            let a = s.stream - cs, b = s.world - cw
            dot += w * (a.x * b.x + a.z * b.z)
            cross += w * (a.z * b.x - a.x * b.z)
        }
        let yaw = atan2(cross, dot)
        return Transform(yaw: yaw, translation: cw - rotateYaw(yaw, cs))
    }

    static func rotateYaw(_ yaw: Float, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }
}
