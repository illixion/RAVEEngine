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

import DebugTrace
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
        public var aligned = false
        public var alignmentSamples = 0
        public var alignmentSpread: Float = 0
        /// RMS disagreement between the headset and the cameras after the fit,
        /// centimetres.
        public var alignmentResidualCm: Float = 0
        public var joints = 0
        public var trackers = 0
        public var dropped: UInt32 = 0

        public init() {}
    }

    /// What `poll` hands out.
    public struct Reading: Sendable {
        /// In the app's world once aligned, else in the hub's space.
        public var frame: RAVEBodyFrame
        public var isAligned: Bool
        /// Seconds since it arrived.
        public var age: Double
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
    private var arrivals: [Double] = []
    private var dropped: UInt32 = 0
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
        references.removeAll()
        alignment.reset()
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
        lock.unlock()
    }

    // MARK: The headset's view

    /// Where the headset has the head and wrists now, in the app's world.
    /// Call every frame; any may be nil. `head` is the device's origin.
    public func observe(head: SIMD3<Float>?, leftWrist: SIMD3<Float>?, rightWrist: SIMD3<Float>?, now: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        references.append(Reference(time: now, head: head, leftWrist: leftWrist, rightWrist: rightWrist))
        if let first = references.first, now - first.time > 1.5 {
            references.removeAll { now - $0.time > 1.0 }
        }
    }

    // MARK: Reading

    /// The newest frame, if fresh: in the world once aligned.
    public func poll(now: Double) -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, now - latestAt <= configuration.staleAfter else { return nil }
        if let fit = alignment.transform {
            return Reading(frame: latest.transformed(yaw: fit.yaw, translation: fit.translation), isAligned: true,
                           age: now - latestAt)
        }
        return Reading(frame: latest, isAligned: false, age: now - latestAt)
    }

    public func status(now: Double) -> Status {
        lock.lock()
        defer { lock.unlock() }
        var status = Status()
        status.hub = hubName
        status.framesPerSecond = arrivals.filter { now - $0 <= 1 }.count
        status.dropped = dropped
        status.aligned = alignment.isAligned
        status.alignmentSamples = alignment.sampleCount
        status.alignmentSpread = alignment.spreadMeters
        status.alignmentResidualCm = alignment.residual * 100
        if let latest {
            status.hubLatencyMs = latest.latency * 1000
            status.frameAge = now - latestAt
            status.joints = latest.joints.count
            status.trackers = latest.trackers.count
        }
        if !running {
            status.state = .idle
        } else if latest != nil {
            status.state = now - latestAt <= configuration.staleAfter ? .receiving : .lost
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
        let quiet = connection != nil && now - max(connectedAt, latestAt) > Self.candidateTimeout
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
        lock.unlock()
        guard let connection, connection.state == .ready else { return }
        connection.send(content: Data(RAVEBodyStreamProtocol.subscribe(name: configuration.name)),
                        completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, let frame = RAVEBodyStreamProtocol.decodeFrame([UInt8](data)) {
                self.accept(frame, at: self.clock())
            }
            if error == nil, connection.state != .cancelled { self.receive(on: connection) }
        }
    }

    // MARK: Frames

    func accept(_ frame: RAVEBodyFrame, at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let latest {
            // A frame overtaken in flight is a few behind and dropped; one far
            // behind, or after a silence, is a restarted hub.
            let behind = latest.sequence &- frame.sequence
            if behind < 30, now - latestAt < 1 { return }
            if frame.sequence &- latest.sequence > 1, frame.sequence &- latest.sequence < 300 {
                dropped &+= frame.sequence &- latest.sequence &- 1
            }
        }
        latest = frame
        latestAt = now
        arrivals.append(now)
        if arrivals.count > 240 { arrivals.removeFirst(arrivals.count - 240) }
        pair(frame, seenAt: now - Double(frame.latency) - configuration.networkDelay)
        let wasAligned = alignment.isAligned
        if alignment.maybeSolve(now: now), !wasAligned, let fit = alignment.transform {
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
        func at(_ key: KeyPath<Reference, SIMD3<Float>?>) -> SIMD3<Float>? {
            guard let p = a[keyPath: key], let q = b[keyPath: key],
                  simd_distance(p, q) / Float(span) <= configuration.pairMaxSpeed else { return nil }
            return simd_mix(p, q, SIMD3(repeating: t))
        }
        if let world = at(\.head), let head = frame.trackers[.head] {
            alignment.addSample(.head, stream: head.position + head.rotation.act(RAVEBodyAlignment.headOffset),
                                world: world, weight: RAVEBodyAlignment.headWeight * head.confidence, time: time)
        }
        if let world = at(\.leftWrist), let wrist = frame.joints[.leftWrist] {
            alignment.addSample(.leftWrist, stream: wrist.position, world: world, weight: wrist.confidence, time: time)
        }
        if let world = at(\.rightWrist), let wrist = frame.joints[.rightWrist] {
            alignment.addSample(.rightWrist, stream: wrist.position, world: world, weight: wrist.confidence, time: time)
        }
    }
}
