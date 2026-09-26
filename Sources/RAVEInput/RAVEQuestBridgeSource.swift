/*
 RAVE Engine — Quest Touch controllers over the LAN, as tracked controllers.

 The Controller Bridge app on a Meta Quest streams both Touch controllers
 (grip pose in the Quest's stage space, trigger, analog grip, stick, buttons,
 touch, battery) as UDP datagrams to port 9520. Park the Quest on a desk facing
 you, point it at the headset running this app, and its controllers become
 this app's controllers — the Quest's optical tracking of a plastic handle is
 steadier than hand tracking of a hand wrapped around one.

 What this class owns, so an app does not have to:

   - the socket (Network.framework, opt-in: nothing listens until `start()`),
   - the protocol: probe replies (the Quest's "Test connection" button works
     against this app), the periodic status heartbeat (the Quest app's
     "connected" pulse fires on the first one — a host that never sends it
     leaves the user without confirmation), haptics back to sender:9521,
   - the alignment: `RAVEQuestAlignment` against ARKit hand positions the app
     feeds in with `observeHands`, persisted in UserDefaults,
   - a status snapshot for HUDs (`status`): idle / seen / collecting / calibrated
     / lost, plus battery.

 Hands in: the app already runs hand tracking (usually `RAVEARKitHandSensor`),
 so this never opens an ARKit session of its own — it takes the samples. That
 is also what keeps it building on macOS, and the solver testable.

 Isolation: none. A lock-guarded class, `@unchecked Sendable`, like
 `RAVEMetricCollector`. `poll`, `observeHands`, `sendHaptic` and `status` are
 safe from any thread, including a render thread; network callbacks run on a
 private serial queue.

 Info.plist, in the consuming app:
   - `NSLocalNetworkUsageDescription` — receiving from a LAN peer triggers the
     local-network prompt; without the key the listener silently gets nothing.
   - `NSBonjourServices` = [`_controllerbridge._udp`] — only when
     `Configuration.advertise` is on; publishing an unlisted service fails.
 */

import Foundation
import Network
import simd

/// Which point on an ARKit hand pairs with a Quest controller's grip pose.
/// Any point rigid with the gripping hand works — the per-hand offset absorbs
/// the rest — but a shorter lever to the grip keeps orientation noise out of
/// the residual.
public enum RAVEQuestCalibrationAnchor: Sendable, Equatable {
    case wrist
    /// Midway between the wrist and the middle-finger knuckle.
    case palmCenter

    public func point(in sample: RAVEHandSample) -> SIMD3<Float> {
        switch self {
        case .wrist: return sample.wrist
        case .palmCenter: return (sample.wrist + sample.middle.knuckle) * 0.5
        }
    }
}

public final class RAVEQuestBridgeSource: RAVETrackedControllerSource, @unchecked Sendable {

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// UDP port to listen on; the Quest app's "Driver port".
        public var port: UInt16 = RAVEQuestBridgeProtocol.defaultPort
        /// Advertise `_controllerbridge._udp` so the Quest app can find this
        /// device without a typed address. Needs `NSBonjourServices`.
        public var advertise = false
        /// Bonjour instance name; nil lets the system use the device name.
        public var serviceName: String?
        /// UserDefaults key for the solved transform; nil disables persistence.
        public var persistenceKey: String? = "RAVEQuestBridge.calibration.v1"
        /// UserDefaults suite; nil for `.standard`.
        public var defaultsSuiteName: String?
        /// Publish a restored transform before any fresh pair has agreed with
        /// it. Off by default: ARKit re-establishes its world origin per
        /// session, so a transform from a previous launch is right only when
        /// the origin happens to land in the same place. Off, a restore costs
        /// nothing when wrong (the watchdog discards it) and skips the whole
        /// collection when right.
        public var trustRestoredCalibration = false
        /// How old the latest controller packet may be and still count as a
        /// live pose (and as calibration evidence).
        public var poseStaleAfter: Double = 0.25
        /// After this long without a packet the controllers are gone.
        public var lostAfter: Double = 1.0
        /// Status heartbeat cadence while packets arrive.
        public var heartbeatInterval: Double = 2.0
        /// Where on the ARKit hand the pairs anchor.
        public var calibrationAnchor: RAVEQuestCalibrationAnchor = .palmCenter
        /// Double-pulse both controllers when the first calibration lands.
        public var pulseOnCalibrated = true

        public init() {}
    }

    // MARK: Status

    public enum Phase: Sendable, Equatable {
        /// Not listening, or listening with nothing heard yet.
        case idle
        /// Controller packets arrive but no hands are being fed, so
        /// calibration cannot start — call `observeHands`.
        case seen
        /// Pairs are accumulating. `samples` against
        /// `RAVEQuestCalibration.minSamples`, `spread` against
        /// `spreadTargetMeters` — the HUD's "keep moving" numbers.
        case collecting(samples: Int, spreadMeters: Float)
        /// Aligned. `residualMm` is the RMS pair error (0 for an unconfirmed
        /// warm start, see `Status.isWarmStart`).
        case calibrated(residualMm: Float)
        /// Packets stopped for longer than `lostAfter`.
        case lost
    }

    public struct Status: Sendable, Equatable {
        public var phase: Phase = .idle
        public var isListening = false
        public var isWarmStart = false
        public var leftHold: RAVEQuestHold = .held
        public var rightHold: RAVEQuestHold = .held
        public var leftTracked = false
        public var rightTracked = false
        public var batteryLeft: UInt8?
        public var batteryRight: UInt8?
        /// The sender's protocol version (1 for a v1 sender), 0 before any packet.
        public var senderVersion: UInt8 = 0
        public var sender: RAVEQuestBridgeProtocol.Sender = .unknown
        public var senderAddress: String?
        public var packetsReceived: UInt32 = 0
        /// Seconds since the last controller packet, nil before the first.
        public var inputAge: Double?

        public init() {}
    }

    // MARK: State (all guarded by `lock`)

    public let configuration: Configuration
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "rave.input.questbridge", qos: .userInteractive)
    private let clock: @Sendable () -> Double
    private let log: (@Sendable (String) -> Void)?

    private var listener: NWListener?
    private var inbound: [ObjectIdentifier: (connection: NWConnection, lastActive: Double)] = [:]
    private var returnConnection: NWConnection?
    private var returnHost: NWEndpoint.Host?

    private var latest: RAVEQuestBridgeProtocol.ControllerState?
    private var latestAt: Double = 0
    private var packetsReceived: UInt32 = 0
    private var lastHeartbeatAt: Double?
    private var heldBattery: (left: UInt8?, right: UInt8?, supported: Bool) = (nil, nil, false)
    private var alignment = RAVEQuestAlignment()
    private var lastHandsAt: Double?

    /// - Parameters:
    ///   - clock: monotonic seconds; must share `CACurrentMediaTime()`'s base
    ///     (the default, `systemUptime`, does) because callers pass that clock
    ///     into `poll(now:)` and `observeHands(now:)`.
    ///   - log: optional sink for connection and calibration events.
    public init(configuration: Configuration = Configuration(),
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                log: (@Sendable (String) -> Void)? = nil) {
        self.configuration = configuration
        self.clock = clock
        self.log = log
        if let transform = loadTransform() {
            alignment.restore(transform)
            log?("quest bridge: restored calibration (unconfirmed until fresh pairs agree)")
        }
    }

    deinit {
        listener?.cancel()
        returnConnection?.cancel()
        for entry in inbound.values { entry.connection.cancel() }
    }

    // MARK: Lifecycle

    /// Start listening. Throws when the port cannot be opened (already bound,
    /// no network). Calling it again while listening is a no-op.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        if configuration.advertise {
            listener.service = NWListener.Service(
                name: configuration.serviceName, type: RAVEQuestBridgeProtocol.bonjourServiceType,
                domain: nil, txtRecord: NWTXTRecord(["v": String(RAVEQuestBridgeProtocol.version)]))
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log?("quest bridge: listening on UDP \(port)")
            case .failed(let error): self?.log?("quest bridge: listener failed — \(error)")
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Stop listening and forget the sender. The calibration survives (and is
    /// still persisted); `resetCalibration()` is the way to drop it.
    public func stop() {
        lock.lock()
        let listener = self.listener
        let connections = inbound.values.map(\.connection)
        let ret = returnConnection
        self.listener = nil
        inbound.removeAll()
        returnConnection = nil
        returnHost = nil
        latest = nil
        lastHeartbeatAt = nil
        lastHandsAt = nil
        lock.unlock()
        listener?.cancel()
        ret?.cancel()
        connections.forEach { $0.cancel() }
    }

    /// Throw away the transform (and its persisted copy) and start collecting
    /// again — the HUD's "recalibrate" button.
    public func resetCalibration() {
        lock.lock()
        alignment.reset()
        lock.unlock()
        if let key = configuration.persistenceKey { defaults.removeObject(forKey: key) }
    }

    // MARK: Hands in

    /// Feed this frame's ARKit hands, one sample per side (nil = not tracked).
    /// This is what drives calibration; call it every frame you have hands,
    /// from any thread. `now` is monotonic seconds.
    public func observeHands(left: RAVEHandSample?, right: RAVEHandSample?, now: Double) {
        let anchor = configuration.calibrationAnchor
        observeReferences(left: left.map(anchor.point(in:)), right: right.map(anchor.point(in:)), now: now)
    }

    /// `observeHands` with the reference points already chosen, and optional
    /// per-hand confidence weights in (0, 1].
    public func observeReferences(left: SIMD3<Float>?, right: SIMD3<Float>?,
                                  leftWeight: Float = 1, rightWeight: Float = 1, now: Double) {
        let nowMs = Self.milliseconds(now)
        lock.lock()
        lastHandsAt = now
        var result = RAVEQuestAlignment.StepResult()
        if let state = latest, now - latestAt <= configuration.poseStaleAfter {
            func observation(_ chirality: RAVEHandChirality, _ reference: SIMD3<Float>?,
                             _ weight: Float) -> RAVEQuestAlignment.HandObservation {
                let hand = state[chirality]
                return RAVEQuestAlignment.HandObservation(
                    questTracked: state.isTracked(chirality), questPosition: hand.position,
                    questRotation: Self.quaternion(hand.rotation), reference: reference, weight: weight)
            }
            result = alignment.step(left: observation(.left, left, leftWeight),
                                    right: observation(.right, right, rightWeight), nowMs: nowMs)
        } else {
            result.pulse = alignment.tickPulses(nowMs: nowMs)
        }
        let transform = result.solved ? alignment.calibration.transform : nil
        let firstSolve = result.solved && result.pulse
        let samples = alignment.calibration.sampleCount
        let spread = alignment.calibration.spreadMeters
        let residual = alignment.calibration.residualMm
        lock.unlock()

        if result.watchdogReset {
            log?("quest bridge: controller poses stopped matching the hands — recalibrating")
        }
        if let transform {
            saveTransform(transform)
            if firstSolve {
                log?(String(format: "quest bridge: calibrated — %d pairs over %.2f m, residual %.0f mm",
                            samples, spread, residual))
            }
        }
        if result.pulse && configuration.pulseOnCalibrated {
            for chirality in RAVEHandChirality.allCases {
                sendHaptic(RAVEControllerHaptic(chirality: chirality, duration: 0.12, frequency: 60,
                                                amplitude: 0.6))
            }
        }
    }

    // MARK: RAVETrackedControllerSource

    public func poll(now: Double) -> RAVETrackedControllerFrame {
        lock.lock()
        defer { lock.unlock() }
        guard let state = latest, now - latestAt <= configuration.lostAfter else {
            return RAVETrackedControllerFrame()
        }
        let fresh = now - latestAt <= configuration.poseStaleAfter
        let aligned = alignment.isCalibrated
            && (configuration.trustRestoredCalibration || !alignment.isWarmStart)
        var frame = RAVETrackedControllerFrame()
        for chirality in RAVEHandChirality.allCases {
            let hand = state[chirality]
            let verdict = alignment.verdict(chirality)
            let placed = alignment.apply(chirality, position: hand.position,
                                         rotation: Self.quaternion(hand.rotation))
            frame[chirality] = RAVETrackedControllerState(
                chirality: chirality,
                isTracked: state.isTracked(chirality) && fresh && aligned && verdict != .notHeld,
                isInHand: verdict != .notHeld,
                position: placed.position,
                orientation: placed.rotation,
                trigger: hand.trigger,
                grip: hand.grip,
                stick: hand.stick,
                buttons: Self.buttons(state.buttons, chirality),
                touchValid: state.flags.contains(.touch),
                batteryPercent: chirality == .left ? heldBattery.left : heldBattery.right,
                timestamp: latestAt)
        }
        return frame
    }

    public func sendHaptic(_ haptic: RAVEControllerHaptic) {
        lock.lock()
        let connection = returnConnection
        lock.unlock()
        guard let connection else { return }
        let bytes = RAVEQuestBridgeProtocol.Haptic(haptic).encoded()
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    // MARK: Status

    /// A snapshot for a HUD. Cheap; poll it at display rate.
    public var status: Status {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        var s = Status()
        s.isListening = listener != nil
        s.isWarmStart = alignment.isWarmStart
        s.leftHold = alignment.verdict(.left)
        s.rightHold = alignment.verdict(.right)
        s.packetsReceived = packetsReceived
        s.senderAddress = returnHost.map { "\($0)" }
        s.batteryLeft = heldBattery.left
        s.batteryRight = heldBattery.right
        guard s.isListening, let state = latest else { return s }
        s.senderVersion = max(state.protocolVersion, RAVEQuestBridgeProtocol.minimumVersion)
        s.sender = state.senderKind
        s.inputAge = now - latestAt
        s.leftTracked = state.isTracked(.left)
        s.rightTracked = state.isTracked(.right)
        if now - latestAt > configuration.lostAfter {
            s.phase = .lost
        } else if alignment.isCalibrated {
            s.phase = .calibrated(residualMm: alignment.calibration.residualMm)
        } else if let handsAt = lastHandsAt, now - handsAt <= configuration.lostAfter {
            s.phase = .collecting(samples: alignment.calibration.sampleCount,
                                  spreadMeters: alignment.calibration.spreadMeters)
        } else {
            s.phase = .seen
        }
        return s
    }

    // MARK: Network

    private func accept(_ connection: NWConnection) {
        let now = clock()
        lock.lock()
        // UDP "connections" are per remote endpoint and never close on their
        // own; the Quest's probe opens a fresh socket per press, so prune.
        let idle = inbound.filter { now - $0.value.lastActive > 30 }
        for key in idle.keys { inbound.removeValue(forKey: key) }
        inbound[ObjectIdentifier(connection)] = (connection, now)
        lock.unlock()
        idle.values.forEach { $0.connection.cancel() }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(datagram: [UInt8](data), from: connection, now: self.clock())
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                self.lock.lock()
                self.inbound.removeValue(forKey: ObjectIdentifier(connection))
                self.lock.unlock()
                connection.cancel()
            }
        }
    }

    /// Everything a datagram does, with the transport reduced to "reply" and
    /// "who sent it" so the protocol behaviour is testable without a socket.
    struct Outgoing: Equatable {
        var reply: [UInt8]?
        var heartbeat: [UInt8]?
    }

    private func handle(datagram: [UInt8], from connection: NWConnection, now: Double) {
        var host: NWEndpoint.Host?
        if case let .hostPort(remoteHost, _) = connection.endpoint { host = remoteHost }
        let out = process(datagram: datagram, senderHost: host.map { "\($0)" }, now: now) {
            self.lock.lock()
            self.inbound[ObjectIdentifier(connection)]?.lastActive = now
            if let host, host != self.returnHost { self.retarget(to: host) }
            self.lock.unlock()
        }
        if let reply = out.reply {
            connection.send(content: Data(reply), completion: .idempotent)
        }
        if let heartbeat = out.heartbeat {
            lock.lock()
            let ret = returnConnection
            lock.unlock()
            ret?.send(content: Data(heartbeat), completion: .idempotent)
        }
    }

    /// The protocol state machine. `onController` runs (unlocked) for every
    /// accepted controller packet, before the heartbeat decision.
    func process(datagram: [UInt8], senderHost: String?, now: Double,
                 onController: () -> Void = {}) -> Outgoing {
        var out = Outgoing()
        switch RAVEQuestBridgeProtocol.decode(datagram) {
        case .probe(let probe):
            lock.lock()
            let count = packetsReceived
            lock.unlock()
            out.reply = RAVEQuestBridgeProtocol.Status(
                protocolVersion: RAVEQuestBridgeProtocol.negotiatedVersion(peer: probe.protocolVersion),
                nonce: probe.nonce, packetsReceived: count).encoded()

        case .controllerState(let state):
            onController()
            lock.lock()
            let first = latest == nil
            latest = state
            latestAt = now
            packetsReceived &+= 1
            if state.flags.contains(.battery) {
                heldBattery = (state.battery(.left), state.battery(.right), true)
            }
            // An unflagged packet after a flagged one holds the last reading:
            // levels are polled every ~30 s, input arrives at frame rate.
            if first || lastHeartbeatAt.map({ now - $0 >= configuration.heartbeatInterval }) ?? true {
                lastHeartbeatAt = now
                out.heartbeat = RAVEQuestBridgeProtocol.Status(
                    protocolVersion: RAVEQuestBridgeProtocol.negotiatedVersion(peer: state.protocolVersion),
                    packetsReceived: packetsReceived).encoded()
            }
            lock.unlock()
            if first {
                log?("quest bridge: controllers streaming from \(senderHost ?? "?") "
                     + "(protocol v\(max(state.protocolVersion, 1)))")
            }

        case .haptic, .status, nil:
            break
        }
        return out
    }

    /// Caller holds `lock`.
    private func retarget(to host: NWEndpoint.Host) {
        returnConnection?.cancel()
        let port = NWEndpoint.Port(rawValue: configuration.port &+ RAVEQuestBridgeProtocol.hapticPortOffset)!
        let connection = NWConnection(host: host, port: port, using: .udp)
        connection.start(queue: queue)
        returnConnection = connection
        returnHost = host
    }

    // MARK: Persistence

    private var defaults: UserDefaults {
        configuration.defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private func loadTransform() -> RAVEQuestCalibration.Transform? {
        guard let key = configuration.persistenceKey, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RAVEQuestCalibration.Transform.self, from: data)
    }

    private func saveTransform(_ transform: RAVEQuestCalibration.Transform) {
        guard let key = configuration.persistenceKey,
              let data = try? JSONEncoder().encode(transform) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: Conversions

    static func milliseconds(_ seconds: Double) -> UInt64 {
        // 0 means "untimestamped" to the calibration ring; never hand it that.
        max(1, UInt64(max(0, seconds) * 1000))
    }

    static func quaternion(_ xyzw: SIMD4<Float>) -> simd_quatf {
        let q = simd_quatf(vector: xyzw)
        let length = simd_length(q.vector)
        // An untracked side ships zeros; keep the math finite.
        return length > 1e-6 ? simd_quatf(vector: q.vector / length) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    static func buttons(_ raw: RAVEQuestBridgeProtocol.Buttons,
                        _ chirality: RAVEHandChirality) -> RAVEControllerButtons {
        typealias B = RAVEQuestBridgeProtocol.Buttons
        let map: [(B, RAVEControllerButtons)] = chirality == .left
            ? [(.x, .primary), (.y, .secondary), (.leftStick, .stickClick), (.leftMenu, .menu),
               (.leftGrip, .gripClick), (.leftTriggerTouch, .triggerTouch), (.leftThumbTouch, .thumbTouch)]
            : [(.a, .primary), (.b, .secondary), (.rightStick, .stickClick), (.rightMenu, .menu),
               (.rightGrip, .gripClick), (.rightTriggerTouch, .triggerTouch), (.rightThumbTouch, .thumbTouch)]
        var out: RAVEControllerButtons = []
        for (bit, button) in map where raw.contains(bit) { out.insert(button) }
        return out
    }
}
