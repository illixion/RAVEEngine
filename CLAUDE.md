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
| `RAVEInput` | Hand + controller sensing, pinch/joystick/palm geometry, binding tables, tracked controllers (PSVR2 Sense; Quest Touch over the LAN via Controller Bridge), physical mouse (`RAVEMouseSource`) |
| `RAVEDiagnostics` | Frame profiler, metric collector, feed gating, HUD views |
| `RAVERig` | Skeleton geometry, humanoid inference, FABRIK, pose solving, leg stepping — shipping, see README |
| `RAVEHolo` | In-world holographic UI for Metal hosts: SDF glyph atlas (CoreText, no font shipped), panel/gauge/text scene, Metal 4 renderer drawing into a pass the host owns. Shader source compiles at runtime (SwiftPM's CLI builds no `.metal`); `RAVEHOLO_SNAPSHOT=/x.png swift test --filter RAVEHolo` renders a sample panel to look at. Renderer is `@available(macOS 26)` (Metal 4) without raising the package floor. Also interactive: pinchable targets (Compositor Services tracking areas + a CPU ray hit-test), widgets/stack layout, and a palm anchor (`RAVEHoloPalmAnchor`, an alias of RAVEInput's `RAVEPalmAnchor`, shared with `RAVEPanel`) — see "RAVEHolo: interactive panels". Depends on `RAVEInput` for the anchor only. Consumers: LambdaVision (HEV HUD + developer palm debug panel), Oneiros (Metal-host wrist HUD) |
| `RAVEPanel` | Any SwiftUI view as a panel in a RealityKit scene: chrome, the attachment hosting fix, world / palm / head-follow placing, and a visibility verdict to pause content by. Rules host-tested, entity half visionOS-only. Depends on `RAVEInput` for the palm anchor. See "About `RAVEPanel`". Consumers: spatial-ai-character, Longwave |
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

**The Quest Controller Bridge protocol is not that protocol, and lives in `RAVEInput`.**
Decided 2026-09-26. `RAVEPCVR`'s reservation is for Longwave's *headset → PC host* bridge
(the AVP streaming its hands and gamepads to a SteamVR host). The Controller Bridge protocol
(`RAVEQuestBridgeProtocol`, canonical header in `illixion/controller-bridge`) runs the other
way round: a Quest streams its Touch controllers *to* the visionOS app, which consumes them
as input exactly like a `GCController`. So the codec, the socket (`RAVEQuestBridgeSource`)
and the calibration it needs are sensing, polled through the same
`RAVETrackedControllerSource` protocol as the PSVR2 Sense backend, and every app that links
`RAVEInput` gets them with no new product to add. Only if the AVP → PC protocol is ever
shared does `RAVEPCVR` get built; the Quest pieces stay here either way.

### About `RAVEPanel`

Built 2026-09-28. It is **a RealityKit panel that shows any SwiftUI view in the room**, with
its chrome and its placing. It came out of spatial-ai-character's `ScreenPanel`, and it has
what Longwave's hand-pinned web windows and palm HUD need too:

- `RAVEPanel` (visionOS only): the attachment and its hosting fix; grab bar, resize corner
  and close button; drags with gain by distance, turning to face the viewer; the content
  scaled to a width in metres; fading through `OpacityComponent` (disabled at 0).
- **Placing:** `move(to:facing:)` for the world; `follow(_ anchor: RAVEPalmAnchor)` over a
  palm (summoned by turning it up); `RAVEPanelHeadFollow` for a panel that floats ahead of the
  viewer and trails their turns (Longwave's banner); `RAVEPanelHandMount` for a panel worn on
  the back of the wrist, always there, long edge along the arm, fading while that palm faces
  the viewer; and `RAVEPanelHeadLock` for one pinned to a spot in the view (OVR Toolkit's
  "attach to head"). The mount and the lock both give the inverse (`offset(placing:…)`), so a
  panel dragged by hand keeps its new place relative to its wrist or the view. `showsChrome`
  hides the handles outside an edit mode. *Follow an entity* (the character
  carrying it like a tablet) is not built; it waits for the character's holding animation.
- **Visibility verdict**, `RAVEPanelVisibility`: available (in the scene, enabled, space in
  the foreground), within a 60° cone of the gaze counting the panel's size, and a 1.5 s delay
  before an unseen panel stops running. Becoming unavailable stops it at once, and being
  seen again resumes it at once. `keepAwake(until:)` holds it running for a tool reading an
  unseen page. The app turns `isRunning` into a pause of whatever the panel holds.

The rules (`RAVEPanelRules.swift`: viewer, visibility, head follow, orientation, drag gain)
are framework-free and host-tested; `RAVEPanel.swift` is visionOS-only.

Why here, not in RAVESDK: it is XR-shaped (entities, input bindings, anchoring). It is
**content-agnostic** and must not import RAVESDK's `RAVEBrowser`. The app puts a browser view
into the panel, and a Mac-streamed window can go into the same panel later. It is the
RealityKit-host counterpart of `RAVEHolo`, which draws panels for Metal hosts.

**The palm anchor is shared with RAVEHolo, and lives in RAVEInput** as `RAVEPalmAnchor`,
aliased in RAVEHolo as `RAVEHoloPalmAnchor` so Oneiros and LambdaVision did not change. It
moved there because RAVEHolo's Metal 4 renderer does not build for the visionOS simulator.
A RealityKit app linking RAVEHolo just for the anchor would lose its simulator build.

**The hosting fix it carries** (measured on the AVP, 2026-09-28): a
`ViewAttachmentComponent` added from outside SwiftUI is put into a window only when the
entity's transform changes after it is already in the scene. Placing it in the same turn as
the add leaves a `UIViewRepresentable` inside at 0×0 with no window: blank, until something
moves it. Re-setting the same transform in a later frame is enough. A SwiftUI update of the
`RealityView` is not. `RAVEPanel` re-sets it each frame after a show until `isHosted`
(the app's probe, such as "the web view has a window") says so, or for 90 frames without one.

Sizing is a width in metres (a screen) or, with `contentScale`, a fixed points→metres scale
with the size following the content (a HUD designed in points).

Consumers: spatial-ai-character (`ScreenPanel`, the character's web screen; its
`scripts/sim-scenarios.py` checks placing, drags, tablet and pausing through it in the
simulator) and Longwave (the PCVR space's wrist HUD over the palm and its head-following
trial/bandwidth banner, `FoveatedImmersiveView.swift`, and the pinned web panels,
`PCVRWebPanelsDriver.swift`; device-only, since the simulator has no hand tracking).

Build it when the Longwave overlay starts, not before, and move Longwave's own RealityKit
palm HUD (`WristHUDDriver` in `FoveatedImmersiveView.swift`) onto it in the same change, so
the target starts with two real consumers. Longwave's risk to measure first: the frame and
power cost of a live page inside the foveated PCVR space (`ImmersiveSpace(foveatedStreaming:)`
with RealityKit content on top). Constantly updating Twitch chat is a good worst case.

## The isolation rule (both targets)

**The collection and sensing layers carry no isolation. This is a hard constraint, not a
preference**, and it is the single most important thing to preserve here.

Two of the three input consumers and two of the four diagnostics consumers poll from a
**render thread that cannot await anything** — Lambda's renderer, Longwave's 90 Hz datagram
loop. The other consumers drive the same code from `@MainActor`. So:

- `RAVEPinchDetector`, `RAVEHandJoystick`, `RAVEArmSwinger`, `RAVEPalmGeometry`, `RAVEEdgeTracker`,
  `RAVEGestureGate`, `RAVEPalmFacingGate`, `RAVEHandOwnership`, `RAVESystemPinchGate`,
  `RAVEStickShaping`/`RAVESnapTurnDetector`, `RAVESampleSeries`, `RAVEQuestCalibration`,
  `RAVEQuestHoldDetector`, `RAVEQuestAlignment`, `RAVEQuestBridgeProtocol` are **isolation-free value types**
- `RAVEMetricCollector` and `RAVEQuestBridgeSource` are **lock-guarded classes**, `@unchecked
  Sendable` — an actor would make `record()` / `poll()` async and unusable from exactly the
  callers that need them most
- `RAVEARKitHandSensor` and the SwiftUI views are the `@MainActor` conveniences *on top*;
  `RAVESpatialAccessorySource` is `@MainActor` for its lifecycle only — its
  `RAVETrackedControllerSource` witnesses (`poll`, `sendHaptic`) are `nonisolated` over a
  lock-guarded store, and must stay that way

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
pointing pose (index out, ring and little curled, middle either way: a one- or two-finger gun) is an explicit exit, and its fist test requires the
index curled, since a finger gun has three curled fingers too. `leftSwinging`/`rightSwinging`
tell the consumer which hands are free. LambdaVision
is the only consumer so far.

**Accidental input is the failure mode to design against.** Every filter below
exists because a gesture fired when nobody meant it, and every app had grown its own
guard for the same case. `RAVEPinchTuning` carries a **selection margin** (the nearest
finger engages only when the runner-up is ≥ 1 cm farther — nearest-wins read Oneiros's
thumb+index as thumb+middle), **finger-switch hysteresis** (another finger must beat the
held one by the margin for `fingerSwitchHold` before the pinch re-targets; the original
dropped it the moment a neighbour crossed the engage radius, emitting end+begin on
jitter), a **tracking-loss grace** (`update(sample: nil)` holds state 120 ms; deliberate
suppression is `forceRelease()`, which is immediate — `RAVEARKitHandSensor` uses it for
`suppressedHands`), and an optional **closing-speed** floor (off by default). `.legacy`
reproduces the original filter-light behaviour. `.clutch` keeps its instant engage —
Lambda's locomotion relies on it — and `.joystick` (index only, 150 ms) is the preset a
joystick hand should adopt. `RAVEArmSwinger` engages only on ≥ 2 reversals *and* the two
hands moving in opposite phase (a jog, not a shove or a clap), and its one-arm jump is
opt-in (`RAVEArmSwingTuning.legacy` restores the old rules). The engage/release logic every
app hand-built — menu holds, the reload charge, palm-up panels — is `RAVEGestureGate`
(hysteresis, hold-to-engage with a 0…1 `progress`, release grace, re-arm delay, caller-
evaluated conditions); `RAVEPalmFacingGate` presets it for panels (`.panel` = Longwave's
plain 0.95/0.70, `.forgiving` = Oneiros's pitch-invariant 0.88/0.70 + 0.4 s linger, both
with a new 0.12 s dwell). `RAVEHandOwnership` is the per-hand claim/priority/holdoff arbiter
(Lambda's `gunHandBusy`, Longwave's `suppressedHands`, as one rule), and
`RAVESystemPinchGate` is Oneiros's system-pinch-owns-thumb+index gate, generic over the
app's surface enum. **All of these thresholds are unverified on device** until the user
says otherwise — the simulator has no hand tracking.

`RAVEARKitHandSensor` reserves left + index for the joystick unless `joystickEnabled` is
false; `joystickPinchTuning` gives the joystick its own detector. The joystick's pinch is
kept out of `RAVEHandTickOutput.pinchEvents` but is still reported *held* in `left`/`right`,
because Longwave maps any held left pinch to its wire-level `leftPinch` flag.

The shared default deadzone is 3 cm. Zero made normal ARKit wrist jitter into movement in
the two consumers that did not override it; Lambda's long-standing 3 cm setting was the
proven behavior. `RAVEJoystickOutput.visualization` is the renderer-neutral overlay seam —
keep it plain SIMD data rather than importing RealityKit or a Metal renderer here.

### Tracked controllers

`RAVETrackedControllerSource` (`poll(now:)`, `sendHaptic(_:)`, both nonisolated) with plain
`RAVETrackedControllerState` values per hand: pose in the **ARKit world**, `isTracked`,
`isInHand`, trigger, analog grip, stick, `RAVEControllerButtons` (position-named: `primary`
is A/X/Cross/Square) with capacitive touch bits gated by `touchValid`, battery. Two backends:

- **`RAVESpatialAccessorySource`** (visionOS only) — lifted from Longwave's
  `SpatialAccessoryTracker`: `GCProductCategorySpatialController` + ARKit
  `AccessoryTrackingProvider`, chirality from `heldChirality ?? inherentChirality`, CoreHaptics
  per side. **Never run on hardware.** Longwave adopted it (replacing its own copy) on 2026-09-26.
- **`RAVEQuestBridgeSource`** — a Quest on the desk running the Controller Bridge app streams
  Touch controllers over UDP :9520. Opt-in: nothing listens until `start()`. Once started it
  advertises `_controllerbridge._udp` (default on, `advertise = false` opts out) and answers
  every probe — at protocol v3 with its kind, name and whether it is accepting — so the Quest
  app connects with no typed address; sends the status heartbeat the Quest app's "connected"
  pulse waits for and haptics to sender:9521. **Apps need `NSLocalNetworkUsageDescription`
  and `NSBonjourServices` = `_controllerbridge._udp`** — without the first the listener hears
  nothing, without the second the advertisement fails. It never hears the Quest's
  *broadcast* probes, by design: visionOS needs Apple's managed multicast entitlement to
  receive broadcasts, and Network.framework does not do broadcast at all (TN3151; measured on
  macOS too). The Quest therefore also probes unicast (Bonjour results + a small-subnet
  sweep), which needs no entitlement. See the source's header before "fixing" this.

The Quest poses are in the Quest's own stage space, so the source aligns them itself against
ARKit hands the app feeds in (`observeHands`, a `RAVEHandSample` per side — it never opens an
ARKit session). `RAVEQuestCalibration` (4-DoF yaw + translation Kabsch, per-hand grip offset,
weights, robust re-solve, 60 s ageing, 24 samples / 0.25 m spread), `RAVEQuestHoldDetector`
(put-down vs moved desk) and the watchdog loop in `RAVEQuestAlignment` are **faithful ports
of the Longwave PCVR host's C++**, constants and tests included. Both now run **20**
alternating offset rounds (`RAVEQuestCalibration.offsetRounds`; the host's `kOffsetRounds`,
OpenXRLayer `99ce197`, pinned there by `TestQuestCalibrationWideRotationConverges`), raised
from the original 3 with the user's approval on 2026-09-26. Three rounds do not converge when the controller rotates widely during
sampling — the realistic case — and left ~4 mm RMS / ~0.6° yaw on the test ring; 20 reach
float noise, and `rotatingOffsetConverges` holds that (dropping the count back fails it).
One difference remains, on purpose: the Swift rounds exit early once neither offset moves
more than 1 µm (the host always runs all 20), because the Swift solve runs under the
source's lock that `poll()` also takes — the worst-case full-ring solve is ~0.2 ms optimised /
~7.5 ms at -Onone, guarded by `fullRingSolveCost`. The two agree to within that micron.

A persisted transform is restored **untrusted** by default (`trustRestoredCalibration =
false`): ARKit re-establishes its world origin every session, so last launch's transform is
right only when the origin lands in the same place. Untrusted, it publishes nothing until one
fresh pair agrees, and the watchdog discards it within a second when none does.

### Mouse

`RAVEMouseSource.shared` owns every `GCMouse`'s handler slots and fans plain `RAVEMouseEvent`s
(connect/disconnect with a count, raw motion +Y up, buttons incl. auxiliary, one wheel axis per
event) out to `@MainActor` subscribers on the main queue. **It is a process-wide singleton on
purpose:** a `GCMouseInput` handler is a single slot, so two parts of one app installing their own
(Longwave's Moonlight session and its Mac desktop bridge) silently stole the mouse from each other.
The first `subscribe` starts it, the last `cancel` stops it, and a late subscriber is replayed a
`.connected` per mouse already there. `isConnected` is nonisolated — the signal to stand down the
system pointer paths that deliver the same click again (SwiftUI taps, spatial events).

The shared arithmetic is value types: `RAVEMouseStepAccumulator` (carry the fraction, truncate
toward zero), `RAVEMouseButtonGate` (forward a press only when allowed, always its release, never
a second press of a held button), and the lock-guarded `RAVEMouseMotionAccumulator` for a render
thread draining per-frame motion. Speed curves, wheel clamps, Y inversion and wire encodings stay
in the apps. Converged from LambdaVision's `MouseInput` and Longwave's `MoonlightMouseManager` /
`MacNativeMouseBridge` (2026-10-06); the GameController half is unverified on device.

**`RAVEFingerBindingTable`'s `Codable` is hand-written and wire-compatible.** It emits the
same named fields (`rightIndex`, `rightMiddle`, …) two apps already have in `UserDefaults`,
and decodes `leftIndex` with `decodeIfPresent` because one app never stored it — its
reserved joystick slot was not a value it kept. Synthesised `Codable` would reset every
user's bindings.

## Logging

RAVEInput is the one target that logs, and it has the package's only external dependency,
`../DebugTrace`. Its sources take a `log:` closure of `DebugLogMessage`, not `String`, so each
value keeps its own privacy through the app's `DebugLogger`: a Quest's address (hashed),
advertised name, controller vendor names and error text stay private, while counts,
calibration figures and error codes are public. Apps forward the message as it is
(`log: { AppLog.input.log("HandTracker: \($0)") }`). Never flatten it to a String.

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

## RAVEHolo: interactive panels

Generalised from Oneiros's `WristPanelProbe` (device-verified 2026-09-22) so any Metal /
Compositor Services host can put pinchable controls on a palm instead of opening a
static window. RealityKit hosts are out of scope on purpose: a SwiftUI attachment already
gets hover and pinch routing for free, and a `CompositorLayer` is exactly the host that
cannot show one.

**The scene is the one source of truth for where a control is.** `RAVEHoloPanel.targets`
(`target(...)`, or `button(...)`, which draws and registers together) feeds both
selection paths: Compositor Services **tracking areas** (the system draws gaze hover and
delivers the pinch with `trackingAreaIdentifier == id`; the app never sees gaze) and
`RAVEHoloScene.hit(origin:direction:)` (Mac hosts, debug-server presses, a pinch that
arrived with only a selection ray). Id 0 is reserved.

**Tracking areas are their own single-sample pass** (`RAVEHoloRenderer.encodeTargets`,
enabled by `Configuration.trackingFormat`). The drawable's tracking texture is
single-sample integer, so it cannot join an MSAA colour pass (LambdaVision's); a separate
pass works for every host. With `trackingDepthFormat` set the targets depth-test (`>=`,
reverse-Z) so a control behind scene geometry is not selectable.

Host checklist (also on `RAVEHoloCompositor`):
1. `RAVEHoloCompositor.configureTrackingAreas` in the layer configuration (device offers
   `r8Uint`, same layout as colour).
2. Per drawable: `registerTargets(of:on:)` → render values, then `encodeTargets` into a
   pass over `drawable.trackingAreasTextures[0]`, cleared to 0. Tracking areas last one
   drawable — register every frame the panel is visible.
3. `onSpatialEvent`: an event whose `trackingAreaIdentifier.rawValue` is a target id goes to
   the control — **before** any world tap / trigger path — and still reports its phases to
   `RAVESystemPinchGate` so the raw hand-tracker reading of the same pinch is refused.
4. `.persistentSystemOverlays(.hidden)` on the `CompositorLayer` **content**. The
   scene-level modifier alone hid the palm-up Home indicator only the first time; from the
   second palm-up on it covered the panel (Oneiros, 2026-09-22).

`RAVEHoloPalmAnchor` is the show/place/follow/fade rule (gate + lift along the palm normal +
upright billboard + snap-then-ease + fade). Its presets differ on purpose: `.overPalm`
(5 cm, reads as held) and `.offPalm` (Oneiros's 18 cm projection). Pair it with the gate
metric the product wants — `RAVEPalmFacingGate.panel` for an intentional "look at your
palm" (LambdaVision's debug panel, which must not appear while that hand drives the
joystick; use `showAllowed`), `.forgiving` for a game HUD. Advancing it on the render
thread with a pose predicted for the drawable removes the tick of lag a tick-driven pose
trails by.

`RAVEHoloInteraction` (lock-guarded, for the isolation rule) records presses on the thread
that receives them and gives the scene builder a 0…1 flash. `RAVEHoloLayout` is a vertical
stack (title / row / gauge / sparkline / buttons / spacer) for debug readouts; labels are
upper-cased because the default atlas is capitals only. Sizes in `RAVEHoloTheme` are for
35–50 cm: buttons ≥ 2.2 cm tall so gaze lands on them. v1 is discrete controls only — a
drag/slider needs the pinch's pose over time, which has not been tried.
`RAVEHOLO_LAYOUT_SNAPSHOT=/x.png swift test --filter rendersADebugLayout` renders a sample
layout.

**Unverified on device:** everything except what the probe proved (hover, pinch routing, no
world tap behind the panel). The separate target pass, the anchor tuning and the layout
sizes are Mac-tested only.

## How consumers use this

Five apps under `~/Projects/`. During development each references this package as a
**local** Swift package (`XCLocalSwiftPackageReference`), so edits are immediate. Once a
target stabilises, tag it and switch that app to `.package(url:)`.

What each app is and where new code goes lives in `~/Projects/CLAUDE.md`; this table is only
the link list.

| App (directory) | Links |
|---|---|
| `Oneiros` (visionOS + macOS) | `RAVEInput`, `RAVEDiagnostics`, `RAVEHolo` (+ SDK's `RAVEConsole`) |
| `Longwave` (visionOS + iOS + macOS) | `RAVEInput`, `RAVEDiagnostics` (+ SDK's `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVECamera`) |
| `halflife-visionos/LambdaVision` | `RAVEInput`, `RAVEDiagnostics`, `RAVERig`, `RAVEHolo` (+ SDK's `RAVEConsole`) |
| `Hypnos` (visionOS + iOS) | `RAVEDiagnostics` (+ SDK's `RAVENet`, `RAVEUI`, `RAVEConsole`, `RAVEMedia`, `RAVESlideshow`) |
| `spatial-ai-character` | `RAVERig` through its own `CharacterKit` package (+ SDK's `RAVEConsole`); it dropped `RAVEDiagnostics` with the debug server |

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
