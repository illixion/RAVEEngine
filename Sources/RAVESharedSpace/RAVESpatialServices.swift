//
//  RAVESpatialServices.swift
//  RAVESharedSpace
//
//  One ARKitSession for every module in the space. Each app ran its own
//  (spatial-ai-character: world, planes, mesh, room, hands; Longwave's
//  controller bridge: world and hands; Hypnos's Cinema: world). Two sessions
//  in one process do both receive hand anchors, at the same rate (measured on
//  the AVP in Nexus's spike, 2026-11-05), so a module may keep its own session
//  while it is ported. One owner is still the goal: one authorization prompt,
//  one set of providers running.
//

#if os(visionOS)
import ARKit
import DebugLog
import Foundation
import Observation
import QuartzCore
import simd

@MainActor
@Observable
public final class RAVESpatialServices {
    public enum State: String, Sendable { case stopped, running, unsupported, denied, failed }

    public private(set) var state: State = .stopped
    public private(set) var handsRunning = false
    /// Hand anchor updates received, for the two-sessions measurement.
    public private(set) var handUpdates = 0
    public private(set) var leftHand: HandAnchor?
    public private(set) var rightHand: HandAnchor?
    public private(set) var lastError: String?

    @ObservationIgnored private var session: ARKitSession?
    @ObservationIgnored private var world: WorldTrackingProvider?
    @ObservationIgnored private var handTask: Task<Void, Never>?
    private let log = DebugLogger(subsystem: RAVESharedSpaceLog.subsystem, category: "SpatialServices")

    public init() {}

    /// Start, or restart with hands on or off. Called by the host when the space opens and
    /// when its members' needs change.
    public func run(hands: Bool) async {
        guard WorldTrackingProvider.isSupported else {
            state = .unsupported
            return
        }
        if session != nil, hands == handsRunning { return }
        stop()

        var wantsHands = hands && HandTrackingProvider.isSupported
        if wantsHands {
            let answer = await ARKitSession().requestAuthorization(for: [.handTracking])
            if answer[.handTracking] != .allowed {
                wantsHands = false
                lastError = "Hand tracking isn't allowed."
            }
        }
        let session = ARKitSession()
        let world = WorldTrackingProvider()
        let handProvider = wantsHands ? HandTrackingProvider() : nil
        let providers: [any DataProvider] = [world] + (handProvider.map { [$0] } ?? [])
        do {
            try await session.run(providers)
        } catch {
            state = .failed
            lastError = error.localizedDescription
            log.error("session failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.session = session
        self.world = world
        handsRunning = handProvider != nil
        state = .running
        log.info("session running, hands \(self.handsRunning, privacy: .public)")
        if let handProvider {
            handTask = Task { [weak self] in
                for await update in handProvider.anchorUpdates {
                    guard let self else { return }
                    self.handUpdates += 1
                    switch update.anchor.chirality {
                    case .left: self.leftHand = update.anchor
                    case .right: self.rightHand = update.anchor
                    }
                }
            }
        }
    }

    public func stop() {
        handTask?.cancel()
        handTask = nil
        session?.stop()
        session = nil
        world = nil
        handsRunning = false
        leftHand = nil
        rightHand = nil
        if state == .running { state = .stopped }
    }

    /// The head's pose in the space's frame, now.
    public func deviceTransform() -> simd_float4x4? {
        guard let world, world.state == .running else { return nil }
        return world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }
}
#endif
