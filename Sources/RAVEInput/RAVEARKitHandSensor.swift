/*
 RAVE Engine — the visionOS hand sensor.

 The only file in the input path that names an ARKit symbol. Everything it
 produces is `RAVEHandSample` / `RAVEPinchOutput` / `RAVEPalmPose`, so no
 consumer transitively depends on visionOS just to say "right middle finger".

 It supports both ownership models the apps already use:

 - **Owning a session** (`start()`): the app has no other reason to run ARKit,
   so the sensor opens `HandTrackingProvider` itself and consumes its updates.
 - **Being fed** (`ingest(_:)`): the app already runs a hand provider for some
   other purpose — pose streaming, joint forwarding — and a second session would
   be waste. Push anchors in and never call `start()`.

 A third consumer shape needs neither: a render-thread loop that already holds a
 `HandAnchor` can call the nonisolated `RAVEHandSample.init(_:)` and drive
 `RAVEPinchDetector` / `RAVEHandJoystick` itself, with no actor involved.
 */

#if os(visionOS)

import ARKit
import Foundation
import QuartzCore
import simd

public extension RAVEHandSample {
    /// Read a sample out of an ARKit anchor. `nil` when the anchor carries no
    /// skeleton (untracked).
    ///
    /// Nonisolated so a render thread can call it without hopping.
    nonisolated init?(_ anchor: HandAnchor) {
        guard let skeleton = anchor.handSkeleton else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        func joint(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(name).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        self.init(
            wrist: joint(.wrist),
            thumbTip: joint(.thumbTip),
            thumbKnuckle: joint(.thumbKnuckle),
            index: RAVEFingerJoints(
                tip: joint(.indexFingerTip),
                metacarpal: joint(.indexFingerMetacarpal),
                knuckle: joint(.indexFingerKnuckle)
            ),
            middle: RAVEFingerJoints(
                tip: joint(.middleFingerTip),
                metacarpal: joint(.middleFingerMetacarpal),
                knuckle: joint(.middleFingerKnuckle)
            ),
            ring: RAVEFingerJoints(
                tip: joint(.ringFingerTip),
                metacarpal: joint(.ringFingerMetacarpal),
                knuckle: joint(.ringFingerKnuckle)
            ),
            little: RAVEFingerJoints(
                tip: joint(.littleFingerTip),
                metacarpal: joint(.littleFingerMetacarpal),
                knuckle: joint(.littleFingerKnuckle)
            )
        )
    }
}

/// ARKit-backed hand sensing.
@MainActor
public final class RAVEARKitHandSensor: RAVEHandInputProvider {

    // MARK: Configuration

    /// Which pinch drives the locomotion joystick. That pinch is still reported
    /// as *held* in `left`/`right` like any other — Longwave maps a held left
    /// pinch of any finger to its wire-level `leftPinch` flag, joystick
    /// included, so hiding it there would change what its host sees. Its
    /// rising edge is left out of `pinchEvents`.
    public var joystickChirality: RAVEHandChirality = .left
    public var joystickFinger: RAVEHandFinger = .index
    /// When false the sensor reserves nothing: every pinch is bindable and the
    /// joystick output stays zero. An app without hand locomotion wants this.
    public var joystickEnabled: Bool = true {
        didSet { if !joystickEnabled { joystick.release(); joystickDetector?.reset() } }
    }
    /// Optional dedicated tuning for the joystick pinch (e.g. `.joystick`, a
    /// heavier debounce than a button wants). `nil`, the default, drives the
    /// joystick from the hand's ordinary detector, as before. When set, a
    /// second detector restricted to `joystickFinger` engages the stick; the
    /// ordinary detector still reports the finger as held on its own timing.
    public var joystickPinchTuning: RAVEPinchTuning? {
        didSet { joystickDetector = joystickPinchTuning.map(Self.makeJoystickDetector) }
    }

    /// Hands whose pinches must not reach the app. Longwave sets this while its
    /// wrist panel is up: the same pinch that presses a button on the panel is
    /// also mapped to a controller button, so without it, checking your frame
    /// times fires a trigger in-game. Per hand, so the other hand keeps playing.
    public var suppressedHands: Set<RAVEHandChirality> = []

    public var pinchTuning: RAVEPinchTuning {
        didSet {
            leftDetector.tuning = pinchTuning
            rightDetector.tuning = pinchTuning
        }
    }
    public var joystick: RAVEHandJoystick

    // MARK: State

    private var leftDetector: RAVEPinchDetector
    private var rightDetector: RAVEPinchDetector
    private var joystickDetector: RAVEPinchDetector?
    private var leftSample: RAVEHandSample?
    private var rightSample: RAVEHandSample?

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private var anchorTask: Task<Void, Never>?
    private var logHandler: (@Sendable (String) -> Void)?

    public init(
        pinchTuning: RAVEPinchTuning = .standard,
        joystick: RAVEHandJoystick = RAVEHandJoystick(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.pinchTuning = pinchTuning
        self.joystick = joystick
        self.leftDetector = RAVEPinchDetector(tuning: pinchTuning)
        self.rightDetector = RAVEPinchDetector(tuning: pinchTuning)
        self.logHandler = log
    }

    /// Full configuration, including the joystick reservation.
    public convenience init(
        pinchTuning: RAVEPinchTuning = .standard,
        joystick: RAVEHandJoystick = RAVEHandJoystick(),
        joystickEnabled: Bool,
        joystickChirality: RAVEHandChirality = .left,
        joystickFinger: RAVEHandFinger = .index,
        joystickPinchTuning: RAVEPinchTuning? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.init(pinchTuning: pinchTuning, joystick: joystick, log: log)
        self.joystickEnabled = joystickEnabled
        self.joystickChirality = joystickChirality
        self.joystickFinger = joystickFinger
        self.joystickPinchTuning = joystickPinchTuning
        self.joystickDetector = joystickPinchTuning.map(Self.makeJoystickDetector)
    }

    private nonisolated static func makeJoystickDetector(_ tuning: RAVEPinchTuning) -> RAVEPinchDetector {
        RAVEPinchDetector(tuning: tuning)
    }

    // MARK: Lifecycle

    /// Open an ARKit session and consume hand anchors from it.
    ///
    /// Skip this entirely if the app already runs its own `HandTrackingProvider`
    /// and pushes anchors through `ingest(_:)`.
    public func start() async {
        // The simulator has no hand tracking: `session.run` raises an ObjC
        // NSException there — not a catchable Swift error — and kills the app.
        guard HandTrackingProvider.isSupported else {
            logHandler?("hand tracking unsupported on this platform — skipping")
            return
        }
        do {
            try await session.run([provider])
        } catch {
            logHandler?("failed to start hand session — \(error)")
            return
        }
        let updates = provider.anchorUpdates
        anchorTask = Task { @MainActor [weak self] in
            for await update in updates {
                guard let self else { return }
                self.ingest(update.anchor)
            }
        }
    }

    /// Stop consuming anchors and immediately clear every held input. Only
    /// meaningful after `start()`; harmless otherwise.
    public func stop() {
        anchorTask?.cancel()
        anchorTask = nil
        leftSample = nil
        rightSample = nil
        leftDetector.reset()
        rightDetector.reset()
        joystickDetector?.reset()
        joystick.release()
    }

    /// Push in an anchor observed elsewhere. An untracked anchor clears that
    /// hand; a pinch it was holding survives the tuning's tracking-loss grace
    /// and then releases.
    public func ingest(_ anchor: HandAnchor) {
        let sample = anchor.isTracked ? RAVEHandSample(anchor) : nil
        switch anchor.chirality {
        case .left:  leftSample = sample
        case .right: rightSample = sample
        @unknown default: break
        }
    }

    // MARK: Per-frame

    /// Advance both hands and the joystick, reporting everything sensed.
    ///
    /// Named apart from the `tick` protocol witness deliberately: a defaulted
    /// `now:` would otherwise make the two indistinguishable at the call site,
    /// and silently picking the lossy one is exactly the kind of mistake this
    /// package exists to stop.
    ///
    /// - Parameter now: monotonic seconds. Injectable so the state machine can
    ///   be driven deterministically in a test.
    @discardableResult
    public func poll(
        now: TimeInterval = CACurrentMediaTime(),
        worldForward: SIMD3<Float>,
        worldRight: SIMD3<Float>
    ) -> RAVEHandTickOutput {
        poll(
            now: now,
            trackingBasis: RAVEPlanarBasis(forward: worldForward, right: worldRight)
        )
    }

    /// Advance both hands with axes explicitly identified as sharing the hand
    /// samples' ARKit tracking space.
    @discardableResult
    public func poll(
        now: TimeInterval = CACurrentMediaTime(),
        trackingBasis: RAVEPlanarBasis
    ) -> RAVEHandTickOutput {
        let left = advance(&leftDetector, .left, now: now)
        let right = advance(&rightDetector, .right, now: now)

        guard joystickEnabled else {
            joystick.release()
            return RAVEHandTickOutput(left: left, right: right)
        }

        var dedicated: RAVEPinchOutput?
        if var detector = joystickDetector {
            // The dedicated detector only ever looks at the joystick finger.
            if detector.tuning.candidateFingers != [joystickFinger] {
                detector.tuning.candidateFingers = [joystickFinger]
            }
            dedicated = advance(&detector, joystickChirality, now: now)
            joystickDetector = detector
        }
        let driving = dedicated ?? (joystickChirality == .left ? left : right)
        let engaged = driving.held == joystickFinger
        let wrist = (joystickChirality == .left ? leftSample : rightSample)?.wrist
        // Pass the frame time: without it `smoothingTime` on a joystick set
        // through this sensor silently does nothing.
        let stick = joystick.update(
            controlPoint: wrist,
            engaged: engaged,
            basis: trackingBasis,
            now: now
        )

        return RAVEHandTickOutput(
            left: left, right: right, joystick: stick,
            joystickSlot: RAVEHandPinchEvent(chirality: joystickChirality, finger: joystickFinger),
            joystickPinch: dedicated
        )
    }

    /// One detector, one frame. A suppressed hand releases at once (suppression
    /// is deliberate and must not linger); an untracked one gets the grace.
    private func advance(_ detector: inout RAVEPinchDetector, _ hand: RAVEHandChirality,
                         now: TimeInterval) -> RAVEPinchOutput {
        if suppressedHands.contains(hand) { return detector.forceRelease() }
        return detector.update(sample: sample(for: hand), now: now)
    }

    /// `RAVEHandInputProvider` witness — the additive-input view, on the media clock.
    public func tick(worldForward: SIMD3<Float>, worldRight: SIMD3<Float>) -> RAVEHandInputFrame {
        poll(
            now: CACurrentMediaTime(),
            trackingBasis: RAVEPlanarBasis(forward: worldForward, right: worldRight)
        )
            .inputFrame
    }

    public func palmPose(_ chirality: RAVEHandChirality) -> RAVEPalmPose? {
        sample(for: chirality).flatMap(RAVEPalmGeometry.palmPose(from:))
    }

    /// World position of the thumb tip — where a pinch physically happens, and
    /// so where a charge indicator belongs: the user is already looking there.
    public func thumbTipWorld(_ chirality: RAVEHandChirality) -> SIMD3<Float>? {
        sample(for: chirality)?.thumbTip
    }

    /// The raw sample for a hand, `nil` when untracked. Suppression does not
    /// hide it — suppression is about input reaching the app, not about where
    /// the hand is.
    public func sample(for chirality: RAVEHandChirality) -> RAVEHandSample? {
        switch chirality {
        case .left:  return leftSample
        case .right: return rightSample
        }
    }

}

#endif
