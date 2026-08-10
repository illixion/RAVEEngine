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

/// Both hands' readings for one frame.
public struct RAVEHandTickOutput: Sendable {
    public var left: RAVEPinchOutput
    public var right: RAVEPinchOutput
    /// The locomotion joystick, driven by whichever pinch the sensor reserves
    /// for it (left + index by default).
    public var joystick: RAVEJoystickOutput

    public init(
        left: RAVEPinchOutput = RAVEPinchOutput(),
        right: RAVEPinchOutput = RAVEPinchOutput(),
        joystick: RAVEJoystickOutput = RAVEJoystickOutput()
    ) {
        self.left = left
        self.right = right
        self.joystick = joystick
    }

    public subscript(chirality: RAVEHandChirality) -> RAVEPinchOutput {
        switch chirality {
        case .left:  return left
        case .right: return right
        }
    }

    /// Rising edges from both hands, in left-then-right order (the order the
    /// ported originals emitted them in).
    public var pinchEvents: [RAVEHandPinchEvent] {
        var events: [RAVEHandPinchEvent] = []
        if let event = left.pinchEvent(for: .left) { events.append(event) }
        if let event = right.pinchEvent(for: .right) { events.append(event) }
        return events
    }

    /// The additive-input view of this frame.
    public var inputFrame: RAVEHandInputFrame {
        RAVEHandInputFrame(pinchEvents: pinchEvents, joystick: joystick.vector)
    }
}

/// ARKit-backed hand sensing.
@MainActor
public final class RAVEARKitHandSensor: RAVEHandInputProvider {

    // MARK: Configuration

    /// Which pinch drives the locomotion joystick. That pinch is still reported
    /// as held like any other; it is up to the app's binding table to leave it
    /// unassigned.
    public var joystickChirality: RAVEHandChirality = .left
    public var joystickFinger: RAVEHandFinger = .index

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

    /// Stop consuming anchors. Only meaningful after `start()`; harmless
    /// otherwise. Held pinches release on the next `tick` once samples stop
    /// arriving and the anchors go untracked.
    public func stop() {
        anchorTask?.cancel()
        anchorTask = nil
    }

    /// Push in an anchor observed elsewhere. An untracked anchor clears that
    /// hand, which releases any pinch it was holding.
    public func ingest(_ anchor: HandAnchor) {
        let sample = anchor.isTracked ? RAVEHandSample(anchor) : nil
        switch anchor.chirality {
        case .left:  leftSample = sample
        case .right: rightSample = sample
        @unknown default: break
        }
    }

    // MARK: Per-frame

    /// Advance both hands and the joystick.
    ///
    /// - Parameter now: monotonic seconds. Injectable so the state machine can
    ///   be driven deterministically in a test.
    @discardableResult
    public func tick(
        now: TimeInterval = CACurrentMediaTime(),
        worldForward: SIMD3<Float>,
        worldRight: SIMD3<Float>
    ) -> RAVEHandTickOutput {
        let left = leftDetector.update(sample: input(for: .left), now: now)
        let right = rightDetector.update(sample: input(for: .right), now: now)

        let driving = (joystickChirality == .left ? left : right)
        let engaged = driving.held == joystickFinger
        let wrist = (joystickChirality == .left ? leftSample : rightSample)?.wrist
        let stick = joystick.update(
            wristWorld: wrist,
            engaged: engaged,
            worldForward: worldForward,
            worldRight: worldRight
        )

        return RAVEHandTickOutput(left: left, right: right, joystick: stick)
    }

    /// `RAVEHandInputProvider` witness — the additive-input view, on the media clock.
    public func tick(worldForward: SIMD3<Float>, worldRight: SIMD3<Float>) -> RAVEHandInputFrame {
        tick(now: CACurrentMediaTime(), worldForward: worldForward, worldRight: worldRight)
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

    private func input(for chirality: RAVEHandChirality) -> RAVEHandSample? {
        guard !suppressedHands.contains(chirality) else { return nil }
        return sample(for: chirality)
    }
}

#endif
