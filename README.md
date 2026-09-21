# RAVE Engine

**R**obot-**A**ssisted **V**ision **E**nhancements — the XR/game-shaped half of
the RAVE packages. Input, frame diagnostics, RealityKit and CompositorServices
scaffolding, and PCVR components.

Its sibling, **RAVE SDK**, covers the app-shaped half — general UI, camera,
2D/3D photo & video viewing and conversion, app networking. The two are
siblings with **no dependency between them**, which is what lets Engine add
macOS support on its own schedule. An app that is both simply links both.

The RAVE family is fixed at exactly these two packages. Shared code that
needs a home becomes a **target inside Engine or SDK** (like `RAVERig` did),
never a new third sibling package — see `RAVEPCVR` below for what that means
in practice. And "Robot-Assisted Vision Enhancements" describes the acronym,
not a scope filter: `RAVERig` (character rigging) belongs here because it's
XR/game-shaped, same as input and diagnostics, not because it's about vision.

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
| `RAVERig` | shipping | Skeleton geometry, humanoid inference, FABRIK, pose solving, leg stepping, tail dynamics |
| `RAVEPCVR` | planned | Only the reusable controller-bridge *protocol*, once a second app needs it — not Longwave's PCVR feature as a whole (paywall, session limiting, CloudXR host stay Longwave-only and mostly closed-source; see this repo's CLAUDE.md) |

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

### Joystick coordinate contract and visualization

`RAVEHandJoystick` takes a control point and a `RAVEPlanarBasis` expressed in
the same tracking coordinate space. The basis validates and orthogonalizes the
horizontal axes before projection, preventing a consumer from accidentally
mixing ARKit hand positions with a separately rotated game-world basis.

The shared defaults use a 3 cm radial deadzone and remap the remaining travel
to the full output range. `RAVEJoystickOutput.visualization` publishes the
center, clamped handle, axes and ring radii as plain SIMD values. Each app can
draw those values with RealityKit, Metal, SwiftUI, or a remote HUD without
putting renderer dependencies in `RAVEInput`.

```swift
let trackingBasis = RAVEPlanarBasis(
    forward: deviceForwardInARKit,
    right: deviceRightInARKit
)
let frame = handInput.tick(trackingBasis: trackingBasis)

moveInput += frame.joystick
if let stick = frame.joystickVisualization {
    joystickOverlay.update(
        center: stick.center,
        handle: stick.handle,
        forward: stick.basis.forward,
        right: stick.basis.right,
        deadzone: stick.deadzoneMeters,
        radius: stick.fullScaleMeters,
        value: stick.value
    )
}
```

## RAVERig

Skeleton geometry and inverse kinematics. Converged the same way `RAVEInput`
was — it grew inside `spatial-ai-character` as part of a character-import
pipeline, and became a package when `halflife-visionos` needed the same solver
to pose a Half-Life player model from a tracked head and hands.

| | |
|---|---|
| `RigSkeleton` | A skeleton as a flat, parent-indexed joint list in Y-up metres. The input to every analysis here. |
| `HumanoidInference` | Works out which joints are the hips, spine, head, arms and legs, from topology and skin weights rather than from names. |
| `LegArchitecture` | Classifies a leg as plantigrade or digitigrade and finds its true ground contact — measured from where the joints sit, not from what they are called. |
| `FABRIK` | Forward And Backward Reaching IK over a chain of points, with a pole constraint and reach/fold limits. Any number of segments. |
| `PoseSolver` | Turns a FABRIK solution back into joint rotations, which is what a skeleton actually stores. |
| `LegStepper` | Plans footfalls — where each foot plants, when it lifts, the arc it swings through. |
| `TailArchitecture` | Finds a tail from geometry: a weighted chain of joints leaving the pelvis backward or down, that is not a limb. |
| `ChainDynamics` | Verlet particle chain for secondary motion — a tail, an ear, a strap — with gravity, a spring toward the animated shape, fixed lengths, a bend limit and a floor. |
| `TailSway` | The deliberate half of a tail: a wag about the base and a carriage height, eased between styles. |
| `BindPoseCheck` | Validates a rig before anything downstream trusts it. |

### The two halves of a solve are deliberately separate

`FABRIK` knows nothing about skeletons and returns bare points: *where should
each joint sit*. A skinned character needs *how far should each joint turn*,
because that is what a bone palette or a `SkeletalPose` stores, and the
conversion is where the subtleties are — accumulated parent transforms, the
change of basis into a parent's space, and rotations that are undefined exactly
when a limb straightens out. `PoseSolver` is that conversion and nothing else.
Callers compose the two.

### It solves in whatever space you hand it

Nothing here assumes an up axis or a unit. `spatial-ai-character` solves in
RealityKit's Y-up metres; `halflife-visionos` solves in GoldSrc's Z-up inches
so its bone palette reaches the vertex shader without an axis conversion
sitting between the tracker and the bones.

### Both stops are guarded, and reported

A chain is slow to converge wherever it is close to a straight line, which
happens at *both* ends: pulled taut, and folded back on itself. `reachLimit`
and `foldLimit` keep the aim off each, and `extended` / `outOfReach` /
`folded` report which stop was hit, so a limb that is always straining stays
visible instead of being quietly absorbed. Measured on a Half-Life arm (11.59 +
10.13 units): 32 iterations hold a fortieth of a millimetre everywhere the
limits leave in play.

A chain that already lies along the line to its target is a third case and a
real trap — it has no bend plane, so it can only collapse or extend and flips
between the two once per iteration. A standing leg reaching for the ground
beneath it is exactly that shape. The solver nudges an interior joint off the
line first; the pole, when given, decides which way.

The pole fixes the bend *plane*; by default it does not choose the side of the
bend, because an animated leg already bends the right way and must not be
second-guessed. A chain seeded from a single frozen frame is the other case —
a player model's arm, whose elbow sits wherever that frame left it — and for
that `bendTowardPole: true` mirrors the seed across the root–target line so the
bend ends up on the pole's side. Measured on a Half-Life arm, the default put a
hand raised to the face with its elbow up behind the shoulder.

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
