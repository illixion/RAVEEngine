//
//  RAVEModuleBus.swift
//  RAVEModuleBus
//
//  The one channel between modules that share a process (Nexus). A module
//  publishes what it knows (what is playing, what was just said, where the
//  screen is) as typed feeds, and registers what it can be asked to do as
//  actions. Another module reads the feeds and invokes the actions without
//  importing the first. Modules never call each other; Nexus's glue only
//  decides which modules are present.
//
//  Foundation only, so the logic runs under `swift test` on the host.
//

import Foundation

/// How sensitive a feed's content is. The bus only carries the label; the app that reads a
/// feed maps it to a `RAVEConsent` kind (text or image preview) before the content leaves
/// the device, and an on-device reader can hold a standing allow.
public enum RAVEFeedPrivacy: String, Sendable, Equatable {
    /// Counts, states and code-defined values.
    case open
    /// Text of what the person is watching, reading or playing: a title, a subtitle line.
    case personalText
    /// Text anyone could already read: a public chat's messages, a channel's title. Nothing
    /// of the person's own, so a reader needs no consent to pass it to a model, but it is
    /// typed by strangers: the reader filters it and never treats it as instructions.
    case publicText
    /// Pixels of what the person is watching or playing.
    case personalImage
}

/// The name and behaviour of one feed, with the type of what it carries. Keys are plain
/// values a vocabulary declares (`RAVEMediaFeeds`), shared by publisher and reader.
public struct RAVEFeedKey<Value: Sendable>: Sendable, Hashable {
    public let name: String
    public let privacy: RAVEFeedPrivacy
    /// A publish sooner than this after the last kept one is dropped (unless forced), so a
    /// chatty module can't flood readers. 0 keeps everything.
    public let minInterval: TimeInterval
    /// How long samples are kept for `window`; 0 keeps only the latest.
    public let retention: TimeInterval
    /// Hard cap on kept samples.
    public let retainedLimit: Int

    public init(_ name: String, privacy: RAVEFeedPrivacy = .open, minInterval: TimeInterval = 0,
                retention: TimeInterval = 0, retainedLimit: Int = 256) {
        self.name = name
        self.privacy = privacy
        self.minInterval = minInterval
        self.retention = retention
        self.retainedLimit = max(1, retainedLimit)
    }

    public static func == (a: Self, b: Self) -> Bool { a.name == b.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// One published value with when (the bus clock, seconds) and who published it.
public struct RAVEFeedSample<Value: Sendable>: Sendable {
    public let value: Value
    public let time: TimeInterval
    public let publisher: String
}

/// A reader's hold on a feed; `cancel()` stops delivery.
@MainActor
public final class RAVEBusSubscription {
    private var onCancel: (() -> Void)?
    fileprivate init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

@MainActor
public final class RAVEModuleBus {
    private struct Stored {
        let time: TimeInterval
        let publisher: String
        let value: any Sendable
    }

    private final class Store {
        var typeID: ObjectIdentifier
        var privacy: RAVEFeedPrivacy
        var samples: [Stored] = []
        var lastKept: TimeInterval?
        var subscribers: [UUID: (Stored) -> Void] = [:]
        init(typeID: ObjectIdentifier, privacy: RAVEFeedPrivacy) {
            self.typeID = typeID
            self.privacy = privacy
        }
    }

    private struct RegisteredAction {
        let action: RAVEBusAction
        let isAvailable: @MainActor () -> Bool
        let handler: @MainActor ([String: RAVEBusValue]) async -> RAVEBusResult
    }

    private var stores: [String: Store] = [:]
    private var actions: [String: RegisteredAction] = [:]
    private let clock: @MainActor () -> TimeInterval

    /// The process-wide bus. Tests make their own with a fake clock.
    public static let shared = RAVEModuleBus()

    public init(clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// Seconds on the bus clock.
    public var now: TimeInterval { clock() }

    // MARK: Feeds

    /// Publishes a value. Returns false when it was dropped: sooner than the key's
    /// `minInterval` after the last kept one, or the name already carries another type.
    @discardableResult
    public func publish<V: Sendable>(_ key: RAVEFeedKey<V>, _ value: V, from module: String,
                                     force: Bool = false) -> Bool {
        let store = store(for: key)
        guard store.typeID == ObjectIdentifier(V.self) else {
            assertionFailure("feed \(key.name) already carries another type")
            return false
        }
        let t = clock()
        if !force, key.minInterval > 0, let last = store.lastKept, t - last < key.minInterval {
            return false
        }
        let stored = Stored(time: t, publisher: module, value: value)
        store.lastKept = t
        store.samples.append(stored)
        trim(store, key: key, at: t)
        for deliver in store.subscribers.values { deliver(stored) }
        return true
    }

    /// The newest value, if any module has published since it was last retired.
    public func latest<V: Sendable>(_ key: RAVEFeedKey<V>) -> RAVEFeedSample<V>? {
        guard let s = stores[key.name], s.typeID == ObjectIdentifier(V.self),
              let last = s.samples.last else { return nil }
        return typed(last)
    }

    /// Samples from the last `seconds` (bounded by the key's retention), oldest first.
    public func window<V: Sendable>(_ key: RAVEFeedKey<V>, last seconds: TimeInterval) -> [RAVEFeedSample<V>] {
        guard let s = stores[key.name], s.typeID == ObjectIdentifier(V.self) else { return [] }
        let cutoff = clock() - seconds
        return s.samples.filter { $0.time >= cutoff }.compactMap { typed($0) }
    }

    /// Calls `handler` for every later publish, and first with the latest value when
    /// `replayLatest` is set and there is one.
    @discardableResult
    public func subscribe<V: Sendable>(_ key: RAVEFeedKey<V>, replayLatest: Bool = true,
                                       _ handler: @escaping @MainActor (RAVEFeedSample<V>) -> Void) -> RAVEBusSubscription {
        let store = store(for: key)
        let id = UUID()
        store.subscribers[id] = { stored in
            if let sample: RAVEFeedSample<V> = Self.typedSample(stored) { handler(sample) }
        }
        if replayLatest, let last = store.samples.last, let sample: RAVEFeedSample<V> = typed(last) {
            handler(sample)
        }
        return RAVEBusSubscription { [weak store] in store?.subscribers[id] = nil }
    }

    /// Feeds with something in them, with their privacy label, for a debug endpoint.
    public var liveFeeds: [(name: String, privacy: RAVEFeedPrivacy, publisher: String?, samples: Int)] {
        stores.map { ($0.key, $0.value.privacy, $0.value.samples.last?.publisher, $0.value.samples.count) }
            .filter { $0.samples > 0 }.sorted { $0.name < $1.name }
    }

    // MARK: Actions

    /// Offers `action`, replacing an earlier registration of the same id. `isAvailable`
    /// lets a module hide a verb it can't do right now (no "pause" while nothing plays).
    public func register(_ action: RAVEBusAction,
                         isAvailable: @escaping @MainActor () -> Bool = { true },
                         handler: @escaping @MainActor ([String: RAVEBusValue]) async -> RAVEBusResult) {
        actions[action.id] = RegisteredAction(action: action, isAvailable: isAvailable, handler: handler)
    }

    /// Actions that can run now, by id.
    public func availableActions(of module: String? = nil) -> [RAVEBusAction] {
        actions.values
            .filter { module == nil || $0.action.module == module }
            .filter { $0.isAvailable() }
            .map(\.action)
            .sorted { $0.id < $1.id }
    }

    /// Checks the arguments against the action's parameters, then runs it.
    public func invoke(_ id: String, _ arguments: [String: RAVEBusValue] = [:]) async -> RAVEBusResult {
        guard let registered = actions[id] else { return .refused("There is no action \(id).") }
        guard registered.isAvailable() else { return .refused("\(id) isn't possible right now.") }
        if let problem = registered.action.validate(arguments) { return .refused(problem) }
        return await registered.handler(arguments)
    }

    // MARK: Lifecycle

    /// A module left: its feeds forget what it published and its actions go. Readers stay
    /// subscribed, so they hear it again if the module returns.
    public func retire(module: String) {
        for store in stores.values {
            store.samples.removeAll { $0.publisher == module }
            if store.samples.isEmpty { store.lastKept = nil }
        }
        actions = actions.filter { $0.value.action.module != module }
    }

    // MARK: Internals

    private func store<V: Sendable>(for key: RAVEFeedKey<V>) -> Store {
        if let s = stores[key.name] { return s }
        let s = Store(typeID: ObjectIdentifier(V.self), privacy: key.privacy)
        stores[key.name] = s
        return s
    }

    private func trim<V: Sendable>(_ store: Store, key: RAVEFeedKey<V>, at t: TimeInterval) {
        if key.retention <= 0 {
            if store.samples.count > 1 { store.samples.removeFirst(store.samples.count - 1) }
            return
        }
        let cutoff = t - key.retention
        store.samples.removeAll { $0.time < cutoff }
        if store.samples.count > key.retainedLimit {
            store.samples.removeFirst(store.samples.count - key.retainedLimit)
        }
    }

    private func typed<V: Sendable>(_ s: Stored) -> RAVEFeedSample<V>? { Self.typedSample(s) }

    private static func typedSample<V: Sendable>(_ s: Stored) -> RAVEFeedSample<V>? {
        guard let v = s.value as? V else { return nil }
        return RAVEFeedSample(value: v, time: s.time, publisher: s.publisher)
    }
}
