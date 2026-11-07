/*
 RAVE Engine — the host app's half of the official foveated gaze route.

 `RAVEFoveatedGazeReceiver` reads `RAVEGazeWire` messages off a session's
 gaze channel into a `RAVEPushGazeSource`. `RAVEFoveatedProviderFeed`
 connects the session to the app's own gaze provider extension and attaches
 a receiver: the whole official path in one object.
 */

#if os(visionOS) && canImport(FoveatedStreaming)

import DebugLog
import Foundation
import FoveatedStreaming
import RAVEInput

/// Reads gaze off a session's message channel.
@available(visionOS 26.4, *)
@MainActor public final class RAVEFoveatedGazeReceiver {

    public let source = RAVEPushGazeSource()
    public let channelID: FoveatedStreamingSession.MessageChannel.ID
    /// True while the gaze channel is open.
    public private(set) var channelOpen = false

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let log = DebugLogger(subsystem: "RAVEEngine", category: "FoveatedGaze")

    public init(channelID: FoveatedStreamingSession.MessageChannel.ID = RAVEFoveatedGaze.channelID) {
        self.channelID = channelID
    }

    /// Waits for the channel to be offered, opens it and reads until the
    /// session drops it, then waits again. Replaces an earlier attach.
    public func attach(_ session: FoveatedStreamingSession, usesLocalProviderClock: Bool = false) {
        detach()
        let generation = self.generation
        let id = channelID
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.generation == generation {
                if session.availableMessageChannels.contains(id), let channel = session.messageChannel(for: id) {
                    self?.channelOpen = true
                    self?.log.info("Gaze channel open")
                    for await data in channel.receivedMessageStream {
                        guard !Task.isCancelled, self?.generation == generation else { return }
                        self?.source.ingest(data, usesLocalProviderClock: usesLocalProviderClock)
                    }
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.source.reset()
                    self?.channelOpen = false
                    self?.log.info("Gaze channel closed")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func detach() {
        generation = UUID()
        source.reset()
        task?.cancel()
        task = nil
        channelOpen = false
    }
}

/// Gaze from any endpoint that serves RAVE's gaze channel: a streaming host
/// that forwards the gaze it receives back to the headset, say. `connect`
/// connects to `endpoint`; `attach` reads a session the app connected itself.
@available(visionOS 26.4, *)
@MainActor public final class RAVEFoveatedChannelFeed: RAVEFoveatedGazeFeed {

    public let name = "channel"
    public let endpoint: FoveatedStreamingSession.Endpoint
    public let receiver = RAVEFoveatedGazeReceiver()
    public var gaze: any RAVEGazeSource { receiver.source }

    public init(endpoint: FoveatedStreamingSession.Endpoint = .systemDiscovered) {
        self.endpoint = endpoint
    }

    public func connect(_ session: FoveatedStreamingSession, options: [String: String]) async throws {
        attach(session, options: options)
        do {
            try await session.connect(endpoint: endpoint)
        } catch {
            detach()
            throw error
        }
    }

    public func attach(_ session: FoveatedStreamingSession, options: [String: String]) {
        receiver.attach(session)
    }

    public func detach() { receiver.detach() }
}

/// The official feed: the app's session streams from the app's own
/// `RAVEGazeOnlyStreamingProvider` extension, which sends the focus region back.
@available(visionOS 27.0, *)
@MainActor public final class RAVEFoveatedProviderFeed: RAVEFoveatedGazeFeed {

    public let name = "provider"
    /// The extension's bundle identifier.
    public let providerBundleID: String
    public let endpoint: FoveatedStreamingSession.Endpoint
    public let receiver = RAVEFoveatedGazeReceiver()
    public var gaze: any RAVEGazeSource { receiver.source }

    /// `providerBundleID` defaults to the app's own identifier plus
    /// `.GazeProvider`. The endpoint reaches the extension untouched; a
    /// gaze-only provider ignores it.
    public init(providerBundleID: String? = nil, endpoint: FoveatedStreamingSession.Endpoint = .systemDiscovered) {
        self.providerBundleID = providerBundleID ?? ((Bundle.main.bundleIdentifier ?? "") + ".GazeProvider")
        self.endpoint = endpoint
    }

    /// The installed provider, or nil (no extension, or no entitlement).
    /// Ask before connecting, never while a session connects: on the AVP
    /// (visionOS 27.2, 2026-11-05) a query then failed in the discovery daemon
    /// and the app died.
    public func provider() async -> FoveatedStreamingSession.StreamingProvider? {
        await FoveatedStreamingSession.queryStreamingProviders().first { $0.bundleIdentifier == providerBundleID }
    }

    /// Whether this app can take the official route at all.
    public func isAvailable() async -> Bool { await provider() != nil }

    public func connect(_ session: FoveatedStreamingSession, options: [String: String]) async throws {
        detach()
        guard let provider = await provider() else { throw RAVEFoveatedGazeError.providerMissing(providerBundleID) }
        attach(session, options: options)
        do {
            try await session.connect(endpoint: endpoint, streamingProvider: provider)
        } catch {
            detach()
            throw error
        }
    }

    public func attach(_ session: FoveatedStreamingSession, options: [String: String]) {
        receiver.attach(session, usesLocalProviderClock: true)
    }

    public func detach() { receiver.detach() }
}

#endif
