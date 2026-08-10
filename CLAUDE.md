# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**RAVE Engine** — *Robot-Assisted Vision Enhancements*, the **XR/game-shaped** half of the
RAVE packages: hand and controller input, frame diagnostics, and (planned)
RealityKit/CompositorServices scaffolding and PCVR components.

Its sibling is **RAVE SDK** (`../RAVESDK`), the app-shaped half — UI shell, app networking,
log console, media.

**The two are siblings with no dependency between them, in either direction.** That is a
hard rule. This package's stated future is a Mac port, and it must be able to get there
without dragging visionOS-only SDK targets along. An app that needs both links both. If you
want to `import RAVESDK` here, the thing you want belongs in the app instead.

## Build and test

```bash
swift test                                       # all host-runnable targets
swift test --filter RAVEPalmPoseTests            # one suite
swift test --filter "RAVEPalmPoseTests/thumbDecidesTheSide"   # one test

# visionOS build — the scheme is "<name>-Package", NOT "RAVEEngine"
xcodebuild -scheme RAVEEngine-Package -sdk xros -destination 'generic/platform=visionOS' build
```

**`-sdk xros` is required.** Without it, `xcodebuild -destination 'generic/platform=visionOS'`
prints `** BUILD SUCCEEDED **` while compiling nothing, after
`Supported platforms for the buildables in the current scheme is empty`. A "successful"
build that names no source files did not happen.

`swift test` covers the framework-free logic only. `RAVEARKitHandSensor` is behind
`#if os(visionOS)` and is compiled by the `xcodebuild` line alone — run both.

## Platform declaration

`Package.swift` declares `[.visionOS(.v26), .macOS(.v14)]`. visionOS is the product; macOS
exists because the sensing, binding and diagnostics logic is deliberately framework-free so
`swift test` can run it on the host, and because a Mac port is the direction.

**What will not port: hand tracking.** Its sensing core is ARKit `HandTrackingProvider` /
`HandAnchor` / `HandSkeleton`. What does port: `GameController` polling, the binding
tables, the pinch/joystick/palm arithmetic, and the whole diagnostics target. Hand input
sits behind `RAVEHandInputProvider`, which returns `RAVENoHandInput` off-visionOS.

## Targets

| Target | Purpose |
|---|---|
| `RAVEInput` | Hand + controller sensing, pinch/joystick/palm geometry, binding tables |
| `RAVEDiagnostics` | Frame profiler, metric collector, feed gating, HUD views |

## The isolation rule (both targets)

**The collection and sensing layers carry no isolation. This is a hard constraint, not a
preference**, and it is the single most important thing to preserve here.

Two of the three input consumers and two of the four diagnostics consumers poll from a
**render thread that cannot await anything** — Lambda's renderer, Longwave's 90 Hz datagram
loop. The other consumers drive the same code from `@MainActor`. So:

- `RAVEPinchDetector`, `RAVEHandJoystick`, `RAVEPalmGeometry`, `RAVEEdgeTracker`,
  `RAVESampleSeries` are **isolation-free value types**
- `RAVEMetricCollector` is a **lock-guarded class**, `@unchecked Sendable` — an actor would
  make `record()` async and unusable from exactly the callers that need it most
- `RAVEARKitHandSensor` and the SwiftUI views are the `@MainActor` conveniences *on top*

Making any of the first two groups an actor, or `@MainActor`, breaks a consumer that cannot
be fixed on its side.

## RAVEInput

Converged from three copies (Spatialcraft wrote it; Longwave and Lambda ported and each
drifted). All three agreed on every tuning constant — 2.5 cm engage / 4.5 cm release / 6 cm
curl / 3 curled fingers = fist — and diverged only in what they did with the result.

**Held state is primary; edges are derived.** The original implementation emitted only a
rising edge, which is lossy — a VR controller button must stay *down* for a pinch's duration, so
Longwave's port had to rebuild the held state the original had thrown away. Reconstructing
edges from held state is free; the reverse is not. `RAVEPinchOutput` publishes `held`,
`heldDuration`, `began` and `ended`.

**The palm normal comes from the thumb, not from a chirality rule.** The thumb column sits
on the palmar side of the finger plane — true of both hands, in any pose, regardless of how
the tracking framework numbers its axes. Two earlier attempts got this wrong by reasoning
about a convention (a wrist-frame `−Y` axis; a hand-drawn sign diagram) instead of
measuring something. Do not reintroduce a per-hand sign.

**Two palm-facing metrics ship, deliberately.** `facing` is a plain dot product — a palm
counts as facing you only when it points at you, which is what a "turn your palm toward
your face" panel needs. `pitchInvariantFacing` strips the finger-axis component so tilting
the hand does not change the reading, which is what a forgiving game trigger needs.
A forgiving trigger's engage/release thresholds are tuned against the **invariant** one
and do not transfer to the plain one. This divergence is a product decision, not drift.

`poll(now:worldForward:worldRight:)` is named apart from the `tick` protocol witness on
purpose: a defaulted `now:` made them indistinguishable at the call site and overload
resolution silently picked the lossy one.

**`RAVEFingerBindingTable`'s `Codable` is hand-written and wire-compatible.** It emits the
same named fields (`rightIndex`, `rightMiddle`, …) two apps already have in `UserDefaults`,
and decodes `leftIndex` with `decodeIfPresent` because one app never stored it — its
reserved joystick slot was not a value it kept. Synthesised `Codable` would reset every
user's bindings.

## RAVEDiagnostics

A convergence of four independent perf readouts that shared no code. All four are the same
shape: *a named-key → numeric-sample store with a count/max or percentile reduction,
refreshed on a windowed interval.* Both windowing rules survive as a choice
(`RAVEProfilerWindow.elapsed` vs `.frames`) — under a variable frame rate they answer
differently.

**Publish structured numbers, never a pre-formatted string.** One app published its meter
as an already-composed `"60 FPS · 16.7 ms · pk 20 ms"`, so nothing downstream could
re-style it, threshold-tint it, or graph it. Formatting is a presentation decision and
belongs in the view.

**`RAVEFeedGate` makes "no data" something a readout can say.** Only one of the four HUDs
had this, and it exists because a panel showed a steady 33 fps for as long as it was looked
at — an entirely plausible reading, minutes old. A frozen readout is worse than an empty
one because it is indistinguishable from a working one. It also separates *stopped* from
*never started*: different faults, opposite investigations.

The percentile formula is nearest-rank, clamped to the last index — the one two apps
independently arrived at. It is preserved exactly rather than "corrected" to an
interpolating percentile, because these numbers have been read on device for months.

## How consumers use this

Five visionOS apps under `~/Projects/`. During development each references this package as
a **local** Swift package (`XCLocalSwiftPackageReference`), so edits are immediate. Once a
target stabilises, tag it and switch that app to `.package(url:)`.

| App | Links |
|---|---|
| `Spatialcraft` | `RAVEInput`, `RAVEDiagnostics` (+ SDK's `RAVEConsole`) |
| `Longwave` | `RAVEInput`, `RAVEDiagnostics` (+ SDK's `RAVEUI`, `RAVEConsole`) |
| `Lambda_VisionPro` | `RAVEInput`, `RAVEDiagnostics` (+ SDK's `RAVEConsole`) |
| `spatialstash` | `RAVEDiagnostics` (+ SDK's `RAVENet`, `RAVEUI`, `RAVEConsole`) |

Apps keep their own spellings via typealiases (`BridgeHand = RAVEHandChirality`,
`HandGestureMapping = RAVEFingerBindingTable<PlayerAction>`) so hundreds of call sites did
not need renaming to prove a package boundary exists. Note that a typealias does **not**
re-export the enum's cases — consuming files still need `import RAVEInput`.

**A green `swift test` here proves very little.** Local package references mean the
consuming apps are the real integration test. After changing a public API, build them:

```bash
cd ~/Projects/Spatialcraft && xcodebuild -project Spatialcraft.xcodeproj -scheme Spatialcraft \
  -sdk xros -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO

# Longwave's PCVR code is behind a flag — the default build compiles none of it
cd ~/Projects/Longwave && xcodebuild -project Longwave.xcodeproj -scheme Longwave \
  -sdk xros -destination 'generic/platform=visionOS' build CODE_SIGNING_ALLOWED=NO \
  XROS_DEPLOYMENT_TARGET=26.4 SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FOVEATED_ENABLED'
```

Keep `$(inherited)` in that conditions list or swift-crypto's BoringSSL exclusion breaks.

## Working on this codebase

Every target is a **convergence of two or more existing implementations**, not a greenfield
design. The constants and guard clauses were paid for on device, and the comments
explaining *why* each is what it is are the most valuable thing in the file — a constant
with no explanation is one someone will "simplify" back into the bug it fixed.

When two source implementations disagree, work out whether it is drift or a deliberate
product decision before picking a winner. Sometimes the right answer is to ship both.

On-device QA is the user's responsibility, and it matters more here than usual: the
simulator has no hand tracking at all (`HandTrackingProvider.isSupported` is false, and
`session.run` raises an uncatchable ObjC exception there), so nothing in `RAVEInput`'s
device path can be validated by building.

**Commits are unsigned.** This is a personal (Ixion) repo, so its pre-push hook requires
signed commits and signing needs a physical key touch. Commit unsigned and leave signing
and pushing to the user.
