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
| `RAVEInput` | Hand + controller sensing, pinch/joystick/palm geometry, binding tables, tracked controllers (PSVR2 Sense; Quest Touch over the LAN via Controller Bridge), physical mouse (`RAVEMouseSource`), the mouse-catcher rule for immersive spaces (`RAVEMouseCatcherRule`), a whole body from PoseHub's cameras (`RAVEBodyStreamSource`, see "Body stream") |
| `RAVEDiagnostics` | Frame profiler, metric collector, feed gating, HUD views |
| `RAVERig` | Skeleton geometry, humanoid inference, FABRIK, pose solving, leg stepping, a tracked performer driving a humanoid (`PerformerRig`, head + hands, mirrored or not, or placed as the performer's own body so its hands land on theirs, legs folded when they sit, legs walking from a `PerformerLowerBody`), and that lower body made up from the head (`PerformerGait`: steps in time with the head's bob; its pelvis and feet are tracker poses, meant for Longwave's PC VR too), and that lower body measured (`TrackedLegs`: planted feet pinned, gaps held, faded against the gait with `PerformerLowerBody.mix`) — shipping, see README |
| `RAVEHolo` | In-world holographic UI for Metal hosts: SDF glyph atlas (CoreText, no font shipped), panel/gauge/text scene, Metal 4 renderer drawing into a pass the host owns. Shader source compiles at runtime (SwiftPM's CLI builds no `.metal`); `RAVEHOLO_SNAPSHOT=/x.png swift test --filter RAVEHolo` renders a sample panel to look at. Renderer is `@available(macOS 26)` (Metal 4) without raising the package floor. Also interactive: pinchable targets (Compositor Services tracking areas + a CPU ray hit-test), widgets/stack layout, and a palm anchor (`RAVEHoloPalmAnchor`, an alias of RAVEInput's `RAVEPalmAnchor`, shared with `RAVEPanel`) — see "RAVEHolo: interactive panels". Depends on `RAVEInput` for the anchor only. Consumers: LambdaVision (HEV HUD + developer palm debug panel), Oneiros (Metal-host wrist HUD) |
| `RAVEPanel` | Any SwiftUI view as a panel in a RealityKit scene: chrome, the attachment hosting fix, world / palm / head-follow placing, and a visibility verdict to pause content by; also draws a `RAVESleeve` (`RAVESleevePanels`, `RAVESleeveHost`). Rules host-tested, entity half visionOS-only. Depends on `RAVEInput` for the palm anchor and on `RAVESleeve`. See "About `RAVEPanel`". Consumers: spatial-ai-character, Longwave |
| `RAVESleeve` | A HUD worn on the forearm, replacing the palm-anchored panels: `RAVESleeveFrame` (the arm as a coordinate system, from the hand skeleton's `forearmWrist` / `forearmArm` joints), `RAVESleeveArmGate` (drops readings that could not be true), `RAVESleeveFollower` (one-euro filter: on the arm in motion, still at rest), `RAVESleeveSteadier` (steadies it by degrees as the other hand nears and at rest), `RAVESleeveLayout` (Codable pages of tiles on the outer and inner face: label, gauge, button, toggle, hold, slider, page, radial, dock, custom), `RAVESleeve` (faces that show as the arm turns, flat tile placement, presses from gaze + pinch and from a fingertip coming down through a tile, events), `RAVESleeveRadial` (a radial menu travel, a stick, gaze and touch all drive), docked panels, `RAVESleevePresets.mediaRemote`. Foundation + simd, host-tested, draws nothing. Depends on `RAVEInput`. See "About `RAVESleeve`". Consumers: none yet (planned: every app with an immersive space) |
| `RAVESharedSpace` | Several apps in one immersive space as modules of one process: `RAVESpaceModule` (what an app implements: content under a root the host gives it), `RAVESpaceBroker` (open while anyone wants it), `RAVESpacePolicy` (the space's one immersion style, arm visibility and surroundings, from all members), `RAVESpatialServices` (one ARKit session), `RAVESpaceHost`/`RAVESpaceView` (per-module roots, taps routed to their module). Policy and broker host-tested. Consumers: Nexus, and spatial-ai-character as its module. See "About `RAVESharedSpace`" |
| `RAVEModuleBus` | The channel between modules that share a process: typed context feeds a module publishes (`RAVEFeedKey`, rate-limited, rolling window, privacy label), actions it offers (`RAVEBusAction`, validated before they run), and the shared media vocabulary (`RAVEMediaFeeds`, `RAVEMediaControlling`, `RAVEMediaDigest`) so a companion can watch along without importing the player, and the chat vocabulary (`RAVEChatFeeds`, `RAVEChatSending`, `RAVEChatDigest`) so it can read a live chat without knowing the site. Foundation + simd only, host-tested. Consumers: Nexus (planned: Hypnos as publisher, spatial-ai-character as reader). See "About `RAVEModuleBus`" |
| `RAVEFoveatedGaze` | Where the wearer looks, through Apple's FoveatedStreaming (visionOS 27): `RAVEFoveatedGazeFeed` (one feed protocol), `RAVEFoveatedProviderFeed` + `RAVEFoveatedGazeReceiver` (host side of the official route), `RAVEGazeOnlyStreamingProvider` (a whole gaze-only provider extension, subclassed in one line; needs the `foveated-streaming-provider` entitlement), and `RAVEFoveatedGazeFeeds.plugin()` (a feed an app links in from outside its repo, found by the Objective-C name `RAVEFoveatedGazePlugin`). All under `os(visionOS) && canImport(FoveatedStreaming)`, so it builds empty on macOS, iOS and the simulator; its own target so other RAVEInput consumers never link FoveatedStreaming. Samples travel as `RAVEGazeWire` bytes (RAVEInput, host-tested). Extension target template: `Templates/FoveatedGazeProvider/`. Consumers: spatial-ai-character, Longwave |
| `RAVEGuardian` | A Guardian-style room boundary from visionOS's world mesh: fitted-plane grids on walls, doors and windows appear briefly when a hand or controller accelerates toward one; nearby furniture can appear as a translucent hologram. The headset is left to visionOS's own protection. `RAVEGuardianMap` (barrier triangles in 1 m chunks per mesh anchor), `RAVEGuardianMonitor` (smoothed acceleration, rate-limited cues, furniture proximity and per-chunk fade), `RAVEGuardianMeshLayout`/`RAVEGuardianPattern`, `RAVEGuardianSettings` + store (on by default), `RAVEGuardianSettingsControls` and `RAVEGuardianMetalRenderer` (the Metal drawing for Compositor Services hosts) are host-tested; `RAVEGuardian` (RealityKit root ticked by a System), `RAVEGuardianOverlay` (the same rules for Metal hosts), `RAVEGuardianMeshExtraction`, `RAVEGuardianProbe.head/hand` and `RAVEGuardianWorldSensor` (its own scene reconstruction) are visionOS-only. See "About `RAVEGuardian`". Consumers: Longwave (PCVR space), spatial-ai-character |
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

### About `RAVESleeve`

Decided with the owner 2026-11-12: every hand-anchored HUD in the portfolio becomes a sleeve.
Before it, each app placed a card from the palm joint, eased it with a 0.06 to 0.1 s time
constant and billboarded it to the eyes, so the card floated near the hand rather than staying
on the arm, and each had its own summon gesture. What it replaces, when the migrations land:
`RAVEPalmAnchor` and `RAVEPanelHandMount` (they become shims over this), Longwave's
`WristHUDDriver`, spatial-ai-character's `StreamHandPanel`, Oneiros's two wrist HUDs,
LambdaVision's forearm vitals and palm debug panel.

The owner's decisions, which are not up for re-litigation:
- **Flat tiles** tangent to the arm, not a curved surface. A RealityKit host keeps SwiftUI and
  the system's hover and pinch routing that way.
- **Declarative layout shared, glue and graphics per repo.** The point of the shared layout is
  that a fix ports across the apps. How a tile looks is each app's: a layout carries labels,
  icon keys and a role, never colours. `.custom` tiles are the hatch for what the vocabulary
  lacks (Oneiros's hotbar).
- **Worn on the non-dominant arm by default**, with a setting to swap.
- **Interaction is gaze + pinch and direct touch**, both always available.
- **`RAVESleeveRadial` replaces LambdaVision's weapon wheel** (`WeaponWheel` + `WeaponWheelPanel`,
  proof-of-concept quality per the owner). It keeps `RAVERadial`'s sector maths and adds what
  the old drivers lacked: one open menu answers to travel, a stick, gaze and touch at once.
  `RAVERadialHandMenu` / `RAVERadialStickMenu` go when LambdaVision has moved.
- **Big panels dock to the sleeve** (web browsers, stream controls): a tile opens them beside
  the arm, in the view or in the room. Longwave and spatial-ai-character get these.
- **Hypnos's HUD and Big Screen modes wear `RAVESleevePresets.mediaRemote`**, whose action ids
  are RAVEModuleBus's `RAVEMediaActionID` values (a test holds them equal).
- The end state is a **Stream Deck replacement**: user-made pages of keys (the layout is JSON),
  actions sent to the app through RAVEModuleBus and to a Mac or PC through RAVESDK's
  `RAVECompanion`. Neither is linked from here; the app is the glue.

How it is split: this target is rules only and draws nothing. `RAVEPanel` draws it for
RealityKit hosts (`RAVESleevePanels`: one flat SwiftUI attachment per tile and one for an open
radial menu; `RAVESleeveHost` wires a sleeve to them, and an app passes its own `tile:` builder
to restyle; built for visionOS, not yet run on a headset) and `RAVEHolo` will for Metal hosts
(not written yet), so a
snapshot (`RAVESleeveSnapshot`: placed tiles with a transform, size, state, press and hover) is
the whole contract between the rules and a renderer. Tile `target` values are stable for a
layout, for Compositor Services tracking areas.

What wearing it on a Vision Pro settled (2026-11-12, spatial-ai-character's stream sleeve; the
defaults in `RAVESleeve.Tuning` and `RAVESleeveMetrics` are still estimates):
- **Use the tracked forearm bone, positions only.** `forearmArm`'s own `isTracked` is false on
  about two frames in three with the arm held up, but its estimated pose is good (LambdaVision
  relies on it), so the anchor's tracking is the only gate. A body-model guess of the elbow
  (shoulder from the head, two-bone solve) was tried and removed: on a wireframe the bone held
  still while the guess wandered. Build the frame from the wrist and elbow *positions*, never a
  joint's orientation: tiles fixed in the wrist joint's frame shook with its orientation noise.
- **`RAVESleeveArmGate` drops readings that could not be true** (a spike of tracking loss)
  before the follower smooths.
- **Pose the tiles through RealityKit's anchor for the wrist joint** (`RAVESleeveHost.update`'s
  `anchorFrame`): posed from ARKit in the app alone they trail the arm by frames, enough for a
  rising arm to cover its own sleeve. The sleeve still runs in the world; each tile is given its
  place relative to the joint as the app last read it. RealityKit's frame for the joint is
  ARKit's turned half way about its x axis on a left arm; a right arm is unchecked.
- **ARKit's arm shakes at the source**, more in poor light and dark sleeves, and more with the
  other hand over the forearm. The app steadies the sleeve by degrees (never a snap freeze, the
  owner's call): more as the other hand nears and while the arm rests, by lowering the
  follower's cut-off, and off the anchor once well steadied. That is `RAVESleeveSteadier`; the
  owner called the result good on the headset with its defaults.
- **Tiles are plain fills, not materials**, and unchanged tiles are not re-sent to the renderer.
- Open: a line of blocks eating the tiles when the headset is hot, and the tiles fading where
  visionOS judges the arm to be in front. `upperLimbVisibility(.hidden)` did not stop either.
  Gaze and pinch presses register reliably; finger presses register but were few in the
  one session counted, so direct touch still wants a proper trial.

Hand tracking exists only inside an immersive space, so a windowed app wears a sleeve only as a
module of a shared space (Nexus).

### About `RAVESharedSpace`

Moved from Nexus (`~/Projects/Nexus`, its spike `NexusKit`) on 2026-11-05, after the headset
checks in `Nexus/docs/PLAN.md` passed. visionOS shows only the space-owning app's windows
while an immersive space is open, and one app can't open another's scenes, so Longwave,
Convolution and spatial-ai-character can share a room only as modules of one app. It is here
rather than in Nexus because those apps have to conform to `RAVESpaceModule` and can't
depend on Nexus; it is Engine-shaped (the space, its settings, ARKit).

- **A module never opens or dismisses a space.** It asks the broker and releases; the space
  is open while anyone holds a request. A bare `dismissImmersiveSpace()` in a module closes
  everyone's.
- **The policy's rules** (in `RAVESpacePolicy`'s header): immersion follows the newest
  request, arms are hidden if anyone hides them, surroundings follow the newest module with
  a preference, hands run if anyone needs them. Measured on the AVP.
- **Everything a module adds stays under its root**: that is how a tap finds its module
  (`RAVESpaceModuleComponent`) and how leaving takes it all away. Gestures in the space are
  the host's; a module gets `tapped(_:)`.
- **Two ARKit sessions in one process both get hand anchors** (measured: the same rate), so
  a ported app may keep its own session at first; moving it onto `RAVESpatialServices` is
  cleanup.
- **The system can close the space** (Digital Crown, another app's space): every member
  hears `spaceTakenAway()` and its request is already gone.
- **Gestures in the space are the host's, routed by owner**: tap, drag, two-hand rotate and a
  0.8 s long press, each sent to the module whose root is above the entity it landed on. A drag
  or rotation stays with the module it began on until it ends. A module also hears the space's
  scene phase and immersion amount, including the current values when it mounts late.
- **`update(_:_:)` changes a member's requirements without moving it to the newest place**; a
  module follows its own settings with it (spatial-ai-character's filter and Perform), so a
  setting change doesn't take immersion from whoever joined after it.
- Window ids carry the module's prefix (`orbit.main`), and RAVESDK's `RAVEWindowScope`
  scopes RAVEUI's window helpers by it. Neither package imports the other.

### About `RAVEModuleBus`

Added 2026-11-08 for Nexus's "watching together" (`~/Projects/Nexus/docs/PLAN.md`, "The interop bus").
Modules never import each other; they meet here. It does not depend on `RAVESharedSpace`, so a
module can link it whether or not it lives in a shared space (a standalone app just has no reader).

- **Feeds are typed keys a vocabulary declares** and both sides share (`RAVEMediaFeeds`). A feed with
  no subscriber costs a store of at most `retainedLimit` samples; `retention` 0 keeps only the latest.
- **`minInterval` drops chatty publishes** (unless `force`); a feed name that already carries another
  type refuses the publish.
- **`retire(module:)` on unmount** removes that module's samples and actions but leaves subscribers, so
  readers hear it again when it returns. A host must call it from the module's `unmount`.
- **Privacy is a label, not a gate**: `.personalText` / `.personalImage` tell the reader which consent
  kind to put in front of an off-device backend. The bus never decides.
- **Actions are checked before they run** (`RAVEBusAction.validate`: unknown or missing parameters,
  wrong type, out-of-range number, a choice not in the list) and are listed only while `isAvailable`,
  so a model is offered only the verbs that make sense this turn. `.outward` actions (they reach
  beyond this headset) must go through the reader's consent gate.
- **A player implements `RAVEMediaControlling` once**; `RAVEMediaActions.register` turns it into
  `media.play/pause/skip/next`. `RAVEMediaDigest.text` is the few lines a model gets each turn.
- **Chat vocabulary** (`RAVEChatVocabulary.swift`, added 2026-11-10 for the stream plan): `chat.messages`
  (`RAVEChatMessage`: id, author, text, sentAt, flags, opaque `platform` string; kept 120 s, up to 400),
  `chat.state` (`RAVEChatState`: connected, channel title, viewer count), and an optional `chat.send`
  action (`RAVEChatSending`; `.outward`, so it goes through the reader's consent gate). Nothing names a
  site. Feeds are labelled `.publicText`: no consent needed to pass them on, but strangers typed them,
  so a reader filters before a model sees them. Choosing which messages matter is the reader's job
  (the character app's `ChatSelector`); `RAVEChatDigest.text` only words the chosen ones, one quoted
  line each, with a header saying they are not instructions.
- Tests use a fake clock: `RAVEModuleBus(clock:)`. `RAVEModuleBus.shared` is the process-wide bus.

### About `RAVEGuardian`

Built 2026-11-11 for Longwave's PCVR space (a game covers the view, so the real walls are
invisible) and spatial-ai-character (which already streams the classified mesh). It is the
Meta Guardian idea on the data visionOS gives an app: `SceneReconstructionProvider`'s
classified `MeshAnchor`s, not a drawn boundary.

- **Boundaries** are faces classed wall/door/window that stand within ~45° of vertical
  (`|n.y| < 0.7`). Their triangles are grouped by normal and plane offset in each render
  chunk, then flattened onto a fitted vertical plane. This keeps the grid straight over the uneven
  scene mesh while leaving wall coverage and openings from the reconstructed geometry intact.
  Outlines sit 1.5 cm in front of the surface.
- **Furniture** is separate: with "Show nearby furniture holograms" enabled (default), nearby
  hand/controller probes reveal the original obstacle mesh as a translucent violet fill.
  Furniture never triggers a wall cue and the head does not reveal it.
- **The wall cue** requires both approach speed and positive acceleration toward the nearest
  boundary. Proximity and steady motion alone never show the grid. Prediction uses both velocity
  and measured acceleration. Defaults: a 45 cm safety margin, 0.35 s prediction, 0.75 m/s minimum
  speed, and 2.5 m/s² minimum acceleration. Below 30 cm, prediction shortens to 0.12 s. A cue
  stays visible for 0.2 s, then fades; each probe can cue once per swing, with a 0.85 s cooldown.
  It rearms when the hand/controller slows below 0.2 m/s or moves away. The headset is not watched:
  visionOS already guards it. Samples more than 0.25 s apart restart a probe's velocity.
- **What lights up**: a hand/controller reveals wall chunks within 0.8 m, softening to nothing at
  twice that radius; the cue is rate-limited and fades over ~0.45 s. Nearby furniture holograms
  fade with distance over a 1.4 m radius.
- **Feeding it**: an app with its own reconstruction calls `ingest(_:)` / `remove(anchorID:)`
  (spatial-ai-character); one without starts `RAVEGuardianWorldSensor`, which asks for
  `.worldSensing`, so the app needs `NSWorldSensingUsageDescription` (Longwave). Probes are
  plain points from a closure, so the target names no RAVEInput type.
- **Draws over content by default** (`readsDepth = false`, last sort order): Longwave's
  RealityKit content is depth-tested against the stream, and a game object nearer than the
  wall must not hide a safety outline. `drawsOverContent: false` restores normal occlusion.
- `RAVEGuardianDemoRoom` makes a tessellated box room for the simulator (no scene mesh there)
  and tests; spatial-ai-character's `setGuardian demoRoom=true` uses it. The base grid and
  fade were simulator-verified 2026-11-11. **Unverified on device**: the fitted planes, wall
  coverage on a real mesh, acceleration thresholds, furniture hologram visibility, the cost of
  Longwave's second reconstruction session, and whether `readsDepth = false` draws over the
  foveated stream as intended.
- **Compositor Services hosts** (added the same day for Longwave's Shell A): `RAVEGuardianOverlay`
  runs the map and monitor on the main actor at ~90 Hz (the probes live there) and publishes a
  snapshot to `RAVEGuardianMetalRenderer`, which the host's render thread encodes per eye view after
  its own drawing: lock-guarded, never awaits (the isolation rule). The pattern is computed in the
  fragment shader from metres along the wall, so style, spacing and line width need no rebuild; no
  depth test, premultiplied blend, load not clear, the view's rate map on the pass. Its host test
  draws the demo room offscreen on the Mac. `RAVEGuardianWorld` is the mapped room both paths
  share; the sensor feeds any `RAVEGuardianMeshSink`. LambdaVision/Oneiros could adopt it the same way.
- Not done: passthrough breakthrough when the head crosses a wall.

## The isolation rule (both targets)

**The collection and sensing layers carry no isolation. This is a hard constraint, not a
preference**, and it is the single most important thing to preserve here.

Two of the three input consumers and two of the four diagnostics consumers poll from a
**render thread that cannot await anything** — Lambda's renderer, Longwave's 90 Hz datagram
loop. The other consumers drive the same code from `@MainActor`. So:

- `RAVEPinchDetector`, `RAVEHandJoystick`, `RAVEArmSwinger`, `RAVEPalmGeometry`, `RAVEEdgeTracker`,
  `RAVEGestureGate`, `RAVEPalmFacingGate`, `RAVEHandOwnership`, `RAVESystemPinchGate`,
  `RAVEStickShaping`/`RAVESnapTurnDetector`, `RAVEMotionSmoother`, `RAVEInputModeSelector`/`RAVEHeldCommands`, `RAVEThumbGestures`, `RAVEArmSwingLocomotion`, `RAVERadialHandMenu`/`RAVERadialStickMenu`, `RAVEFingerGunTrigger`, `RAVESampleSeries`, `RAVEQuestCalibration`,
  `RAVEQuestHoldDetector`, `RAVEQuestAlignment`, `RAVEQuestBridgeProtocol`, `RAVEGamepadSnapshot` are **isolation-free value types**
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

### Body stream

PoseHub (miscale's `Tools/PoseHub`, Python) watches the performer with two or more cameras and sends a
fused metric skeleton over UDP: joints and tracker poses (head, hips, feet, knees, chest), specified in
`Tools/PoseHub/BODY_STREAM.md`. Consumers subscribe every second and frames come back, so no device opens
a port. Three decoders read the same bytes, each tested against the hub's fixture: the hub's own, this
one (`RAVEBodyStreamProtocol`), and the Longwave broker's C++ (`SessionBroker/broker/body_stream.cpp`,
VRChat OSC trackers).

- **`RAVEBodyStreamSource`** (lock-guarded, isolation-free like the Quest source): finds the hub over
  Bonjour (`_posehub._udp`) or at an address, subscribes, keeps the newest frame. It connects to the
  addresses in the hub's TXT record in turn rather than to the service: a UDP `NWConnection` to the
  service sat in "preparing" for good on macOS 27 although `dns-sd` resolved it, and a hub on a
  machine with several networks advertises addresses some consumers can't reach. Apps need
  `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `_posehub._udp`.
- **`RAVEBodyAlignment`**: the hub's space and the headset's are both gravity-aligned, so a 4-DoF fit
  (yaw + translation, 2D Kabsch, robust passes, 60 s ageing) maps one onto the other, from pairs the
  app gives away for free: the headset's head and wrists against the cameras'. A frame is 50–90 ms
  old on arrival, so the source pairs it with where the headset had them *then* (clock-synchronized
  capture time; `latency` plus `networkDelay` for older hubs) and skips pairs from anchors moving over 1 m/s. No per-anchor offsets (unlike
  `RAVEQuestCalibration`): a BlazePose wrist and an ARKit wrist are the same point, near enough,
  and the head's between-the-ears-to-eyes offset is a fixed estimate (`headOffset`).
- **`TrackedLegs`** (RAVERig) turns hips, feet and optional knees into a `PerformerLowerBody`.
  Pass capture timestamps: repeated render polls must not count as new measurements. Its `fallback:`
  argument blends lost feet independently back to the gait; `leftWeight`/`rightWeight` expose quality.
- **`PerformerBodyTracking`** (RAVERig) is the common policy over source-independent
  `PerformerBodyObservation`: headset head/hands win, cameras supply torso and hidden arms, and
  `TrackedLegs` owns lower-body fallback. App adapters map RAVEInput joints into it; neither target
  depends on the other. Camera wrists carry no finger observations. `PerformerRig` consumes torso,
  knee directions and reflected lower bodies, so mirrors use the same motion as the own body/camera.
- Extended hubs exchange clock pings, mark calibration generations, and accept time-matched headset
  references. Call `observe(... headRotation:)` to contribute the real head to the hub's tracker
  output. Raw camera wrists remain independent alignment measurements; a fused head never certifies
  its own alignment. Fits require <=8 cm robust RMS and >=70% inliers; failed fits collect afresh.
  Total pose age includes inference and network. Recalibration invalidates the consumer's limb state.
  Protocol details and limitations live in `miscale/Tools/PoseHub/BODY_STREAM.md`.
- **Setup status** (`RAVEBodyHubStatus`, `Status.setup`): the hub calibrates its cameras by itself and
  sends its state, one prompt (code and English text) and a line per camera (framing, placed, moved,
  progress) twice a second, before it has any frames to send. Show it as it comes, so setup reads the
  same in every app; a source counts any datagram as the hub being reachable. Only a full recalibration
  or a headset scale correction changes the space (new generation); a camera joining later doesn't.
- Test against a real hub: `python -m posehub play <recording.jsonl>` there, then
  `RAVE_BODY_HUB=127.0.0.1:7711 swift test --filter liveHub` (or `RAVE_BODY_HUB=discover`); a
  camera-less `posehub serve --osc off` and `RAVE_BODY_HUB_SETUP=127.0.0.1:7711 --filter liveHubSetup`
  for the status.

**Unverified on device:** the alignment against a real headset, the head offset, and whether
BlazePose still sees the face under a headset (the head pair only; wrists carry the fit).

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

### Input mode, keyboard, smoothing, thumb gestures (2026-11-02)

Moved out of LambdaVision's app code so a second consumer (Northstar) can link them. All
engine-neutral: nothing here names Half-Life, Xash or a game's commands.

- **`RAVEInputMode`** (`RAVEInputModeSelector`, `RAVEInputModeSetting`, `RAVEInputHandoff`,
  `RAVEHeldCommands`, and the lock-guarded `RAVEInputModeArbiter`): one owner among hands,
  keyboard+mouse and gamepad. A device used takes the mode; hands come back on a deliberate
  hand action only after `handsReclaimSeconds` with no device touched; idle never flips it. A
  handoff says what the old owner lets go of. **The game maps `unstickKeyboardMoves` to its
  own stop-moving commands**: LambdaVision's list was `-forward -back -moveleft ...`, an
  engine detail that stayed behind.
- **`RAVEKeyboardSource` / `RAVEKeyCharacters`**: `GCKeyboard` attach, held keys, shift,
  `isInUse(now:)` (stand hand gestures down while hands rest on keys), and the US-layout ASCII
  table. A key's meaning to a game (an engine's key numbers, snap-turn keys) stays in the app.
  Needs a window under the pointer or the mouse catcher on visionOS to receive anything.
- **`RAVEMotionSmoother` / `RAVEEventIntervalStats`**: two critically damped stages that
  conserve every count, for GCMouse's uneven delivery on visionOS. Smoothing is the app's
  choice; `RAVEMouseMotionAccumulator` still drains the raw motion.
- **`RAVEThumbGestures` / `RAVEThumbContact`**: reload hold and alt-fire (see the file header
  for the four rules that tell them apart). The caller measures a frame
  (`RAVEHandSample.indexExtensionRatio`, `thumbExtensionRatio`, `RAVEThumbContact.measure`)
  and passes `nil` while the gestures may not run. Thresholds are LambdaVision's, unchanged by the
  move and extensively tested on a Vision Pro there.
- **`RAVEArmSwingLocomotion`**: the opt-in policy around `RAVEArmSwinger`. **Off by default**.
  It does not arbitrate hands: `wantsHand(_:)` feeds a `RAVEHandOwnership` claim.
- **`RAVERadialMenu`** (`RAVERadialEntry<Action>`, `RAVERadial` geometry, `RAVERadialHandMenu`,
  `RAVERadialStickMenu`, `RAVERadialView`): LambdaVision's weapon wheel with the weapons taken
  out. Generic over the app's `Action`; it knows sectors, arming, confirm holds and nested
  members, not what a pick does. The hand driver opens on all four fingertips pinched to the
  thumb (a fist gate keeps a clenched hand out), the stick driver on a held button; both hand
  a drawer one `RAVERadialView`. **Aim tests at sector centres**: 3 o'clock is the boundary
  between sectors 0 and 1 of four, so a test there is a float-rounding coin flip. The drawer
  stays the app's (LambdaVision's is `WeaponWheelPanel` over RAVEHolo).
- **`RAVEFingerGunTrigger`**: curl the index to pull, extend to release, hold inside the band.
  Releases at once on a lost hand or when anything else owns it, so fire cannot stick. Returns
  a `RAVEEdge` so an engine bridge sends a command only on a change. Share the one threshold
  pair with `RAVEThumbGestures.Tuning` (`indexCurled`/`indexExtended`).

**Provenance.** Written in LambdaVision (GPL-3.0, with Xash3D and hlsdk vendored beside it) by
the owner with Claude, then re-expressed here under MIT with the engine specifics removed.
Before the move, every Lambda app file was compared against the vendored GPL trees (token
shingles, verbatim lines, comments, strings, identifiers): no verbatim lines, comment
sentences or strings, and the only shared identifiers were engine API names the moved code
no longer mentions. The same check run on these files finds none either. Lambda was not
written in a clean room, so this is evidence, not a guarantee. Not moved because they are
Half-Life shaped: `KeyboardInput`'s engine key numbers, `GamepadInput`'s `+command` binds,
`HandMovement`'s train and jump glue, `JumpSequencer`, `WeaponWheel`, `FreeAim` (one consumer,
no Xash in it; move it when a second app aims a held gun). **LambdaVision now consumes all of
the above** (2026-11-02): its `MouseSmoothing.swift` and `ThumbGestures.swift` are gone, its
`InputMode`, `WeaponWheel` gesture and gamepad wheel, finger-gun trigger and arm-swing policy
are these types under typealiases, and `KeyboardInput` sits on `RAVEKeyboardSource`. The
numbers did not change. `WeaponWheel` was first left
behind as Half-Life shaped; only its contents are (slots, weapon names, the commands), and its
menu half moved as `RAVERadialMenu` the same day. What stays in Lambda: the slot/weapon entries
it feeds in, `command(for:)` and `perform`, and `WeaponWheelPanel`.

### Mouse catcher (immersive spaces)

visionOS sends `GCMouse`/`GCKeyboard` to the app only while the pointer is over one of its
windows, never over a full immersive space, and no API changes that (visionOS 26/27). A window
that draws nothing still counts, so the workaround is an invisible "catcher" window kept in front
of the user. Confirmed on device in LambdaVision 2026-10-07 (GCMouse flowed, the mouse drove the
game). **It must draw something:** `Color.clear` with a `contentShape` did not catch (the
pointer hit-tests drawn pixels, not SwiftUI shapes); a visible tint did. UIKit documents the same
rule for its hit-testing (alpha below 0.01 is ignored), so start at a white fill of 0.01 and step up
if GCMouse stays silent; the lowest alpha that works on device is still to be measured.

RAVEInput holds the framework-free half: `RAVEMouseCatcherRule` (up or not, with a loggable
reason), `RAVEEventRate` (events in the last second for a `/state` counter) and
`RAVEMouseCatcherWatch` (notices a catcher that isn't catching). **The window stays in the app**:
it is SwiftUI scene code, and each app's gaze-pinch handling differs. The wiring, as
LambdaVision does it (`InputCatcher.swift`):

- **Scene:** `Window(id:)` with `.windowStyle(.plain)` (no glass), `.windowResizability(.contentSize)`
  and a big frame (4000×2600 pt asked; the system clamps), `.defaultLaunchBehavior(.suppressed)`,
  `.restorationBehavior(.disabled)`, `.persistentSystemOverlays(.hidden)` on the scene and the view.
  Content: a faint fill (`Color.white.opacity(0.01)`, never clear), `.hoverEffectDisabled()`,
  `.handlesGameControllerEvents(matching: .gamepad)` (every window needs it, or a gazed window
  freezes polled pad values).
- **Lifecycle:** a main-actor loop (~4 Hz) evaluates the rule and calls `openWindow(id:)` /
  `dismissWindow(id:)`, captured from the window that stays up under the space (the main
  window). Neither that `dismissWindow(id:)` nor the catcher's own `dismissWindow()` closed it
  once the immersive space had closed (device, 2026-10-07). Capture the catcher's `UIWindowScene`
  from inside it, read "open" from UIKit (still in `connectedScenes`, not background), and fall
  back to `UIApplication.shared.requestSceneSessionDestruction(scene.session, …)`.
- **Pinches:** a gaze-pinch on the catcher reaches it, not the immersive layer. Forward its
  `SpatialEventGesture(coordinateSpace: .immersiveSpace)` events to the same handler as the
  layer's `onSpatialEvent`. The selection ray is in SwiftUI's space (points, +Y down), so negate Y
  for a world (ARKit, +Y up) direction. Drop `.pointer` events while `RAVEMouseSource.isConnected`:
  GCMouse already has those clicks. ARKit hand tracking is unaffected.
- **Placement:** visionOS ignores `defaultWindowPlacement` except relative to another app window,
  has no head-following window, and `windowManagerRole` is `.automatic` only. Re-centre by
  dismissing and reopening (a new window opens in front of the user) when `onContinuousHover`
  reports `.ended` (pointer hover reaches apps; eye gaze does not), rate-limited.
- **Diagnostics:** count every `RAVEMouseEvent` into a `RAVEEventRate`; feed the watch hover
  moves, mouse events and pointer events that reach the layer.

Longwave has the same bug and has not adopted this yet: its immersive space needs the same window,
with `policy` from its own input settings and `blockedBy` for any gaze-driven UI.

**`RAVEFingerBindingTable`'s `Codable` is hand-written and wire-compatible.** It emits the
same named fields (`rightIndex`, `rightMiddle`, …) two apps already have in `UserDefaults`,
and decodes `leftIndex` with `decodeIfPresent` because one app never stored it — its
reserved joystick slot was not a value it kept. Synthesised `Codable` would reset every
user's bindings.

## Logging

RAVEInput is the one target that logs, and it has the package's only external dependency:
`../DebugTrace`, through its small `DebugLog` product (the message type and `DebugLogger`;
no dependencies, so none of the trace builder, registry or server comes with it). Its sources take a `log:` closure of `DebugLogMessage`, not `String`, so each
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
| `Nexus` (visionOS) | `RAVESharedSpace` (+ SDK's `RAVELauncher`) |

`RAVEGuardian` is linked by Longwave (visionOS target, PCVR space) and spatial-ai-character (visionOS target).

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
