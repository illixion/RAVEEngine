/*
 RAVE Engine — a whole body from PoseHub's cameras, in this app's world.

 PoseHub sends a fused skeleton per camera frame to whoever subscribes
 (`RAVEBodyStreamProtocol`). This class is the subscriber an app runs: it finds
 the hub (Bonjour, or a given address), keeps the subscription alive, keeps
 the newest frame, and fits the hub's space to the app's world from the
 headset's own head and wrists (`RAVEBodyAlignment`), so `poll` hands out
 joints and trackers in the same space as everything else the app tracks.

 Head and wrists in: the app already tracks them (a `PerformerFrame`, an
 ARKit hand sensor), so it calls `observe` every frame with what it has. The
 source keeps the last second of them and pairs each camera frame with where
 they were when the cameras saw it, the frame's latency ago. That is what
 keeps a 60–90 ms old frame from dragging the fit sideways as the wearer
 moves. It never opens an ARKit session itself, which is what keeps it
 building on macOS and its alignment testable.

 Isolation: none. A lock-guarded class, `@unchecked Sendable`, like
 `RAVEQuestBridgeSource`: `observe`, `poll` and `status` are safe from any
 thread, including a render thread; network callbacks run on a private
 serial queue.

 ┌──────────────────────────────────────────────────────────────────────────┐
 │ Info.plist — REQUIRED in every consuming app                             │
 │                                                                          │
 │   NSLocalNetworkUsageDescription  (String)                               │
 │       Talking to a LAN hub triggers the local-network prompt.            │
 │   NSBonjourServices  (Array)                                             │
 │       [ "_posehub._udp" ]  — for `.discover`; browsing an unlisted type  │
 │       finds nothing. A fixed `.address` needs no entry.                  │
 └──────────────────────────────────────────────────────────────────────────┘
 */

import DebugLog
import Foundation
import Network
import simd

public final class RAVEBodyStreamSource: @unchecked Sendable {

    public struct Configuration: Sendable, Equatable {
        public enum Hub: Sendable, Equatable {
            /// The first hub Bonjour finds.
            case discover
            case address(host: String, port: UInt16 = RAVEBodyStreamProtocol.defaultPort)
        }

        public var hub: Hub = .discover
        /// How this app shows in the hub's log.
        public var name = "RAVE"
        /// A frame older than this is not handed out.
        public var staleAfter: Double = 0.5
        /// One-way network time added to a frame's own latency to find when
        /// the cameras saw it on this device's clock.
        public var networkDelay: Double = 0.004
        /// Anchors moving faster than this (m/s) give no pairs: 10 ms of clock
        /// error would be a centimetre.
        public var pairMaxSpeed: Float = 1.0

        public init(hub: Hub = .discover, name: String = "RAVE") {
            self.hub = hub
            self.name = name
        }
    }

    public enum State: String, Sendable {
        /// Not started.
        case idle
        /// Looking for a hub on the network.
        case searching
        /// Subscribed, nothing heard yet.
        case waiting
        case receiving
        /// Frames stopped coming.
        case lost
    }

    public struct Status: Sendable, Equatable {
        public var state: State = .idle
        /// The hub's Bonjour name or address.
        public var hub: String?
        public var framesPerSecond: Int = 0
        /// The newest frame's hub latency, milliseconds.
        public var hubLatencyMs: Float = 0
        /// Seconds since the newest frame arrived.
        public var frameAge: Double?
        public var clockUncertaintyMs: Double?
        public var rejected: UInt32 = 0
        public var aligned = false
        public var alignmentSamples = 0
        public var alignmentSpread: Float = 0
        /// RMS disagreement between the headset and the cameras after the fit,
        /// centimetres.
        public var alignmentResidualCm: Float = 0
        public var joints = 0
        public var trackers = 0
        public var dropped: UInt32 = 0
        /// The hub's setup state and prompt, while it keeps sending them
        /// (nil after 3 s of silence, or from a hub that predates them).
        public var setup: RAVEBodyHubStatus?

        public init() {}
    }

    /// What `poll` hands out.
    public struct Reading: Sendable {
        /// In the app's world once aligned, else in the hub's space.
        public var frame: RAVEBodyFrame
        public var isAligned: Bool
        /// Estimated capture-to-use age, including inference and network.
        public var age: Double
        /// Capture time on the consumer's clock, for measurement-rate updates.
        public var capturedAt: Double
        public var alignmentRevision: UInt64
    }

    // MARK: State (all guarded by `lock`)

    public let configuration: Configuration
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "rave.input.bodystream", qos: .userInteractive)
    private let clock: @Sendable () -> Double
    private let log: (@Sendable (DebugLogMessage) -> Void)?

    private var running = false
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var hubName: String?
    /// Where the hub might be, tried in turn until one sends frames: a hub
    /// lists every address it has, and not all of them reach this device.
    private var candidates: [(endpoint: NWEndpoint, name: String)] = []
    private var candidate = 0
    private var connectedAt: Double = 0
    private var latest: RAVEBodyFrame?
    private var latestAt: Double = 0
    /// Anything from the hub (frame, pong, status): it is reachable here,
    /// even before it has a calibration to send frames from.
    private var heardAt: Double = 0
    private var setup: RAVEBodyHubStatus?
    private var setupAt: Double = 0
    private var arrivals: [Double] = []
    private var dropped: UInt32 = 0
    private var rejected: UInt32 = 0
    private var bodyClock = RAVEBodyClock()
    private var pendingPing: Double?
    private var latestCapturedAt: Double = 0
    private var alignmentRevision: UInt64 = 0
    private var disagreementSince: Double?
    private var retiredGenerations: [UInt64] = []
    private var lastReferenceSent: Double = -1e9
    private var alignment = RAVEBodyAlignment()
    private var references: [Reference] = []

    struct Reference {
        var time: Double
        var head: SIMD3<Float>?
        var leftWrist: SIMD3<Float>?
        var rightWrist: SIMD3<Float>?
    }

    /// - Parameters:
    ///   - clock: monotonic seconds, the base callers pass to `observe(now:)`
    ///     and `poll(now:)` (the default, `systemUptime`, shares
    ///     `CACurrentMediaTime()`'s).
    ///   - log: optional sink for connection and alignment events.
    public init(configuration: Configuration = Configuration(),
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                log: (@Sendable (DebugLogMessage) -> Void)? = nil) {
        self.configuration = configuration
        self.clock = clock
        self.log = log
    }

    deinit {
        browser?.cancel()
        connection?.cancel()
        timer?.cancel()
    }

    // MARK: Lifecycle

    /// Find the hub and subscribe. A no-op while running.
    public func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + RAVEBodyStreamProtocol.subscribeInterval,
                       repeating: RAVEBodyStreamProtocol.subscribeInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        var browser: NWBrowser?
        if configuration.hub == .discover {
            let found = NWBrowser(for: .bonjourWithTXTRecord(type: RAVEBodyStreamProtocol.bonjourServiceType,
                                                             domain: nil), using: .udp)
            found.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
            found.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.log?("body stream: browsing failed — \(String(describing: error), privacy: .public)")
                }
            }
            self.browser = found
            browser = found
        }
        lock.unlock()
        timer.resume()
        if let browser {
            browser.start(queue: queue)
            log?("body stream: looking for a hub")
        } else if case let .address(host, port) = configuration.hub, let port = NWEndpoint.Port(rawValue: port) {
            use([(.hostPort(host: NWEndpoint.Host(host), port: port), host)])
        }
    }

    /// Unsubscribe and stop. The alignment is dropped with the connection:
    /// a new session's world is not the old one's.
    public func stop() {
        lock.lock()
        let connection = self.connection, browser = self.browser, timer = self.timer
        running = false
        self.connection = nil
        self.browser = nil
        self.timer = nil
        hubName = nil
        candidates.removeAll()
        latest = nil
        setup = nil
        heardAt = 0
        references.removeAll()
        alignment.reset()
        bodyClock = RAVEBodyClock()
        pendingPing = nil
        retiredGenerations.removeAll()
        disagreementSince = nil
        alignmentRevision &+= 1
        lock.unlock()
        timer?.cancel()
        browser?.cancel()
        if let connection {
            connection.send(content: Data(RAVEBodyStreamProtocol.unsubscribe()), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// Start the fit over: after a recentre, or when the cameras moved.
    public func resetAlignment() {
        lock.lock()
        alignment.reset()
        references.removeAll()
        disagreementSince = nil
        alignmentRevision &+= 1
        lock.unlock()
    }

    // MARK: The headset's view

    /// Where the headset has the head and wrists now, in the app's world.
    /// Call every frame; any may be nil. `head` is the device's origin.
    public func observe(head: SIMD3<Float>?, leftWrist: SIMD3<Float>?, rightWrist: SIMD3<Float>?, now: Double,
                        headRotation: simd_quatf? = nil) {
        lock.lock()
        guard running else { lock.unlock(); return }
        references.append(Reference(time: now, head: head, leftWrist: leftWrist, rightWrist: rightWrist))
        if let first = references.first, now - first.time > 1.5 {
            references.removeAll { now - $0.time > 1.0 }
        }
        var reference: [UInt8]?
        if now - lastReferenceSent >= 1 / 60, let head, let headRotation,
           let fit = alignment.transform, let generation = latest?.generation,
           now - latestCapturedAt <= configuration.staleAfter,
           let time = bodyClock.hubTime(now, now: now) {
            let inverse = simd_quatf(angle: -fit.yaw, axis: SIMD3<Float>(0, 1, 0))
            func point(_ p: SIMD3<Float>) -> SIMD3<Float> { inverse.act(p - fit.translation) }
            // ARKit's head looks down -Z, the body's head looks down +Z.
            let rotation = simd_normalize(inverse * headRotation * simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
            let ears = point(head) - rotation.act(RAVEBodyAlignment.headOffset)
            reference = RAVEBodyStreamProtocol.reference(generation: generation, time: time,
                head: RAVEBodyTrackerPose(position: ears, rotation: rotation, confidence: 1),
                leftWrist: leftWrist.map(point), rightWrist: rightWrist.map(point))
            lastReferenceSent = now
        }
        let connection = self.connection
        lock.unlock()
        if let reference, let connection {
            connection.send(content: Data(reference), completion: .idempotent)
        }
    }

    // MARK: Reading

    /// The newest frame, if fresh: in the world once aligned.
    public func poll(now: Double) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, now - latestCapturedAt <= configuration.staleAfter else { return nil }
        let age = max(0, now - latestCapturedAt)
        if let fit = alignment.transform {
            return Reading(frame: latest.transformed(yaw: fit.yaw, translation: fit.translation), isAligned: true,
                           age: age, capturedAt: latestCapturedAt, alignmentRevision: alignmentRevision)
        }
        return Reading(frame: latest, isAligned: false, age: age, capturedAt: latestCapturedAt,
                       alignmentRevision: alignmentRevision)
    }

    public func status(now: Double) -> Status {
        lock.lock()
        defer { lock.unlock() }
        var status = Status()
        status.hub = hubName
        status.framesPerSecond = arrivals.filter { now - $0 <= 1 }.count
        status.dropped = dropped
        status.rejected = rejected
        status.clockUncertaintyMs = bodyClock.uncertainty(now: now).map { $0 * 1000 }
        status.aligned = alignment.isAligned
        status.alignmentSamples = alignment.sampleCount
        status.alignmentSpread = alignment.spreadMeters
        status.alignmentResidualCm = alignment.residual * 100
        if now - setupAt <= 3 { status.setup = setup }
        if let latest {
            status.hubLatencyMs = latest.latency * 1000
            status.frameAge = max(0, now - latestCapturedAt)
            status.joints = latest.joints.count
            status.trackers = latest.trackers.count
        }
        if !running {
            status.state = .idle
        } else if latest != nil {
            status.state = now - latestCapturedAt <= configuration.staleAfter ? .receiving : .lost
        } else {
            status.state = connection == nil ? .searching : .waiting
        }
        return status
    }

    // MARK: Network (queue)

    /// Seconds a candidate gets to send a frame before the next is tried.
    static let candidateTimeout: Double = 3

    /// The hub's TXT record lists its addresses and port, so the source
    /// connects to plain addresses rather than the service. A UDP
    /// `NWConnection` to the service itself sat in "preparing" for good on
    /// macOS 27 although dns-sd resolved it, and a hub on a machine with
    /// several networks has addresses this device can't reach anyway.
    private func found(_ results: Set<NWBrowser.Result>) {
        var list: [(endpoint: NWEndpoint, name: String)] = []
        for result in results.sorted(by: { "\($0.endpoint)" < "\($1.endpoint)" }) {
            var name = "\(result.endpoint)"
            if case let .service(service, _, _, _) = result.endpoint { name = service }
            if case let .bonjour(txt) = result.metadata, let addresses = txt["addr"],
               let port = txt["port"].flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:)) {
                for address in addresses.split(separator: ",") where !address.isEmpty {
                    list.append((.hostPort(host: NWEndpoint.Host(String(address)), port: port), name))
                }
            }
            list.append((result.endpoint, name))
        }
        guard !list.isEmpty else { return }
        lock.lock()
        let fresh = connection == nil
        lock.unlock()
        if fresh {
            use(list)
        } else {
            lock.lock()
            candidates = list
            candidate = min(candidate, list.count - 1)
            lock.unlock()
        }
    }

    private func use(_ list: [(endpoint: NWEndpoint, name: String)]) {
        lock.lock()
        candidates = list
        candidate = 0
        lock.unlock()
        connect(to: list[0].endpoint, name: list[0].name)
    }

    /// Every second: renew the subscription, and move on from a candidate
    /// that has sent nothing.
    private func tick() {
        let now = clock()
        lock.lock()
        let quiet = connection != nil && now - max(connectedAt, latestAt, heardAt) > Self.candidateTimeout
        var next: (endpoint: NWEndpoint, name: String)?
        if quiet, candidates.count > 1 {
            candidate = (candidate + 1) % candidates.count
            next = candidates[candidate]
        }
        lock.unlock()
        if let next {
            connect(to: next.endpoint, name: next.name)
        } else {
            subscribe()
        }
    }

    /// Takes `lock` itself; callers must not hold it.
    private func connect(to endpoint: NWEndpoint, name: String) {
        let parameters = NWParameters.udp
        // The hub listens on IPv4 only; a Bonjour name can resolve to a
        // link-local IPv6 address first.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.log?("body stream: subscribing to \(name, privacy: .private(mask: .hash)) at \("\(endpoint)", privacy: .private(mask: .hash))")
                self.subscribe()
            case .failed(let error):
                self.log?("body stream: connection failed — \(String(describing: error), privacy: .public)")
                self.dropConnection(connection)
            default:
                break
            }
        }
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        let old = self.connection
        self.connection = connection
        latest = nil
        setup = nil
        heardAt = 0
        bodyClock = RAVEBodyClock()
        pendingPing = nil
        alignment.reset()
        disagreementSince = nil
        alignmentRevision &+= 1
        hubName = name
        connectedAt = clock()
        lock.unlock()
        old?.cancel()
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// A failed connection is dropped; the next tick tries another candidate
    /// or, with none, discovery finds the hub again.
    private func dropConnection(_ connection: NWConnection) {
        lock.lock()
        let current = self.connection === connection
        if current {
            self.connection = nil
            hubName = nil
        }
        let retry = current && running && !candidates.isEmpty
            ? candidates[(candidate + 1) % candidates.count] : nil
        if retry != nil { candidate = (candidate + 1) % candidates.count }
        lock.unlock()
        connection.cancel()
        guard let retry else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect(to: retry.endpoint, name: retry.name) }
    }

    private func subscribe() {
        lock.lock()
        let connection = self.connection
        let sent = clock()
        pendingPing = sent
        lock.unlock()
        guard let connection, connection.state == .ready else { return }
        connection.send(content: Data(RAVEBodyStreamProtocol.subscribe(name: configuration.name)),
                        completion: .idempotent)
        connection.send(content: Data(RAVEBodyStreamProtocol.ping(sentAt: sent)), completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            self.lock.lock()
            let current = self.running && self.connection === connection
            self.lock.unlock()
            guard current else { return }
            if let data {
                let bytes = [UInt8](data), now = self.clock()
                if let frame = RAVEBodyStreamProtocol.decodeFrame(bytes) {
                    self.accept(frame, at: now)
                } else if let pong = RAVEBodyStreamProtocol.decodePong(bytes) {
                    self.accept(pong, at: now)
                } else if let status = RAVEBodyStreamProtocol.decodeStatus(bytes) {
                    self.accept(status, at: now)
                }
            }
            if error == nil, connection.state != .cancelled { self.receive(on: connection) }
        }
    }

    // MARK: Frames

    func accept(_ status: RAVEBodyHubStatus, at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        setup = status
        setupAt = now
        heardAt = now
    }

    func accept(_ pong: RAVEBodyStreamProtocol.Pong, at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        heardAt = now
        guard pendingPing == pong.sent else { return }
        pendingPing = nil
        bodyClock.record(sent: pong.sent, received: now, hubReceived: pong.hubReceived, hubSent: pong.hubSent)
    }

    func accept(_ frame: RAVEBodyFrame, at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard running, frame.captureTime.isFinite, frame.latency.isFinite, frame.latency >= 0 else { return }
        if latest?.generation != nil, frame.generation == nil { return }
        if let generation = frame.generation, retiredGenerations.contains(generation) { return }
        let changedSpace = latest.map { $0.generation != frame.generation } ?? false
        var capturedAt = (changedSpace ? nil : bodyClock.localTime(frame.captureTime, now: now))
            ?? (now - Double(frame.latency) - configuration.networkDelay)
        // Reject impossible future samples, allowing clock uncertainty.
        let uncertainty = bodyClock.uncertainty(now: now) ?? 0.01
        guard capturedAt <= now + uncertainty, frame.latency <= Float(configuration.staleAfter),
              now - capturedAt <= configuration.staleAfter else {
            rejected &+= 1
            return
        }
        capturedAt = min(now - Double(frame.latency), capturedAt)
        if changedSpace {
            bodyClock = RAVEBodyClock()
            if let generation = latest?.generation {
                retiredGenerations.append(generation)
                if retiredGenerations.count > 8 { retiredGenerations.removeFirst() }
            }
            alignment.reset()
            disagreementSince = nil
            alignmentRevision &+= 1
        }
        if let latest {
            let ahead = Int32(bitPattern: frame.sequence &- latest.sequence)
            // Extended hubs identify a restart explicitly. Legacy hubs can
            // restart only after silence, never just because a packet is old.
            let legacyRestart = frame.generation == nil && now - latestAt > 1
            if !changedSpace && !legacyRestart && (ahead <= 0 || frame.captureTime <= latest.captureTime) { return }
            if legacyRestart {
                alignment.reset()
                alignmentRevision &+= 1
            }
            if frame.sequence &- latest.sequence > 1, frame.sequence &- latest.sequence < 300 {
                dropped &+= frame.sequence &- latest.sequence &- 1
            }
        }
        latest = frame
        latestAt = now
        latestCapturedAt = capturedAt
        arrivals.append(now)
        if arrivals.count > 240 { arrivals.removeFirst(arrivals.count - 240) }
        pair(frame, seenAt: capturedAt)
        let wasAligned = alignment.isAligned
        let solved = alignment.maybeSolve(now: now)
        if wasAligned && !alignment.isAligned { alignmentRevision &+= 1 }
        if solved, !wasAligned, let fit = alignment.transform {
            log?("""
            body stream: aligned to the headset, \(Int((alignment.residual * 1000).rounded()), privacy: .public) mm RMS \
            over \(alignment.sampleCount, privacy: .public) pairs, yaw \(Int((fit.yaw * 180 / .pi).rounded()), privacy: .public)°
            """)
        }
    }

    /// Caller holds `lock`. Pairs the frame's head and wrists with where the
    /// headset had them at `time`.
    private func pair(_ frame: RAVEBodyFrame, seenAt time: Double) {
        guard let after = references.firstIndex(where: { $0.time >= time }), after > 0 else { return }
        let a = references[after - 1], b = references[after]
        let span = b.time - a.time
        guard span > 0, span < 0.05 else { return }
        let t = Float((time - a.time) / span)
        var errors: [Float] = []
        func offer(_ anchor: RAVEBodyAlignment.Anchor, stream: SIMD3<Float>, world: SIMD3<Float>, confidence: Float) {
            guard confidence >= RAVEBodyAlignment.minConfidence else { return }
            if let error = alignment.error(stream: stream, world: world) { errors.append(error) }
            alignment.addSample(anchor, stream: stream, world: world, weight: confidence, time: time)
        }
        func at(_ key: KeyPath<Reference, SIMD3<Float>?>) -> SIMD3<Float>? {
            guard let p = a[keyPath: key], let q = b[keyPath: key],
                  simd_distance(p, q) / Float(span) <= configuration.pairMaxSpeed else { return nil }
            return simd_mix(p, q, SIMD3(repeating: t))
        }
        if !frame.headIsReference, let world = at(\.head), let head = frame.trackers[.head] {
            offer(.head, stream: head.position + head.rotation.act(RAVEBodyAlignment.headOffset),
                  world: world, confidence: RAVEBodyAlignment.headWeight * head.confidence)
        }
        if let world = at(\.leftWrist), let wrist = frame.joints[.leftWrist] {
            offer(.leftWrist, stream: wrist.position, world: world, confidence: wrist.confidence)
        }
        if let world = at(\.rightWrist), let wrist = frame.joints[.rightWrist] {
            offer(.rightWrist, stream: wrist.position, world: world, confidence: wrist.confidence)
        }
        guard !errors.isEmpty else { return }
        if errors.sorted()[errors.count / 2] > 0.2 {
            if disagreementSince == nil { disagreementSince = time }
            if time - (disagreementSince ?? time) >= 0.5 {
                alignment.reset()
                disagreementSince = nil
                alignmentRevision &+= 1
            }
        } else {
            disagreementSince = nil
        }
    }
}
