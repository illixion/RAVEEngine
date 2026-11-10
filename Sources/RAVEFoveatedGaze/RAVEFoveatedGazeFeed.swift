/*
 RAVE Engine — where the wearer looks, through Apple's foveated streaming.

 visionOS shares eye input with no app directly. A `FoveatedStreamingSession`
 hands it to whatever sits at the far end of the stream, and since visionOS 27
 that can be a *streaming provider extension* (entitlement
 `com.apple.developer.foveated-streaming-provider`, granted on request) whose
 context carries `latestFocusRegion`. That is the official route, and this
 target is both of its halves:

 - **Extension side:** `RAVEGazeOnlyStreamingProvider` is a complete
   provider that streams nothing and forwards each focus region to the host
   app over a message channel. An app's extension target is one class:
   `@main final class GazeProvider: RAVEGazeOnlyStreamingProvider {}`
   (with `import ExtensionKit` beside it).
 - **Host side:** `RAVEFoveatedProviderFeed` connects the app's session to
   that extension and reads the samples back as a `RAVEGazeSource`.

 Both feeds and anything else that yields gaze through a foveated session
 conform to `RAVEFoveatedGazeFeed`, so an app holds one feed and never knows
 which it got. `RAVEFoveatedGazeFeeds.plugin()` finds an extra feed compiled
 into the app from outside its repository (a class named
 `RAVEFoveatedGazePlugin`), for builds that bring their own.

 Samples travel in `RAVEGazeWire` bytes. The focus region's direction is
 device-relative, which is `RAVEGazeSample`'s head space.
 */

#if os(visionOS) && canImport(FoveatedStreaming)

import Foundation
import FoveatedStreaming
import RAVEInput

public enum RAVEFoveatedGaze {
    /// The message channel gaze travels on. A UUID, not a string, so any
    /// foveated-streaming endpoint (UUID channel IDs, visionOS 26.4), on any headset, can serve it too.
    public static let channelUUID = UUID(uuidString: "52415645-4741-5A45-8000-000000000001")!

    @available(visionOS 26.4, *)
    public static var channelID: FoveatedStreamingSession.MessageChannel.ID { .init(channelUUID) }
}

public enum RAVEFoveatedGazeError: Error, LocalizedError, Equatable {
    /// No installed provider extension has this bundle identifier.
    case providerMissing(String)
    /// The host opened a channel the provider doesn't serve.
    case unknownChannel
    /// A feed needs an option it wasn't given.
    case missingOption(String)

    public var errorDescription: String? {
        switch self {
        case .providerMissing(let id): "No foveated streaming provider \(id) is installed (it needs the provider entitlement)."
        case .unknownChannel: "The gaze provider serves only the gaze channel."
        case .missingOption(let key): "The gaze feed needs the \"\(key)\" option."
        }
    }
}

/// Something that yields gaze through a `FoveatedStreamingSession`.
@available(visionOS 26.4, *)
@MainActor public protocol RAVEFoveatedGazeFeed: AnyObject {
    /// Short label for logs and debug reports.
    var name: String { get }
    /// Where the samples land; stays the same object for the feed's life.
    var gaze: any RAVEGazeSource { get }
    /// Connects `session` and starts reading gaze. `options` are the feed's own
    /// (`"host"` for a LAN endpoint, say).
    func connect(_ session: FoveatedStreamingSession, options: [String: String]) async throws
    /// Starts reading gaze for a session the app connected itself.
    func attach(_ session: FoveatedStreamingSession, options: [String: String])
    /// Stops reading. Disconnecting the session stays the app's call.
    func detach()
}

/// A feed compiled into an app from outside its repository. Declare it as
/// `@objc(RAVEFoveatedGazePlugin) final class …: NSObject, RAVEFoveatedGazePlugin`.
@available(visionOS 26.4, *)
@MainActor public protocol RAVEFoveatedGazePlugin: RAVEFoveatedGazeFeed {
    init()
}

@available(visionOS 26.4, *)
public enum RAVEFoveatedGazeFeeds {
    /// The Objective-C class name `plugin()` looks for.
    public static let pluginClassName = "RAVEFoveatedGazePlugin"

    /// The plug-in feed built into this app, if there is one.
    @MainActor public static func plugin() -> (any RAVEFoveatedGazeFeed)? {
        guard let type = NSClassFromString(pluginClassName) as? any RAVEFoveatedGazePlugin.Type else { return nil }
        return type.init()
    }
}

#endif
