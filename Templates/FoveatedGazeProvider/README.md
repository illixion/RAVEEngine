# Gaze provider extension

The official way for a visionOS app to know where the wearer looks: an
ExtensionKit **foveated streaming provider** (visionOS 27) that streams no
picture and sends `context.latestFocusRegion` back to its host app. The code is
`RAVEGazeOnlyStreamingProvider` (extension side) and `RAVEFoveatedProviderFeed`
(host side), both in the `RAVEFoveatedGaze` product. These files are the
target around them.

## Before you start

- **Entitlement:** `com.apple.developer.foveated-streaming-provider` is
  granted per team on request:
  https://developer.apple.com/contact/request/foveated-streaming-provider/
  The host app also needs `com.apple.developer.foveated-streaming-session`.
- Until the grant arrives, the extension can't be signed, so don't add the
  target to a project build-and-sign deploys: it would fail to sign.

## Adding it to an app

1. New target: visionOS → **Generic Extension** (ExtensionKit), named
   `GazeProvider`, embedded in the app. Its bundle id must be
   `<app bundle id>.GazeProvider`, which is what `RAVEFoveatedProviderFeed`
   looks for by default.
2. Replace its sources with `GazeProvider.swift`, and its Info.plist and
   entitlements with the two files here. **Check the extension point
   identifier** in `Info.plist`: it is a placeholder until Apple documents it.
3. Link `RAVEFoveatedGaze` (RAVEEngine) into the extension target, and into
   the app.
4. Add the extension's profile to the app's `build-signing.conf`.

## Host side

```swift
let feed = RAVEFoveatedProviderFeed()          // finds <app>.GazeProvider
if await feed.isAvailable() {
    try await feed.connect(session, options: [:])
    // feed.gaze.latest → RAVEGazeSample, head space, with distance
}
```

The session still needs its `ImmersiveSpace(foveatedStreaming:)` scene and
`immersivePresentationBehaviors`; the provider's own scene is empty, so the
app's content in that space is all the wearer sees.

Unverified on a device (no grant yet): which endpoint the system wants for a
provider that ignores it (the feed passes `.systemDiscovered`), and whether
connecting shows a consent prompt.
