import Foundation
import Network

/// Developer-mode HTTP/JSON introspection and control for on-device QA.
///
/// This is the transport half of the pattern proven in Oneiros: while the
/// headset runs the app, a Mac on the same network queries live state instead
/// of diagnosing from screenshots.
///
///     curl http://<device-ip>:8642/            # endpoint index
///     curl http://<device-ip>:8642/state       # whatever the app registered
///
/// It carries **no** app semantics — an app supplies its own `RAVEDebugRoute`
/// values and this type owns the listener, request parsing, `/help`, and the
/// response encoding. That split is deliberate: the app-side route file is the
/// thing you strip from a submission build (see `RAVEDebugServer` docs in
/// `~/CLAUDE.md`), and what remains here is generic plumbing with no knowledge
/// of the app it was linked into.
///
/// Everything runs on the main queue. Traffic is a handful of tiny requests
/// during debugging, and staying on `.main` keeps `@MainActor` model reads
/// race-free without any snapshot plumbing.
///
/// - Important: binding a listener triggers the system Local Network privacy
///   prompt. The host app needs `NSLocalNetworkUsageDescription` in its
///   Info.plist or `start()` fails silently.
@MainActor
public final class RAVEDebugServer {

    // MARK: - Request

    /// A parsed GET request. Query values are exposed through accessors rather
    /// than three parallel dictionaries, so a route asks for the type it wants.
    public struct Request: Sendable {
        public let path: String
        public let rawQuery: [String: String]

        public init(path: String, rawQuery: [String: String]) {
            self.path = path
            self.rawQuery = rawQuery
        }

        public func string(_ key: String) -> String? { rawQuery[key] }
        public func int(_ key: String) -> Int? { rawQuery[key].flatMap(Int.init) }
        public func double(_ key: String) -> Double? { rawQuery[key].flatMap(Double.init) }

        /// `?flag`, `?flag=1`, `?flag=true`, `?flag=yes` are all true.
        public func flag(_ key: String, default fallback: Bool = false) -> Bool {
            guard let raw = rawQuery[key] else { return fallback }
            if raw.isEmpty { return true }
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return fallback
            }
        }

        public var hasQuery: Bool { !rawQuery.isEmpty }
    }

    // MARK: - Response

    public enum Response {
        case json(status: String = "200 OK", body: [String: Any])
        case binary(contentType: String, body: Data)
        /// Reply first, then run `after` once the bytes reach the network.
        /// For endpoints whose side effect tears down this very server — an
        /// immersive exit cancels the listener, so the reply has to be handed
        /// over before the action runs or the caller sees a dropped connection.
        case jsonThen(status: String = "200 OK", body: [String: Any], after: @MainActor () -> Void)

        public static func error(_ status: String, _ message: String) -> Response {
            .json(status: status, body: ["error": message])
        }

        /// 400 with a uniform shape, for the very common missing-parameter case.
        public static func badRequest(_ message: String) -> Response {
            .json(status: "400 Bad Request", body: ["error": message])
        }
    }

    // MARK: - Route

    public struct Route {
        /// Path including the leading slash, e.g. `"/state"`.
        public let path: String
        /// One line for `/help`. Include the query shape, e.g.
        /// `"/chunk?x=&y=&z=": "one chunk coord's membership…"`.
        public let usage: String
        let handler: Handler

        enum Handler {
            case sync(@MainActor (Request) -> Response)
            case async(@MainActor (Request) async -> Response)
        }

        public init(_ path: String, usage: String, handler: @escaping @MainActor (Request) -> Response) {
            self.path = path
            self.usage = usage
            self.handler = .sync(handler)
        }

        /// For routes that must await — a frame capture, a disk write.
        public init(_ path: String, usage: String, asyncHandler: @escaping @MainActor (Request) async -> Response) {
            self.path = path
            self.usage = usage
            self.handler = .async(asyncHandler)
        }
    }

    // MARK: - Lifecycle

    public let port: UInt16
    private var routes: [String: Route] = [:]
    private var order: [String] = []
    private var listener: NWListener?
    private let log: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - port: TCP port to bind. Oneiros uses 8642.
    ///   - log: where to send lifecycle lines. Left nil, the server is silent —
    ///     the package deliberately does not pick a logging framework.
    public init(port: UInt16, log: (@Sendable (String) -> Void)? = nil) {
        self.port = port
        self.log = log
    }

    public func register(_ route: Route) {
        if routes[route.path] == nil { order.append(route.path) }
        routes[route.path] = route
    }

    public func register(_ routes: [Route]) {
        for route in routes { register(route) }
    }

    public var isRunning: Bool { listener != nil }

    public func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: port) else {
            log?("RAVEDebugServer: invalid port \(self.port)")
            return
        }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                // The listener runs on the main queue, so MainActor is a fact here.
                MainActor.assumeIsolated {
                    self?.accept(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            let addresses = Self.localIPv4Addresses().joined(separator: ", ")
            log?("RAVEDebugServer: listening on port \(self.port) (\(addresses.isEmpty ? "no LAN address yet" : addresses))")
        } catch {
            // Port in use (a second instance — e.g. spectator alongside
            // immersive) or sandbox denial. Debug tooling, never fatal.
            log?("RAVEDebugServer: failed to start: \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Requests are single tiny GETs; one read is enough for curl/browsers.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil, let data, !data.isEmpty,
                      let raw = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.handle(raw, on: connection)
            }
        }
    }

    private func handle(_ raw: String, on connection: NWConnection) {
        guard let request = Self.parse(raw) else {
            send(.error("400 Bad Request", "malformed request line"), on: connection)
            return
        }
        if request.path == "/" || request.path == "/help" {
            send(helpResponse(), on: connection)
            return
        }
        guard let route = routes[request.path] else {
            send(.json(status: "404 Not Found",
                       body: ["error": "no such endpoint", "try": "/help"]),
                 on: connection)
            return
        }
        switch route.handler {
        case .sync(let handler):
            send(handler(request), on: connection)
        case .async(let handler):
            Task { @MainActor in
                self.send(await handler(request), on: connection)
            }
        }
    }

    private func helpResponse() -> Response {
        var endpoints: [String: String] = [:]
        for path in order { endpoints[path] = routes[path]?.usage ?? "" }
        return .json(body: ["endpoints": endpoints])
    }

    private func send(_ response: Response, on connection: NWConnection) {
        switch response {
        case .json(let status, let body):
            connection.send(content: Self.httpResponse(status: status, body: body),
                            completion: .contentProcessed { _ in connection.cancel() })
        case .binary(let contentType, let body):
            connection.send(content: Self.httpBinaryResponse(contentType: contentType, body: body),
                            completion: .contentProcessed { _ in connection.cancel() })
        case .jsonThen(let status, let body, let after):
            connection.send(content: Self.httpResponse(status: status, body: body),
                            completion: .contentProcessed { [log] error in
                MainActor.assumeIsolated {
                    if let error { log?("RAVEDebugServer: deferred-action response failed: \(error)") }
                    connection.cancel()
                    after()
                }
            })
        }
    }

    // MARK: - Parsing

    static func parse(_ raw: String) -> Request? {
        guard let line = raw.components(separatedBy: "\r\n").first, line.hasPrefix("GET ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = parts[1].split(separator: "?", maxSplits: 1)
        let path = String(target[0])
        var query: [String: String] = [:]
        if target.count == 2 {
            for pair in target[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1])
                } else if kv.count == 1 {
                    // Bare `?flag` with no value — `flag(_:)` reads it as true.
                    query[String(kv[0])] = ""
                }
            }
        }
        return Request(path: path, rawQuery: query)
    }

    // MARK: - Encoding

    public static func httpResponse(status: String = "200 OK", body: [String: Any]) -> Data {
        // JSONSerialization THROWS an ObjC exception (uncatchable from Swift —
        // the app aborts) on a non-finite number; a compositor's default far
        // plane is `inf`, which took a headset down on a /state poll
        // (2026-08-27). Scrub every nested number first.
        let safe = sanitized(body) as? [String: Any] ?? [:]
        let payload = (try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"error\":\"unserializable state\"}".utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + payload
    }

    public static func httpBinaryResponse(contentType: String, body: Data) -> Data {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Recursively replaces non-finite Double/Float values with strings
    /// ("inf", "-inf", "nan") so JSON serialization can never throw.
    public static func sanitized(_ value: Any) -> Any {
        switch value {
        case let d as Double:
            return d.isFinite ? d : (d.isNaN ? "nan" : (d > 0 ? "inf" : "-inf"))
        case let f as Float:
            return f.isFinite ? f : (f.isNaN ? "nan" : (f > 0 ? "inf" : "-inf"))
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitized(v) }
            return out
        case let array as [Any]:
            return array.map(sanitized)
        default:
            return value
        }
    }

    // MARK: - Discovery

    /// Interface-name + IPv4 pairs, loopback excluded — printed on start so the
    /// device's address doesn't have to be hunted in Settings.
    public static func localIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrList) == 0 else { return results }
        defer { freeifaddrs(ifaddrList) }
        var pointer = ifaddrList
        while let entry = pointer {
            let ifa = entry.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: host)
                    if !address.hasPrefix("127.") {
                        results.append("\(String(cString: ifa.ifa_name)) \(address)")
                    }
                }
            }
            pointer = ifa.ifa_next
        }
        return results
    }
}
