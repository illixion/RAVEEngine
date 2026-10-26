import simd

/// Source-independent body observations. A camera adapter maps its landmarks
/// here; the solver knows nothing about PoseHub, ARKit or RealityKit.
public struct PerformerBodyObservation: Sendable {
    public struct Arm: Sendable {
        public var wrist: SIMD3<Float>
        public var elbow: SIMD3<Float>?
        public var confidence: Float
        public init(wrist: SIMD3<Float>, elbow: SIMD3<Float>?, confidence: Float) {
            self.wrist = wrist; self.elbow = elbow; self.confidence = confidence
        }
    }
    public var lower: TrackedLegs.Input?
    public var chest: simd_quatf?
    public var chestConfidence: Float
    public var left: Arm?
    public var right: Arm?
    public init(lower: TrackedLegs.Input?, chest: simd_quatf? = nil, chestConfidence: Float = 0,
                left: Arm? = nil, right: Arm? = nil) {
        self.lower = lower; self.chest = chest; self.chestConfidence = chestConfidence
        self.left = left; self.right = right
    }
}

/// Owns tracking policy once for all avatar consumers. Headset head and hands
/// win; cameras supply torso and hidden arms; missing legs return independently
/// to the gait. All state is an isolation-free value type.
public struct PerformerBodyTracking: Sendable {
    public private(set) var legs = TrackedLegs()
    private var chest: simd_quatf?
    private var chestWeight: Float = 0
    public init() {}

    public struct Solution: Sendable {
        public var frame: PerformerFrame?
        public var lowerBody: PerformerLowerBody?
        public var cameraArms: [Bool]
    }

    public mutating func reset() { self = Self() }

    public mutating func update(_ observed: PerformerBodyObservation?, headset: PerformerFrame?,
                                fallback: PerformerLowerBody?, deltaTime: Float) -> Solution {
        let dt = max(0, deltaTime)
        let lower = legs.update(observed?.lower, deltaTime: dt, fallback: fallback) ?? fallback
        let seesChest = observed?.chest != nil && (observed?.chestConfidence ?? 0) >= 0.3
        if seesChest { chest = observed?.chest }
        chestWeight = seesChest ? min(1, chestWeight + dt / 0.25) : max(0, chestWeight - dt / 0.4)
        var frame = headset
        if frame != nil, let chest, chestWeight > 0 {
            frame?.torso = PerformerTorso(rotation: chest, weight: chestWeight)
        }
        var cameraArms = [false, false]
        func arm(_ live: PerformerHand?, _ camera: PerformerBodyObservation.Arm?, slot: Int) -> PerformerHand? {
            guard let camera, camera.confidence >= 0.3 else { return live }
            if var live {
                if live.forearm == nil { live.forearm = camera.elbow }
                return live
            }
            cameraArms[slot] = true
            // A camera wrist is arm position, never measured fingers.
            return PerformerHand(wrist: camera.wrist, forearm: camera.elbow, thumb: [], fingers: [])
        }
        if var f = frame {
            f.left = arm(f.left, observed?.left, slot: 0)
            f.right = arm(f.right, observed?.right, slot: 1)
            frame = f
        }
        return Solution(frame: frame, lowerBody: lower, cameraArms: cameraArms)
    }
}
