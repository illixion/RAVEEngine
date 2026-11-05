//
//  RAVESpaceBroker.swift
//  RAVESharedSpace
//
//  Replaces every module's own openImmersiveSpace/dismissImmersiveSpace. A
//  module asks for the space and releases it; the space is open while anyone
//  holds a request and closes when the last one lets go. Hypnos's Cinema has
//  this shape internally (`claim`/`release`), and its unnamed
//  `dismissImmersiveSpace()` is exactly the call that cannot survive a shared
//  space: it closes everyone's.
//

import DebugLog
import Foundation
import Observation

@MainActor
@Observable
public final class RAVESpaceBroker {
    public enum Phase: String, Sendable { case closed, opening, open, closing }

    public private(set) var requests: [(id: String, requirements: RAVESpaceRequirements)] = []
    public private(set) var phase: Phase = .closed
    /// Why the last open failed, for the status line and the debug endpoint.
    public private(set) var lastError: String?

    /// What the space is set to; nil while nobody wants it.
    public var resolution: RAVESpaceResolution? { RAVESpacePolicy.resolve(requests) }
    public var members: [String] { requests.map(\.id) }

    /// Set from a window's environment (`raveSpaceActions()`); the broker can't reach
    /// SwiftUI's actions itself.
    @ObservationIgnored public var openSpace: (@MainActor () async -> Bool)?
    @ObservationIgnored public var dismissSpace: (@MainActor () async -> Void)?
    /// Told when the system took the space away (the Digital Crown, another app's space).
    @ObservationIgnored public var onTakenAway: (@MainActor ([String]) -> Void)?

    private let log = DebugLogger(subsystem: RAVESharedSpaceLog.subsystem, category: "SpaceBroker")

    public init() {}

    public func contains(_ id: String) -> Bool { requests.contains { $0.id == id } }

    /// Join the space, or update what this module asks of it. Asking again makes the module
    /// the newest, which is the one immersion follows.
    public func request(_ id: String, _ requirements: RAVESpaceRequirements = .init()) {
        requests.removeAll { $0.id == id }
        requests.append((id, requirements))
        log.info("request \(id, privacy: .public): members \(self.members.count, privacy: .public)")
        Task { await reconcile() }
    }

    public func release(_ id: String) {
        guard contains(id) else { return }
        requests.removeAll { $0.id == id }
        log.info("release \(id, privacy: .public): members \(self.members.count, privacy: .public)")
        Task { await reconcile() }
    }

    /// The space's own view calls these: they are what actually happened, whatever was asked.
    public func spaceDidAppear() {
        phase = .open
    }

    public func spaceDidDisappear() {
        let wasExpected = phase == .closing || requests.isEmpty
        phase = .closed
        guard !wasExpected else { return }
        // Nobody released it: the system closed it. Every member lost it at once.
        let lost = members
        log.notice("space taken away from \(lost.count, privacy: .public) members")
        requests.removeAll()
        onTakenAway?(lost)
    }

    /// Bring the space in line with the requests: open it for the first, close it after the
    /// last. Re-entrant calls while a transition runs do nothing; the transition's end checks
    /// again, so a request made mid-open is never lost.
    private func reconcile() async {
        switch (phase, requests.isEmpty) {
        case (.closed, false):
            guard let openSpace else {
                lastError = "No window has handed over the space actions yet."
                return
            }
            phase = .opening
            let opened = await openSpace()
            if !opened {
                phase = .closed
                lastError = "visionOS refused to open the space."
                log.error("open refused")
                return
            }
            lastError = nil
            if phase == .opening { phase = .open }
            await reconcile()
        case (.open, true):
            guard let dismissSpace else { return }
            phase = .closing
            await dismissSpace()
            // `spaceDidDisappear` sets .closed; a request made meanwhile reopens.
            if phase == .closing { phase = .closed }
            await reconcile()
        default:
            break
        }
    }
}
