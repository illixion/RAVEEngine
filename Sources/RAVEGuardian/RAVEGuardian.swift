/*
 RAVE Engine — the guardian itself: a RealityKit root an app adds to its
 immersive content. Walls show as a short grid cue only when a hand or
 controller accelerates toward them; nearby furniture uses a separate
 translucent mesh.

 Wiring, in an app's RealityView:

     let guardian = RAVEGuardian()                       // settings: .shared store
     content.add(guardian.root)
     guardian.probeSource = { handAndControllerProbes() }
     sensor.start(feeding: guardian)                     // or guardian.ingest(meshAnchor)

 Each frame (a RealityKit System, so it runs in step with rendering) it reads
 the probes, asks `RAVEGuardianMonitor` which boundary cue or furniture
 hologram should show, rebuilds the chunks whose mesh changed and sets their opacity. Mesh
 extraction from a `MeshAnchor` runs off the main actor; the newest update per
 anchor wins.

 The settings store is read every frame, so a change in the app's settings
 shows on the next one; a change of style, colour or line width swaps the
 shared material, a change of spacing re-lays the chunks.

 visionOS only (RealityKit + ARKit). The rules it applies are the host-tested
 core in this target.
 */

#if os(visionOS)

import ARKit
import CoreGraphics
import Foundation
import QuartzCore
import RealityKit
import UIKit

@MainActor
public final class RAVEGuardian: RAVEGuardianMeshSink {

    /// Add this to the immersive content. Its children are world-space chunk
    /// entities, so keep it at the identity transform under the scene root.
    public let root = Entity()
    public let settingsStore: RAVEGuardianSettingsStore

    /// The tracked points to protect, read once a frame. ARKit world space.
    public var probeSource: (@MainActor () -> [RAVEGuardianProbe])?

    /// The last frame's verdict, for debug endpoints and HUDs.
    public private(set) var lastFrame = RAVEGuardianFrame()
    /// The mapped room.
    public let world = RAVEGuardianWorld()
    public var map: RAVEGuardianMap { world.map }

    /// Draws nothing while false (the app's space is hidden, a menu is up);
    /// the settings switch is separate and persistent.
    public var isActive = true {
        didSet { if !isActive { hideAll() } }
    }

    private var monitor = RAVEGuardianMonitor()
    private var entities: [RAVEGuardianChunkID: ModelEntity] = [:]
    private var builtRevision: [RAVEGuardianChunkID: Int] = [:]
    private var builtSpacing: Float?
    private var wallMaterialKey: MaterialKey?
    private var obstacleMaterialKey: MaterialKey?
    private var wallMaterial: UnlitMaterial?
    private var obstacleMaterial: UnlitMaterial?

    private struct MaterialKey: Equatable {
        var style: RAVEGuardianSettings.Style
        var color: RAVEGuardianSettings.Color
        var lineFraction: Float
    }

    /// Whether the outline ignores depth and draws over everything, the app's
    /// own content and any streamed frames included. On by default: a safety
    /// outline hidden behind a game object nearer than the wall (Longwave's
    /// PCVR space depth-tests RealityKit against the stream) is no outline.
    /// Off lets real-world occlusion and the app's content hide it.
    public let drawsOverContent: Bool

    public init(settings: RAVEGuardianSettingsStore = .shared, drawsOverContent: Bool = true) {
        self.settingsStore = settings
        self.drawsOverContent = drawsOverContent
        root.name = "RAVEGuardian"
        Self.registerOnce()
        root.components.set(RAVEGuardianComponent(guardian: self))
    }

    // MARK: Mesh

    /// The lowest floor seen so far, metres.
    public var floorY: Float? { world.floorY }

    /// Feed a mesh anchor from the app's own scene reconstruction.
    public func ingest(_ anchor: MeshAnchor) { world.ingest(anchor) }

    public func remove(anchorID: UUID) { world.remove(anchorID: anchorID) }

    /// Replace one anchor's barriers directly (tests, a saved room, a demo).
    public func setBarriers(_ triangles: [RAVEGuardianTriangle], anchor: UUID) {
        world.setBarriers(triangles, anchor: anchor)
    }

    public func removeAll() {
        world.removeAll()
        monitor.reset()
    }

    // MARK: Frame

    func tick(time: Double) {
        let settings = settingsStore.settings
        guard isActive, settings.isEnabled else {
            hideAll()
            if !settings.isEnabled { monitor.reset() }
            lastFrame = RAVEGuardianFrame()
            return
        }
        // Chunks are in world space; hold the root at the world origin
        // whatever the app parented it under (a module root, a scene root).
        if root.transformMatrix(relativeTo: nil) != matrix_identity_float4x4 {
            root.setTransformMatrix(matrix_identity_float4x4, relativeTo: nil)
        }
        let probes = probeSource?() ?? []
        let frame = monitor.update(probes: probes, time: time, map: map, settings: settings)
        lastFrame = frame

        updateMaterial(settings.appearance)
        let spacing = settings.appearance.spacing
        if builtSpacing != spacing {
            builtSpacing = spacing
            builtRevision.removeAll()
        }

        // Drop entities for chunks that no longer exist.
        for (id, entity) in entities where map.chunks[id] == nil {
            entity.removeFromParent()
            entities[id] = nil
            builtRevision[id] = nil
        }

        for (id, entity) in entities where frame.chunkOpacity[id] == nil {
            entity.isEnabled = false
        }
        for (id, opacity) in frame.chunkOpacity {
            guard let chunk = map.chunks[id] else { continue }
            let entity = entities[id] ?? makeEntity(id)
            if builtRevision[id] != map.chunkRevisions[id] {
                rebuild(entity, chunk: chunk, spacing: spacing)
                builtRevision[id] = map.chunkRevisions[id]
            }
            entity.components.set(OpacityComponent(opacity: opacity))
            entity.isEnabled = true
        }
    }

    private func hideAll() {
        for entity in entities.values { entity.isEnabled = false }
    }

    private func makeEntity(_ id: RAVEGuardianChunkID) -> ModelEntity {
        let entity = ModelEntity()
        entity.name = "RAVEGuardianChunk"
        if drawsOverContent {
            // Last among transparent things, so other blended content can't
            // paint over it either.
            entity.components.set(ModelSortGroupComponent(group: Self.sortGroup, order: Int32.max))
        }
        root.addChild(entity)
        entities[id] = entity
        return entity
    }

    private func rebuild(_ entity: ModelEntity, chunk: RAVEGuardianChunk, spacing: Float) {
        let layout = RAVEGuardianMeshLayout(triangles: chunk.triangles, spacing: spacing)
        var descriptor = MeshDescriptor(name: "guardian")
        descriptor.positions = MeshBuffers.Positions(layout.positions)
        descriptor.normals = MeshBuffers.Normals(layout.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(layout.uvs)
        descriptor.primitives = .triangles(layout.indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
        let surfaceMaterial = chunk.id.isObstacle ? obstacleMaterial : wallMaterial
        entity.model = ModelComponent(mesh: mesh, materials: surfaceMaterial.map { [$0] } ?? [])
    }

    private func updateMaterial(_ appearance: RAVEGuardianSettings.Appearance) {
        let wallKey = MaterialKey(style: appearance.style, color: appearance.color,
                                  lineFraction: appearance.lineWidth / appearance.spacing)
        let obstacleKey = MaterialKey(style: .solid, color: appearance.obstacleColor,
                                      lineFraction: appearance.lineWidth / appearance.spacing)
        var changed = false
        if wallKey != wallMaterialKey,
           let material = Self.material(for: wallKey, overContent: drawsOverContent) {
            wallMaterialKey = wallKey
            wallMaterial = material
            changed = true
        }
        if obstacleKey != obstacleMaterialKey,
           let material = Self.material(for: obstacleKey, overContent: drawsOverContent) {
            obstacleMaterialKey = obstacleKey
            obstacleMaterial = material
            changed = true
        }
        guard changed else { return }
        for (id, entity) in entities where entity.model != nil {
            let material = id.isObstacle ? obstacleMaterial : wallMaterial
            if let material { entity.model?.materials = [material] }
        }
    }

    private static func material(for key: MaterialKey, overContent: Bool) -> UnlitMaterial? {
        let n = RAVEGuardianPattern.size
        let bytes = RAVEGuardianPattern.rgba(style: key.style, lineFraction: key.lineFraction)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color,
                                                                               mipmapsMode: .allocateAndGenerateAll))
        else { return nil }
        let sampler = MTLSamplerDescriptor()
        sampler.sAddressMode = .repeat
        sampler.tAddressMode = .repeat
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.maxAnisotropy = 8
        var material = UnlitMaterial()
        let c = key.color
        material.color = .init(tint: UIColor(red: CGFloat(c.red), green: CGFloat(c.green),
                                             blue: CGFloat(c.blue), alpha: 1),
                               texture: .init(texture, sampler: .init(sampler)))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        // Drawn over, never into, the depth buffer: the outline must not hide
        // the app's own content or carve holes in it.
        material.writesDepth = false
        material.readsDepth = !overContent
        return material
    }

    // MARK: Registration

    private static let sortGroup = ModelSortGroup(depthPass: nil)

    private static var registered = false
    private static func registerOnce() {
        guard !registered else { return }
        registered = true
        RAVEGuardianComponent.registerComponent()
        RAVEGuardianSystem.registerSystem()
    }
}

/// Marks the guardian's root so its System can find it.
struct RAVEGuardianComponent: Component {
    weak var guardian: RAVEGuardian?
}

/// Ticks every guardian in the scene once per rendered frame.
struct RAVEGuardianSystem: System {
    static let query = EntityQuery(where: .has(RAVEGuardianComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let now = CACurrentMediaTime()
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            entity.components[RAVEGuardianComponent.self]?.guardian?.tick(time: now)
        }
    }
}

#endif
