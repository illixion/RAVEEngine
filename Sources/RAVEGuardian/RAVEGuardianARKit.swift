/*
 RAVE Engine — the guardian's ARKit half: barrier triangles from a
 `MeshAnchor`, probes from the device and hand anchors, and a small sensor
 that runs its own scene reconstruction (plus world tracking for the head)
 for an app that has none.

 Apps that already run a `SceneReconstructionProvider` feed its updates to
 `RAVEGuardian.ingest(_:)` instead of starting the sensor
 (spatial-ai-character does); a second reconstruction provider in another
 session would work but costs the same meshing twice.

 visionOS only. The simulator has no scene reconstruction, so the sensor
 stays idle there and the guardian simply has nothing to draw.
 */

#if os(visionOS)

import ARKit
import DebugLog
import Foundation
import QuartzCore
import simd

extension RAVEGuardianSurface {
    /// The barrier kind of an ARKit face class; floor, ceiling and stairs are
    /// not barriers.
    public init?(_ classification: SurfaceClassification) {
        switch classification {
        case .wall: self = .wall
        case .door: self = .door
        case .window: self = .window
        case .floor, .ceiling, .stairs: return nil
        // Furniture, appliances, screens, plants and unclassified clutter:
        // all things to keep a hand off, shown only with furniture on.
        default: self = .obstacle
        }
    }
}

public enum RAVEGuardianMeshExtraction {

    /// One anchor's barrier triangles in world space, plus the height of its
    /// lowest floor faces (nil when it holds no floor).
    public static func barriers(of anchor: MeshAnchor, floorY knownFloor: Float?)
        -> (triangles: [RAVEGuardianTriangle], floorY: Float?) {
        let geometry = anchor.geometry
        let transform = anchor.originFromAnchorTransform
        let vertices = read3(geometry.vertices)
        let normals = read3(geometry.normals)
        guard !vertices.isEmpty else { return ([], nil) }
        let world = vertices.map { v -> SIMD3<Float> in
            let w = transform * SIMD4<Float>(v, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let faces = geometry.faces
        let faceCount = faces.count
        let classes = readClasses(geometry.classifications, count: faceCount)

        // Floor first: the obstacle height filter is relative to it.
        var floorY: Float?
        if let classes {
            for f in 0..<faceCount where classes[f] == UInt8(SurfaceClassification.floor.rawValue) {
                let idx = indices(faces, f)
                let y = min(world[Int(idx.0)].y, world[Int(idx.1)].y, world[Int(idx.2)].y)
                floorY = min(floorY ?? y, y)
            }
        }
        let floor = knownFloor.map { k in floorY.map { min($0, k) } ?? k } ?? floorY

        var out: [RAVEGuardianTriangle] = []
        out.reserveCapacity(faceCount / 2)
        for f in 0..<faceCount {
            // An unclassified mesh (no classification mode) treats every face
            // as a candidate wall; the orientation filter keeps the vertical ones.
            let surface: RAVEGuardianSurface
            if let classes {
                let raw = classes[f]
                guard let cls = SurfaceClassification(rawValue: SurfaceClassification.RawValue(raw)),
                      let s = RAVEGuardianSurface(cls) else { continue }
                surface = s
            } else {
                surface = .wall
            }
            let idx = indices(faces, f)
            let i0 = Int(idx.0), i1 = Int(idx.1), i2 = Int(idx.2)
            guard i0 < world.count, i1 < world.count, i2 < world.count else { continue }
            var inward: SIMD3<Float>?
            if normals.count == vertices.count {
                inward = rotation * (normals[i0] + normals[i1] + normals[i2])
            }
            guard let t = RAVEGuardianTriangle(world[i0], world[i1], world[i2],
                                               inward: inward, surface: surface),
                  RAVEGuardianFaceFilter.accepts(t, floorY: floor) else { continue }
            out.append(t)
        }
        return (out, floorY)
    }

    private static func read3(_ source: GeometrySource) -> [SIMD3<Float>] {
        guard source.format == .float3 else { return [] }
        let base = source.buffer.contents().advanced(by: source.offset)
        return (0..<source.count).map { i in
            let p = base.advanced(by: i * source.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }
    }

    private static func readClasses(_ source: GeometrySource?, count: Int) -> [UInt8]? {
        guard let source, source.count >= count else { return nil }
        let base = source.buffer.contents().advanced(by: source.offset)
        return (0..<count).map { i in
            base.advanced(by: i * source.stride).assumingMemoryBound(to: UInt8.self).pointee
        }
    }

    private static func indices(_ faces: GeometryElement, _ face: Int) -> (UInt32, UInt32, UInt32) {
        let base = faces.buffer.contents()
        let stride = faces.bytesPerIndex * faces.primitive.indexCount
        let p = base.advanced(by: face * stride)
        if faces.bytesPerIndex == 2 {
            let q = p.assumingMemoryBound(to: UInt16.self)
            return (UInt32(q[0]), UInt32(q[1]), UInt32(q[2]))
        }
        let q = p.assumingMemoryBound(to: UInt32.self)
        return (q[0], q[1], q[2])
    }
}

extension RAVEGuardianProbe {

    /// The head, from the device anchor's transform.
    public static func head(_ originFromDevice: simd_float4x4) -> RAVEGuardianProbe {
        RAVEGuardianProbe(id: "head", kind: .head,
                          position: SIMD3(originFromDevice.columns.3.x,
                                          originFromDevice.columns.3.y,
                                          originFromDevice.columns.3.z))
    }

    /// A tracked hand as three points: mid-palm and the index and middle
    /// fingertips (the parts that reach a wall first in a swing or a punch).
    /// Empty for an untracked hand.
    public static func hand(_ anchor: HandAnchor) -> [RAVEGuardianProbe] {
        guard anchor.isTracked else { return [] }
        let side = anchor.chirality == .left ? "left" : "right"
        let origin = anchor.originFromAnchorTransform
        guard let skeleton = anchor.handSkeleton else {
            return [RAVEGuardianProbe(id: "hand.\(side).palm", kind: .hand,
                                      position: SIMD3(origin.columns.3.x, origin.columns.3.y, origin.columns.3.z))]
        }
        func p(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let m = origin * joint.anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        var out: [RAVEGuardianProbe] = []
        if let wrist = p(.wrist), let knuckle = p(.middleFingerKnuckle) {
            out.append(.init(id: "hand.\(side).palm", kind: .hand, position: (wrist + knuckle) / 2))
        }
        if let tip = p(.indexFingerTip) { out.append(.init(id: "hand.\(side).index", kind: .hand, position: tip)) }
        if let tip = p(.middleFingerTip) { out.append(.init(id: "hand.\(side).middle", kind: .hand, position: tip)) }
        return out
    }
}

/// Runs scene reconstruction and world tracking for the guardian when the app
/// has neither. Asks for world-sensing permission, so the app's Info.plist
/// needs `NSWorldSensingUsageDescription` (ARKit aborts on a request whose
/// usage string is missing rather than denying it).
@MainActor
public final class RAVEGuardianWorldSensor {
    public private(set) var isRunning = false
    private var session: ARKitSession?
    private var world: WorldTrackingProvider?
    private var task: Task<Void, Never>?
    private let log: (@Sendable (DebugLogMessage) -> Void)?

    public init(log: (@Sendable (DebugLogMessage) -> Void)? = nil) {
        self.log = log
    }

    /// Start feeding `guardian` (the RealityKit guardian, a Metal overlay, or
    /// the bare world). Safe to call repeatedly.
    public func start(feeding guardian: any RAVEGuardianMeshSink) {
        guard task == nil else { return }
        guard SceneReconstructionProvider.isSupported else {
            log?("guardian: scene reconstruction unsupported here — idle")
            return
        }
        task = Task { [weak self, weak guardian] in
            let session = ARKitSession()
            var status = await session.queryAuthorization(for: [.worldSensing])[.worldSensing]
            if status == .notDetermined {
                status = await session.requestAuthorization(for: [.worldSensing])[.worldSensing]
            }
            guard status == .allowed, !Task.isCancelled else {
                self?.log?("guardian: world sensing not allowed — idle")
                self?.task = nil
                return
            }
            let mesh = SceneReconstructionProvider(modes: [.classification])
            let world = WorldTrackingProvider()
            do {
                try await session.run([mesh, world])
            } catch {
                self?.log?("guardian: ARKit session failed: \(String(describing: error))")
                self?.task = nil
                return
            }
            self?.session = session
            self?.world = world
            self?.isRunning = true
            self?.log?("guardian: world sensor running")
            for await update in mesh.anchorUpdates {
                if Task.isCancelled { break }
                switch update.event {
                case .added, .updated: guardian?.ingest(update.anchor)
                case .removed: guardian?.remove(anchorID: update.anchor.id)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        session?.stop()
        session = nil
        world = nil
        isRunning = false
    }

    /// The head's world transform now, while world tracking runs.
    public func deviceTransform() -> simd_float4x4? {
        guard let world, world.state == .running,
              let device = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
        return device.originFromAnchorTransform
    }

    public func headProbe() -> RAVEGuardianProbe? {
        deviceTransform().map(RAVEGuardianProbe.head)
    }
}

#endif
