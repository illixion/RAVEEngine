//
//  RAVESpaceModule.swift
//  RAVESharedSpace
//
//  An app as a host app runs it beside others in one process (Nexus): windows
//  of its own, plus content it puts in the one shared immersive space instead
//  of declaring a space of its own.
//
//  Windows aren't in this protocol. SwiftUI scenes are types, so a module
//  exposes them as a `Scene` the host's `App.body` lists by name (statically:
//  the host is built knowing its modules). Window ids carry the module's
//  prefix ("orbit.main"), because the apps all call their main window "main"
//  and a process has one namespace of scene ids. RAVESDK's RAVEUI scopes its
//  window helpers by that prefix (`RAVEWindowScope`).
//

#if os(visionOS)
import RealityKit
import SwiftUI

@MainActor
public protocol RAVESpaceModule: AnyObject {
    /// Stable, short, lowercase: the prefix of the module's window ids and storage.
    var id: String { get }
    var name: String { get }
    var systemImage: String { get }
    /// The window the launcher opens.
    var mainWindowID: String { get }

    /// The module joined the space: build its content under `root`, which the host has
    /// already put in the scene and owns. Everything the module adds must stay under it, so
    /// taps route back here and leaving the space takes it all away.
    func mount(_ root: Entity, services: RAVESpatialServices) async
    /// The module left the space; the host removes `root` after this returns.
    func unmount()
    /// A tap landed on an entity under this module's root.
    func tapped(_ entity: Entity)
    /// The system closed the space without the module leaving: the Digital Crown, or another
    /// app opening its own. The module's request is already gone.
    func spaceTakenAway()
}

public extension RAVESpaceModule {
    func tapped(_ entity: Entity) {}
    func spaceTakenAway() {}
}

/// Marks a module's root entity, so a tap anywhere below it finds its module.
public struct RAVESpaceModuleComponent: Component {
    public let moduleID: String
}
#endif
