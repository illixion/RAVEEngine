/*
 RAVE Engine — spatial game controllers (PSVR2 Sense, and whatever else reports
 `GCProductCategorySpatialController`) as tracked controllers.

 Lifted from Longwave's `SpatialAccessoryTracker`. Each controller supplies the
 pose, angular velocity, buttons and haptics for ITS hand: a spatial controller
 knows which hand it is and where it is, so none of the single-gamepad IMU
 attribution a plain pad needs applies.

 "Best-effort" is structural: `AccessoryTrackingProvider.isSupported` is false
 in the simulator and on anything without the tracking stack, and no spatial
 accessory can connect there anyway, so everything here sits dormant until a
 real controller arrives on a real device. This has NOT yet run against real
 hardware; the integration is designed to fail toward the app's existing hand
 and gamepad paths (a side with no controller polls as nil).

 Coordinate space: `AccessoryAnchor.originFromAnchorTransform` is in the same
 ARKit world origin as `HandTrackingProvider` anchors, so no calibration is
 involved. The anchor origin is the accessory's own; a consumer that mounts
 things on an OpenXR-style grip pose carries its own offset (resolving
 `coordinateSpace(for: .grip)` is worth revisiting once real hardware shows
 the residual).

 Isolation: lifecycle (discovery, authorization, the anchor loop, haptic
 engines) is `@MainActor`, the way the original ran. The poll path is not:
 `poll(now:)` and `sendHaptic(_:)` are nonisolated and read a lock-guarded
 store, so a render thread can drive this like any other source.
 */

#if os(visionOS)

import ARKit
import CoreHaptics
import Foundation
import GameController
import QuartzCore
import simd

@MainActor
public final class RAVESpatialAccessorySource: RAVETrackedControllerSource {

    /// A pose older than this is dropped, so a parked controller hands the pose
    /// back to the wrist within a quarter second.
    public nonisolated static let staleAfter: Double = 0.25

    /// True while at least one spatial controller is connected and tracking runs.
    public var isActive: Bool { !store.isEmpty && providerTask != nil }

    private nonisolated let store = Store()
    private let log: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Accessories by the controller they wrap, keyed by ObjectIdentifier —
    /// GCController is not Hashable.
    private var accessories: [ObjectIdentifier: (controller: GCController, accessory: Accessory)] = [:]
    private var session: ARKitSession?
    private var provider: AccessoryTrackingProvider?
    private var providerTask: Task<Void, Never>?
    private var running = false

    private var hapticEngines: [RAVEHandChirality: CHHapticEngine] = [:]
    private var hapticOwners: [RAVEHandChirality: ObjectIdentifier] = [:]
    private var hapticPlayers: [RAVEHandChirality: CHHapticPatternPlayer] = [:]
    private var lastHapticAt: [RAVEHandChirality: Double] = [:]

    public init(log: (@Sendable (String) -> Void)? = nil) {
        self.log = log
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        guard AccessoryTrackingProvider.isSupported else {
            log?("spatial controllers: accessory tracking unsupported here — inactive")
            return
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                let box = UncheckedBox(controller)
                MainActor.assumeIsolated { self?.adoptIfSpatial(box.value) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                let box = UncheckedBox(controller)
                MainActor.assumeIsolated { self?.forget(box.value) }
            },
        ]
        for existing in GCController.controllers() { adoptIfSpatial(existing) }
    }

    public func stop() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver(_:))
        observers = []
        stopProvider()
        session?.stop()
        session = nil
        accessories.removeAll()
        store.clear()
        for player in hapticPlayers.values { try? player.stop(atTime: CHHapticTimeImmediate) }
        hapticPlayers.removeAll()
        hapticEngines.values.forEach { $0.stop() }
        hapticEngines.removeAll()
        hapticOwners.removeAll()
    }

    // MARK: RAVETrackedControllerSource

    public nonisolated func poll(now: Double) -> RAVETrackedControllerFrame {
        var frame = RAVETrackedControllerFrame()
        for chirality in RAVEHandChirality.allCases {
            guard let (controller, pose) = store.read(chirality) else { continue }
            var state = Self.readInputs(controller.value, chirality: chirality)
            if let pose {
                state.position = pose.position
                state.orientation = pose.orientation
                state.angularVelocity = pose.angularVelocity
                state.timestamp = pose.updatedAt
                state.isTracked = pose.isTracked && now - pose.updatedAt < Self.staleAfter
            }
            frame[chirality] = state
        }
        return frame
    }

    public nonisolated func sendHaptic(_ haptic: RAVEControllerHaptic) {
        Task { @MainActor [weak self] in self?.play(haptic) }
    }

    // MARK: Discovery

    private func adoptIfSpatial(_ controller: GCController) {
        guard controller.productCategory == GCProductCategorySpatialController else { return }
        let id = ObjectIdentifier(controller)
        guard accessories[id] == nil else { return }
        log?("spatial controllers: connected \(controller.vendorName ?? "unknown")")
        let box = UncheckedBox(controller)
        Task { @MainActor [weak self] in
            do {
                let accessory = try await Accessory(device: box.value)
                guard let self, self.running else { return }
                self.accessories[id] = (box.value, accessory)
                switch accessory.inherentChirality {
                case .left: self.store.setController(box, for: .left)
                case .right: self.store.setController(box, for: .right)
                default:
                    // A one-handed accessory with no fixed side (stylus-like);
                    // heldChirality on its anchors places it.
                    break
                }
                await self.restartProvider()
            } catch {
                self?.log?("spatial controllers: accessory creation failed — \(error.localizedDescription)")
            }
        }
    }

    private func forget(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard accessories.removeValue(forKey: id) != nil else { return }
        store.remove(controller: id)
        log?("spatial controllers: disconnected")
        Task { @MainActor [weak self] in await self?.restartProvider() }
    }

    // MARK: Provider lifecycle

    /// (Re)run tracking over the current accessory set. The provider's set is
    /// fixed at init, so any membership change means a fresh provider — and a
    /// data provider instance cannot be re-run, so a fresh session too.
    private func restartProvider() async {
        stopProvider()
        session?.stop()
        session = nil
        guard running, !accessories.isEmpty else { return }

        let session = ARKitSession()
        self.session = session
        let auth = await session.requestAuthorization(for: [.accessoryTracking])
        guard auth[.accessoryTracking] == .allowed else {
            log?("spatial controllers: accessory-tracking authorization denied")
            return
        }
        let provider = AccessoryTrackingProvider(accessories: accessories.values.map(\.accessory))
        self.provider = provider
        do {
            try await session.run([provider])
        } catch {
            log?("spatial controllers: tracking run failed — \(error.localizedDescription)")
            self.provider = nil
            return
        }
        let store = self.store
        providerTask = Task { @MainActor [weak self] in
            for await update in provider.anchorUpdates {
                if Task.isCancelled { break }
                guard self != nil else { break }
                Self.ingest(update.anchor, into: store)
            }
        }
        log?("spatial controllers: tracking \(accessories.count) accessory(s)")
    }

    private func stopProvider() {
        providerTask?.cancel()
        providerTask = nil
        provider = nil
    }

    // MARK: Anchors

    private static func ingest(_ anchor: AccessoryAnchor, into store: Store) {
        // A held side beats the built-in one: heldChirality is ARKit's live
        // judgement, inherentChirality the device's nature. For a Sense pair
        // they agree; for an unspecified accessory only the former places it.
        let chirality: RAVEHandChirality
        switch anchor.heldChirality ?? anchor.accessory.inherentChirality {
        case .left: chirality = .left
        case .right: chirality = .right
        default: return
        }
        let m = anchor.originFromAnchorTransform
        let rotation = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        // Orientation-only tracking still yields a rotation, but the position
        // would be stale; only full 6DoF counts as tracked, and the wrist
        // carries the hand through occlusion.
        let tracked: Bool
        switch anchor.trackingState {
        case .positionOrientationTracked, .positionOrientationTrackedLowAccuracy: tracked = true
        default: tracked = false
        }
        store.setPose(Store.Pose(
            position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
            orientation: simd_quatf(rotation),
            angularVelocity: anchor.angularVelocity,
            isTracked: tracked,
            updatedAt: CACurrentMediaTime()), for: chirality)
    }

    // MARK: Inputs

    /// One spatial controller's buttons and axes, read through the live-input
    /// element API (these are not extended gamepads). On the right Sense `.a`
    /// / `.b` are Cross / Circle, on the left Square / Triangle — the positions
    /// `primary` / `secondary` name.
    private nonisolated static func readInputs(_ controller: GCController,
                                               chirality: RAVEHandChirality) -> RAVETrackedControllerState {
        let input = controller.input
        var state = RAVETrackedControllerState(chirality: chirality)
        var buttons: RAVEControllerButtons = []
        var touchValid = false
        func pressed(_ name: GCButtonElementName) -> Bool {
            input.buttons[name]?.pressedInput.isPressed == true
        }
        func touched(_ name: GCButtonElementName) -> Bool {
            guard let touch = input.buttons[name]?.touchedInput else { return false }
            touchValid = true
            return touch.isTouched
        }
        if pressed(.a) { buttons.insert(.primary) }
        if pressed(.b) { buttons.insert(.secondary) }
        if pressed(.grip) { buttons.insert(.gripClick) }
        if pressed(.thumbstickButton) { buttons.insert(.stickClick) }
        if pressed(.menu) { buttons.insert(.menu) }
        if touched(.trigger) { buttons.insert(.triggerTouch) }
        let thumb = touched(.thumbstickButton) || touched(.a) || touched(.b)
        if thumb { buttons.insert(.thumbTouch) }
        state.buttons = buttons
        state.touchValid = touchValid
        state.trigger = input.buttons[.trigger]?.pressedInput.value ?? 0
        state.grip = input.buttons[.grip]?.pressedInput.value ?? 0
        if let stick = input.dpads[.thumbstick] {
            state.stick = SIMD2(stick.xyAxes.value.x, stick.xyAxes.value.y)
        }
        if let level = controller.battery?.batteryLevel, level >= 0 {
            state.batteryPercent = UInt8(min(100, max(0, (level * 100).rounded())))
        }
        return state
    }

    // MARK: Haptics

    private func play(_ haptic: RAVEControllerHaptic) {
        let side = haptic.chirality
        let amplitude = min(max(haptic.amplitude, 0), 1)
        if amplitude == 0 {
            if let player = hapticPlayers.removeValue(forKey: side) { try? player.stop(atTime: CHHapticTimeImmediate) }
            return
        }
        guard let target = store.controller(side)?.value, let deviceHaptics = target.haptics else { return }

        // Games spam short pulses at frame rate; per-side coalescing keeps us
        // from stacking a CoreHaptics player per request.
        let now = CACurrentMediaTime()
        if now - (lastHapticAt[side] ?? 0) < 0.010 { return }
        lastHapticAt[side] = now

        // Cached engines belong to one specific device; rebuild on swap.
        if hapticOwners[side] != ObjectIdentifier(target) {
            if let player = hapticPlayers.removeValue(forKey: side) { try? player.stop(atTime: CHHapticTimeImmediate) }
            hapticEngines[side]?.stop()
            hapticEngines[side] = nil
            hapticOwners[side] = ObjectIdentifier(target)
        }

        let engine: CHHapticEngine
        if let cached = hapticEngines[side] {
            engine = cached
        } else {
            guard let created = deviceHaptics.createEngine(withLocality: .default) else {
                log?("spatial controllers: no haptic engine")
                return
            }
            created.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.hapticPlayers[side] = nil
                    self?.hapticEngines[side] = nil
                }
            }
            created.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.hapticPlayers[side] = nil
                    self?.hapticEngines[side] = nil
                }
            }
            do { try created.start() } catch {
                log?("spatial controllers: haptic engine start failed — \(error.localizedDescription)")
                return
            }
            hapticEngines[side] = created
            engine = created
        }

        // Index-style haptics run ~1–320 Hz; map frequency onto sharpness.
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: amplitude)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness,
                                               value: min(max(haptic.frequency / 320, 0), 1))
        // Duration 0 is a click-style pulse → transient event.
        let event = haptic.duration > 0
            ? CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness],
                            relativeTime: 0, duration: Double(min(haptic.duration, 2)))
            : CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            if let player = hapticPlayers.removeValue(forKey: side) { try? player.stop(atTime: CHHapticTimeImmediate) }
            let player = try engine.makePlayer(with: pattern)
            hapticPlayers[side] = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            log?("spatial controllers: haptic play failed — \(error.localizedDescription)")
        }
    }
}

// MARK: - Lock-guarded store

/// GameController objects are not Sendable; reading their input snapshots from
/// a poll thread is what every RAVEInput gamepad consumer already does.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension RAVESpatialAccessorySource {
    final class Store: @unchecked Sendable {
        struct Pose: Sendable {
            var position: SIMD3<Float>
            var orientation: simd_quatf
            var angularVelocity: SIMD3<Float>
            var isTracked: Bool
            var updatedAt: Double
        }

        private let lock = NSLock()
        private var controllers: [RAVEHandChirality: UncheckedBox<GCController>] = [:]
        private var poses: [RAVEHandChirality: Pose] = [:]

        var isEmpty: Bool {
            lock.lock(); defer { lock.unlock() }
            return controllers.isEmpty
        }

        func setController(_ controller: UncheckedBox<GCController>, for chirality: RAVEHandChirality) {
            lock.lock(); defer { lock.unlock() }
            controllers[chirality] = controller
        }

        func controller(_ chirality: RAVEHandChirality) -> UncheckedBox<GCController>? {
            lock.lock(); defer { lock.unlock() }
            return controllers[chirality]
        }

        func remove(controller id: ObjectIdentifier) {
            lock.lock(); defer { lock.unlock() }
            for (chirality, box) in controllers where ObjectIdentifier(box.value) == id {
                controllers[chirality] = nil
                poses[chirality] = nil
            }
        }

        func setPose(_ pose: Pose, for chirality: RAVEHandChirality) {
            lock.lock(); defer { lock.unlock() }
            poses[chirality] = pose
        }

        /// A side reads only when a controller of that chirality is connected.
        func read(_ chirality: RAVEHandChirality) -> (UncheckedBox<GCController>, Pose?)? {
            lock.lock(); defer { lock.unlock() }
            guard let controller = controllers[chirality] else { return nil }
            return (controller, poses[chirality])
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            controllers.removeAll()
            poses.removeAll()
        }
    }
}

#endif
