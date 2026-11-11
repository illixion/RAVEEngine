/*
 RAVE Engine — the guardian for Metal hosts (Compositor Services): the same
 map, settings and monitor as the RealityKit `RAVEGuardian`, ticked on the
 main actor at display rate, publishing what to draw to a
 `RAVEGuardianMetalRenderer` that the host's render thread encodes.

     let overlay = RAVEGuardianOverlay()
     overlay.probeSource = { [sensor] in [sensor.headProbe()].compactMap { $0 } + hands() }
     sensor.start(feeding: overlay)
     overlay.start()
     // render thread, per frame, after drawing the scene:
     overlay.renderer.encode(commandBuffer: cb, targets: eyes)

 The monitor runs here rather than on the render thread because its probes
 (ARKit hands, controller poses) live on the main actor; a tick of fade lag
 is invisible next to a 50 ms rise.

 visionOS only (ARKit mesh anchors).
 */

#if os(visionOS)

import ARKit
import Foundation
import QuartzCore

@MainActor
public final class RAVEGuardianOverlay: RAVEGuardianMeshSink {
    public let settingsStore: RAVEGuardianSettingsStore
    /// Hand this to the render thread.
    public let renderer = RAVEGuardianMetalRenderer()
    public let world = RAVEGuardianWorld()
    public var probeSource: (@MainActor () -> [RAVEGuardianProbe])?
    public private(set) var lastFrame = RAVEGuardianFrame()

    /// Seconds between ticks; ~90 Hz.
    public var interval: Duration = .milliseconds(11)

    private var monitor = RAVEGuardianMonitor()
    private var task: Task<Void, Never>?

    public init(settings: RAVEGuardianSettingsStore = .shared) {
        self.settingsStore = settings
    }

    public var isRunning: Bool { task != nil }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(time: CACurrentMediaTime())
                try? await Task.sleep(for: self?.interval ?? .milliseconds(11))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        renderer.clear()
        monitor.reset()
        lastFrame = RAVEGuardianFrame()
    }

    public func ingest(_ anchor: MeshAnchor) { world.ingest(anchor) }
    public func remove(anchorID: UUID) { world.remove(anchorID: anchorID) }
    public func setBarriers(_ triangles: [RAVEGuardianTriangle], anchor: UUID) {
        world.setBarriers(triangles, anchor: anchor)
    }
    public func removeAll() {
        world.removeAll()
        monitor.reset()
        renderer.clear()
    }

    func tick(time: Double) {
        let settings = settingsStore.settings
        guard settings.isEnabled else {
            monitor.reset()
            lastFrame = RAVEGuardianFrame()
            renderer.clear()
            return
        }
        let frame = monitor.update(probes: probeSource?() ?? [], time: time, map: world.map, settings: settings)
        lastFrame = frame
        renderer.publish(map: world.map, opacity: frame.chunkOpacity, appearance: settings.appearance)
    }
}

#endif
