//
//  RAVESpaceHost.swift
//  RAVESharedSpace
//
//  Owns the shared space's scene graph: one root entity per module that holds
//  a request, mounted when it joins and removed when it leaves, and the tap
//  routing that keeps one module's gestures off another's entities
//  (spatial-ai-character's gestures used to target any entity and filter by
//  name, which in a shared space would catch everyone's).
//

#if os(visionOS)
import DebugLog
import Observation
import RealityKit
import SwiftUI

@MainActor
@Observable
public final class RAVESpaceHost {
    /// The `ImmersiveSpace` id the host app declares the space under.
    public let spaceID: String
    public let modules: [any RAVESpaceModule]
    public let broker = RAVESpaceBroker()
    public let services = RAVESpatialServices()
    /// Mounted module ids, in mount order.
    public private(set) var mounted: [String] = []
    /// Taps routed per module, for the scoping check.
    public private(set) var tapCounts: [String: Int] = [:]

    /// The space's content root. Lives as long as the host, so a module's entities could
    /// outlive one opening of the space; today roots are rebuilt on each mount.
    @ObservationIgnored public let sceneRoot = Entity()
    @ObservationIgnored private var roots: [String: Entity] = [:]
    @ObservationIgnored private var spaceIsUp = false
    private let log = DebugLogger(subsystem: RAVESharedSpaceLog.subsystem, category: "Host")

    public init(modules: [any RAVESpaceModule], spaceID: String = "rave.sharedSpace") {
        self.modules = modules
        self.spaceID = spaceID
        sceneRoot.name = "rave.sharedSpace.root"
        RAVESpaceModuleComponent.registerComponent()
        broker.onTakenAway = { [weak self] lost in
            guard let self else { return }
            for id in lost { self.module(id)?.spaceTakenAway() }
        }
    }

    public func module(_ id: String) -> (any RAVESpaceModule)? {
        modules.first { $0.id == id }
    }

    // MARK: Called by RAVESpaceView

    func spaceDidAppear() async {
        spaceIsUp = true
        broker.spaceDidAppear()
        await sync()
    }

    func spaceDidDisappear() {
        spaceIsUp = false
        for id in mounted { unmount(id) }
        services.stop()
        broker.spaceDidDisappear()
    }

    /// Mount who joined, unmount who left, and run the session the members need.
    func sync() async {
        guard spaceIsUp else { return }
        let wanted = broker.members
        for id in mounted where !wanted.contains(id) { unmount(id) }
        await services.run(hands: broker.resolution?.needsHands ?? false)
        for id in wanted where !mounted.contains(id) {
            guard let module = module(id) else { continue }
            let root = Entity()
            root.name = "rave.sharedSpace.module.\(id)"
            root.components.set(RAVESpaceModuleComponent(moduleID: id))
            sceneRoot.addChild(root)
            roots[id] = root
            mounted.append(id)
            log.info("mount \(id, privacy: .public)")
            await module.mount(root, services: services)
        }
    }

    private func unmount(_ id: String) {
        module(id)?.unmount()
        roots.removeValue(forKey: id)?.removeFromParent()
        mounted.removeAll { $0 == id }
        log.info("unmount \(id, privacy: .public)")
    }

    /// Send a tap to the module whose root is above `entity`; nobody else hears it.
    func route(tap entity: Entity) {
        var node: Entity? = entity
        while let current = node {
            if let owner = current.components[RAVESpaceModuleComponent.self] {
                tapCounts[owner.moduleID, default: 0] += 1
                module(owner.moduleID)?.tapped(entity)
                return
            }
            node = current.parent
        }
    }
}

/// The shared space's content. Declare it once, in the host's `App.body`:
///
///     ImmersiveSpace(id: host.spaceID) { RAVESpaceView(host: host) }
///         .raveSpaceStyle(host)
public struct RAVESpaceView: View {
    let host: RAVESpaceHost

    public init(host: RAVESpaceHost) { self.host = host }

    public var body: some View {
        RealityView { content in
            content.add(host.sceneRoot)
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            host.route(tap: value.entity)
        })
        .preferredSurroundingsEffect(surroundings)
        .task { await host.spaceDidAppear() }
        .onChange(of: host.broker.members) { _, _ in Task { await host.sync() } }
        .onChange(of: host.broker.resolution?.needsHands) { _, _ in Task { await host.sync() } }
        .onDisappear { host.spaceDidDisappear() }
    }

    private var surroundings: SurroundingsEffect? {
        switch host.broker.resolution?.surroundings {
        case .dark: .systemDark
        case .dim: .dim(intensity: 0.5)
        case nil: nil
        }
    }
}

public extension SwiftUI.Scene {
    /// The space's one immersion style and arm visibility, from the members' resolution.
    func raveSpaceStyle(_ host: RAVESpaceHost) -> some SwiftUI.Scene {
        // Read in `body`, so a change re-evaluates the scene and restyles an open space.
        let full = host.broker.resolution?.immersion == .full
        let hidden = host.broker.resolution?.upperLimbsHidden == true
        return self
            .immersionStyle(selection: Binding {
                full ? FullImmersionStyle.full as any ImmersionStyle : MixedImmersionStyle.mixed
            } set: { _ in }, in: .mixed, .full)
            .upperLimbVisibility(hidden ? .hidden : .automatic)
    }
}

public extension View {
    /// Hand the space actions to the broker. Put it on every window: whichever is up when a
    /// module asks for the space is the one that opens it.
    func raveSpaceActions(_ host: RAVESpaceHost) -> some View {
        modifier(RAVESpaceActions(host: host))
    }
}

private struct RAVESpaceActions: ViewModifier {
    let host: RAVESpaceHost
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    func body(content: Content) -> some View {
        content.onAppear {
            guard host.broker.openSpace == nil else { return }
            let open = openImmersiveSpace
            let dismiss = dismissImmersiveSpace
            let spaceID = host.spaceID
            host.broker.openSpace = {
                if case .opened = await open(id: spaceID) { return true }
                return false
            }
            host.broker.dismissSpace = { await dismiss() }
        }
    }
}
#endif
