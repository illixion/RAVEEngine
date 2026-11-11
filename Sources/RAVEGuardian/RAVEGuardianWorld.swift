/*
 RAVE Engine — the guardian's mapped room on the main actor: mesh anchors
 in, barrier triangles extracted off the main actor, newest update per anchor
 wins, the floor estimate kept beside. Shared by both drawing paths: the
 RealityKit guardian (`RAVEGuardian`) and the Metal overlay for Compositor
 Services hosts (`RAVEGuardianOverlay`).
 */

#if os(visionOS)

import ARKit
import Foundation

/// Something the world sensor can feed mesh anchors to.
@MainActor
public protocol RAVEGuardianMeshSink: AnyObject {
    func ingest(_ anchor: MeshAnchor)
    func remove(anchorID: UUID)
}

@MainActor
public final class RAVEGuardianWorld: RAVEGuardianMeshSink {
    public private(set) var map = RAVEGuardianMap()
    private var floors: [UUID: Float] = [:]
    private var generations: [UUID: Int] = [:]

    public init() {}

    /// The lowest floor seen so far, metres.
    public var floorY: Float? { floors.values.min() }

    public func ingest(_ anchor: MeshAnchor) {
        let id = anchor.id
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        let knownFloor = floorY
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = RAVEGuardianMeshExtraction.barriers(of: anchor, floorY: knownFloor)
            await self?.apply(result, anchor: id, generation: generation)
        }
    }

    public func remove(anchorID: UUID) {
        generations[anchorID] = (generations[anchorID] ?? 0) + 1
        floors[anchorID] = nil
        map.remove(anchor: anchorID)
    }

    public func setBarriers(_ triangles: [RAVEGuardianTriangle], anchor: UUID) {
        generations[anchor] = (generations[anchor] ?? 0) + 1
        map.replace(anchor: anchor, with: triangles)
    }

    public func removeAll() {
        generations.removeAll()
        floors.removeAll()
        map.removeAll()
    }

    private func apply(_ result: (triangles: [RAVEGuardianTriangle], floorY: Float?),
                       anchor: UUID, generation: Int) {
        guard generations[anchor] == generation else { return }
        if let y = result.floorY { floors[anchor] = y }
        map.replace(anchor: anchor, with: result.triangles)
    }
}

#endif
