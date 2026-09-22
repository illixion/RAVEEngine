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

`Package.swift` declares `[.visionOS(.v26), .macOS(.v14), .iOS(.v26)]`. visionOS is the
product; macOS exists because the sensing, binding and diagnostics logic is deliberately
framework-free so `swift test` can run it on the host, and because a Mac port is the
direction; iOS is declared because an omitted platform is not an excluded one — see the
comment in `Package.swift`. **tvOS and watchOS are not declared.**

**What will not port: hand tracking.** Its sensing core is ARKit `HandTrackingProvider` /
`HandAnchor` / `HandSkeleton`. What does port: `GameController` polling, the binding
tables, the pinch/joystick/palm arithmetic, and the whole diagnostics target. Hand input
sits behind `RAVEHandInputProvider`, which returns `RAVENoHandInput` off-visionOS.

## Targets

| Target | Purpose |
|---|---|
| `RAVEInput` | Hand + controller sensing, pinch/joystick/palm geometry, binding tables |
| `RAVEDiagnostics` | Frame profiler, metric collector, feed gating, HUD views |
| `RAVERig` | Skeleton geometry, humanoid inference, FABRIK, pose solving, leg stepping — shipping, see README |
| `RAVEPCVR` | Planned — see "About the planned RAVEPCVR target" below before touching this |

**"XR/game-shaped" is the real scope, not the acronym.** Robot-Assisted Vision Enhancements
reads like it's about vision/perception; it isn't a scope boundary. `RAVERig` (skeleton IK,
character rigging) already ships here and is not a category error — it's XR/game-shaped
exactly like input and diagnostics are. Judge whether something belongs in Engine vs. SDK by
the app-shaped/XR-shaped split in the header above, never by parsing the acronym.

### About the planned `RAVEPCVR` target

This package's family is fixed at exactly **two** sibling packages: this one and `RAVESDK`
(`../RAVESDK`). When code used by multiple apps needs a shared home, the answer is always
**a target inside one of these two**, never a new third sibling package. Do not create a
`RAVEPCVR` repo alongside `RAVEEngine`/`RAVESDK` — if it ever gets built, it is a target
added to *this* package's `Package.swift`, the same way `RAVERig` was.

`RAVEPCVR` is planned to hold only the **reusable controller-bridge protocol** — the
wire-level shape shared between a headset client and a host, once a second app needs it.
It is **not** a place for Longwave's PCVR feature as a whole. Longwave's PCVR is a paid,
app-specific product surface — trial limiting (`PCVRSessionLimiter`), the StoreKit paywall
(`PCVRStore`/`PCVRPaywallView`), the CloudXR session-management host, and the gesture/gaze
internals — and per `~/Projects/Longwave/CLAUDE.md` most of that is closed-source and lives
in private submodules that don't even attach to this Xcode project. None of it moves here
just because it's "PCVR-related." Only extract a piece into `RAVEPCVR` once a second
consumer actually needs that exact piece, the same convergence rule every other target here
followed (see "Working on this codebase" below).

## The isolation rule (both targets)

**The collection and sensing layers carry no isolation. This is a hard constraint, not a
preference**, and it is the single most important thing to preserve here.

Two of the three input consumers and two of the four diagnostics consumers poll from a
**render thread that cannot await anything** — Lambda's renderer, Longwave's 90 Hz datagram
loop. The other consumers drive the same code from `@MainActor`. So:

- `RAVEPinchDetector`, `RAVEHandJoystick`, `RAVEArmSwinger`, `RAVEPalmGeometry`, `RAVEEdgeTracker`,
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

**Joystick positions and axes use one tracking space.** `RAVEHandJoystick` accepts a
`RAVEPlanarBasis` so that contract is visible at direct call sites; the compatibility
overload and `RAVEARKitHandSensor` construct it for older callers. Do not project an ARKit
hand position against a game-world basis that has already had the game's yaw applied.
The output is head-relative and the game may rotate that 2D value into its world afterward.

**`RAVEArmSwinger` only reaches full deflection; it never scales it.** It is H3VR's arm
swinger over hand tracking: both fists plus a swing pattern engage it, either one keeps it
engaged (tracking drops fists mid-stroke), and speed comes from a stroke-peak envelope,
because the mean speed of a sinusoidal stroke is 64% of its peak and a ramp fed instantaneous
speed can never hold 1.0. Its output is the joystick's shape, and what 1.0 means belongs to
the game. `scaled(sensitivity:)` changes the effort needed, never the top speed. Hands join and
leave individually once it is running, so one arm can carry the run while the other aims: a
pointing pose (index out, a finger gun) is an explicit exit, and its fist test requires the
index curled, since a finger gun has three curled fingers too. `leftSwinging`/`rightSwinging`
tell the consumer which hands are free. LambdaVision
is the only consumer so far.

The shared default deadzone is 3 cm. Zero made normal ARKit wrist jitter into movement in
the two consumers that did not override it; Lambda's long-standing 3 cm setting was the
proven behavior. `RAVEJoystickOutput.visualization` is the renderer-neutral overlay seam —
keep it plain SIMD data rather than importing RealityKit or a Metal renderer here.

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

Five apps under `~/Projects/`. During development each references this package as a
**local** Swift package (`XCLocalSwiftPackageReference`), so edits are immediate. Once a
target stabilises, tag it and switch that app to `.package(url:)`.

What each app is and where new code goes lives in `~/Projects/CLAUDE.md`; this table is only
the link list.

| App (directory) | Links |
|---|---|
| `Oneiros` (visionOS + macOS) | `RAVEInput`, `RAVEDiagnostics` (+ SDK's `RAVEConsole`) |
| `Longwave` (visionOS + iOS + macOS) | `RAVEInput`, `RAVEDiagnostics` (+ SDK's `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVECamera`) |
| `halflife-visionos/LambdaVision` | `RAVEInput`, `RAVEDiagnostics`, `RAVERig` (+ SDK's `RAVEConsole`) |
| `Hypnos` (visionOS + iOS) | `RAVEDiagnostics` (+ SDK's `RAVENet`, `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVESlideshow`) |
| `spatial-ai-character` | `RAVEDiagnostics`, and `RAVERig` through its own `CharacterKit` package (+ SDK's `RAVEConsole`) |

`RAVERig`'s two consumers are the reference case for the split rule: `CharacterKit` binds it
to a RealityKit `SkeletalPose`, LambdaVision to a GoldSrc bone palette, and the shared half
names no framework. Read the links from `productName = RAVE…` in each `project.pbxproj`, not
from `import RAVE…` — `CharacterKit` re-exports `RAVERig`, so no file in spatial-ai-character
spells the import.

Apps keep their own spellings via typealiases (`BridgeHand = RAVEHandChirality`,
`HandGestureMapping = RAVEFingerBindingTable<PlayerAction>`) so hundreds of call sites did
not need renaming to prove a package boundary exists. Note that a typealias does **not**
re-export the enum's cases — consuming files still need `import RAVEInput`.

**A green `swift test` here proves very little.** Local package references mean the
consuming apps are the real integration test. After changing a public API, build them:

```bash
cd ~/Projects/Oneiros && xcodebuild -project Oneiros.xcodeproj -scheme Oneiros \
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
