# RAVE Engine

**R**obot-**A**ssisted **V**ision **E**nhancements — the XR/game-shaped half of
the RAVE packages. Input, frame diagnostics, RealityKit and CompositorServices
scaffolding, and PCVR components.

Its sibling, **RAVE SDK**, covers the app-shaped half — general UI, camera,
2D/3D photo & video viewing and conversion, app networking. The two are
siblings with **no dependency between them**, which is what lets Engine add
macOS support on its own schedule. An app that is both simply links both.

## Platforms

visionOS 26 today. macOS is declared already because the sensing, binding and
diagnostics logic is deliberately framework-free — `swift test` runs it on the
host — and because a Mac port is the stated direction.

What will *not* port: hand tracking. Its sensing core is ARKit
`HandTrackingProvider` / `HandAnchor` / `HandSkeleton`, visionOS-only. What does
port: `GameController` polling, the binding tables, the diagnostics collector,
and head pose. Hand input sits behind `RAVEHandInputProvider`, which returns
`RAVENoHandInput` off-visionOS.

## Targets

| Target | Status | Purpose |
|---|---|---|
| `RAVEInput` | shipping | Hand and controller sensing, pinch/joystick/palm geometry, binding tables |
| `RAVEDiagnostics` | shipping | Frame profiler, metric collector, feed gating, HUD views |
| `RAVEPCVR` | planned | Controller-bridge protocol, sourced from Longwave |

## RAVEInput

Converged from three copies of the same code. Spatialcraft wrote it; Longwave
and Lambda ported it and each drifted. All three agreed on every tuning constant
(2.5 cm engage / 4.5 cm release / 6 cm curl / 3 curled fingers = fist) and
diverged only in what they did with the result — which is the shape that belongs
in a package.

### Held state is primary, edges are derived

The original emitted only a rising edge, which is lossy: a VR controller button
must stay *down* for a pinch's duration, so Longwave's port had to re-derive
held state the original had thrown away. Reconstructing edges from held state is
free; the reverse is not. `RAVEPinchOutput` publishes `held`, `heldDuration`,
`began` and `ended`, and each consumer takes what it needs.

### Two palm-facing metrics, both deliberate

The apps disagree here on purpose and both survive:

- `facing` — a plain dot product. A palm counts as facing you only when it
  actually points at you. Longwave's wrist panel wants this.
- `pitchInvariantFacing` — strips the finger-axis component first, so tilting
  the hand up or down does not change the reading. This is what a forgiving
  trigger wants, with engage/release thresholds tuned against it. They are **not**
  transferable to the plain metric.

The palm *normal*, by contrast, had one right answer and two wrong ones. What
ships is the thumb test: the thumb column sits on the palmar side of the finger
plane, in both hands, in any pose, regardless of how the tracking framework
numbers its axes. An earlier wrist-frame −Y rule worked only because it was
applied to one hand.

### No isolation in the sensing layer

`RAVEPinchDetector`, `RAVEHandJoystick`, `RAVEPalmGeometry` and `RAVEEdgeTracker`
are isolation-free value types. That is what lets a `@MainActor` tracker and a
render-thread poll loop share them without either converting — a hard
requirement, since two of the three consumers run off the main actor.

`RAVEARKitHandSensor` is the `@MainActor` convenience on top, and supports both
ownership models: it can open its own `HandTrackingProvider` (`start()`) or be
fed anchors an app already receives (`ingest(_:)`).

## Consuming this package

The visionOS apps link this package as a **local** Swift package — an Xcode
`XCLocalSwiftPackageReference` with a relative path, not a versioned remote
dependency. There are no tags and no `Package.resolved` entry; a build always
compiles the working copy you have checked out.

That is deliberate. The packages and the apps co-evolve continuously — `RAVEInput`
arrived here by being converged out of three apps that had each already shipped a
copy of it — and a path reference makes "move this code into the package and
update its callers" one atomic edit instead of a commit, a tag, and a pin bump in
every app.

The cost is a layout convention. Clone this package as a **sibling** of any app
that uses it:

```
some-parent/
├── RAVEEngine/       <- this package
├── RAVESDK/          <- its sibling package
├── Spatialcraft/
└── Longwave/
```

Each app's project points at `../RAVEEngine` or `../../RAVEEngine` depending on
how deeply its `.xcodeproj` is nested; both resolve to the same parent directory,
so the only requirement is that the app repo's parent also contains `RAVEEngine`
(and `RAVESDK`, for an app that links it) under exactly those directory names.
The app repo's own directory name does not matter. Get it wrong and Xcode fails
at package resolution rather than at compile time.

## Testing

```bash
swift test                                                                 # pure-logic targets, on the host
xcodebuild -scheme RAVEEngine-Package -sdk xros -destination 'generic/platform=visionOS' build
```
