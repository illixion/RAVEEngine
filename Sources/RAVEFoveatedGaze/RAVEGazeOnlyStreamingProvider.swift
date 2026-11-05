/*
 RAVE Engine — the extension's half of the official foveated gaze route.

 A complete `FoveatedStreamingExtension` that streams no picture: its
 immersive scene is empty, so the host app's own content in
 `ImmersiveSpace(foveatedStreaming:)` is all the wearer sees. What it does do
 is read `context.latestFocusRegion` each time the system updates it and send
 it to the host on the gaze channel (`RAVEFoveatedGaze.channelID`).

 An app adopts it with an ExtensionKit extension target holding one file,

     import ExtensionKit   // brings AppExtension.main() into scope for @main
     import RAVEFoveatedGaze
     @main final class GazeProvider: RAVEGazeOnlyStreamingProvider {}

 signed with `com.apple.developer.foveated-streaming-provider`, and connects
 with `RAVEFoveatedProviderFeed`. Subclass and override the lifecycle calls
 (calling `super`) to stream something real alongside.
 */

#if os(visionOS) && canImport(FoveatedStreaming)

import DebugLog
import Foundation
import FoveatedStreaming
import Observation
import RAVEInput
import SwiftUI

@available(visionOS 27.0, *)
@MainActor open class RAVEGazeOnlyStreamingProvider: FoveatedStreamingExtension {

    public private(set) var context: Context?
    public private(set) var gazeChannel: MessageChannel?
    /// Focus regions sent to the host so far.
    public private(set) var forwarded = 0

    private var lastTimestamp: TimeInterval = .nan
    private let log = DebugLogger(subsystem: "RAVEEngine", category: "GazeProvider")

    public required init() {}

    open func connect(context: Context) async throws {
        self.context = context
        context.updateAvailableMessageChannels([RAVEFoveatedGaze.channelID])
        log.info("Gaze provider connected")
        observeFocus()
    }

    open func disconnect() async throws {
        gazeChannel?.close()
        gazeChannel = nil
        context = nil
        log.info("Gaze provider disconnected after \(self.forwarded, privacy: .public) samples")
    }

    open func openMessageChannel(_ channel: MessageChannel) throws {
        guard channel.id == RAVEFoveatedGaze.channelID else { throw RAVEFoveatedGazeError.unknownChannel }
        gazeChannel = channel
        forward()
    }

    public var immersiveScene: some View { EmptyView() }

    /// Re-arms after every change, so each new focus region is sent once.
    private func observeFocus() {
        guard let context else { return }
        withObservationTracking {
            _ = context.latestFocusRegion
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.forward()
                self?.observeFocus()
            }
        }
    }

    private func forward() {
        guard let region = context?.latestFocusRegion, region.timestamp != lastTimestamp,
              let channel = gazeChannel, channel.channelStatus == .ready else { return }
        lastTimestamp = region.timestamp
        forwarded += 1
        let sample = RAVEGazeSample(sequence: forwarded, direction: region.direction, distance: region.distance)
        channel.send(RAVEGazeWire.encode(sample, providerTime: region.timestamp))
    }
}

#endif
