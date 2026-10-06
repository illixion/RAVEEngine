/*
 RAVE Engine — every connected `GCMouse`, fanned out to whoever listens.

 `GCMouse` is the only way to read a Bluetooth/USB mouse on visionOS: raw
 deltas, physical buttons and the wheel, fired on every motion whether or not
 a button is held, and no pointer capture. It has one gotcha this class
 exists for: each handler on a `GCMouseInput` is a **single slot**. Two parts
 of one app installing their own handlers (Longwave's Moonlight session and
 its Mac desktop bridge) silently steal the mouse from each other — the last
 one to connect wins. So the source owns the slots, once per process
 (`shared`), and hands every event to all subscribers.

 Lifecycle follows the subscribers: the first `subscribe` starts watching for
 connects (and picks up mice already connected), the last `cancel` clears the
 handlers and stops. A new subscriber is first told about every mouse already
 connected (`.connected` for each, counting up), the way each app used to
 walk `GCMouse.mice()` on start.

 Queue: handlers run on the **main queue** (`handlerQueue = .main`, which is
 GameController's default and what every copy relied on), so subscribers are
 `@MainActor` and can touch UI state directly. That is the lifecycle-only
 isolation `RAVESpatialAccessorySource` has; anything a render thread needs
 goes through a lock-guarded type (`RAVEMouseMotionAccumulator`, or
 `isConnected` here, which is nonisolated).

 visionOS: mouse events, like controller events, only flow while the user
 is looking at one of the app's windows (or is in its immersive space).
 */

import Foundation
#if canImport(GameController)
import GameController
#endif

/// Where the mouse events come from. The real one is GameController; tests
/// substitute their own and drive the source's `device…`/`emit` entry points.
@MainActor
protocol RAVEMouseBackend: AnyObject, Sendable {
    func start(_ source: RAVEMouseSource)
    func stop()
}

/// A subscriber's handle. Keep it for as long as the events are wanted and
/// `cancel()` it when done; it does not cancel itself on deinit.
@MainActor
public final class RAVEMouseSubscription {
    private weak var source: RAVEMouseSource?
    let id: Int

    init(source: RAVEMouseSource, id: Int) {
        self.source = source
        self.id = id
    }

    /// Stops delivery to this subscriber. Idempotent.
    public func cancel() {
        source?.unsubscribe(id)
        source = nil
    }
}

@MainActor
public final class RAVEMouseSource {
    /// The process-wide source. Use this one: a second source over the same
    /// mice would fight it for the handler slots.
    nonisolated public static let shared = RAVEMouseSource(backend: RAVEMouseSource.defaultBackend())

    nonisolated private let backend: RAVEMouseBackend
    private var subscribers: [(id: Int, handler: @MainActor (RAVEMouseEvent) -> Void)] = []
    private var nextID = 0
    private var running = false
    /// Connected devices, in connection order, with their vendor names.
    private var devices: [(id: ObjectIdentifier, vendorName: String?)] = []

    nonisolated private let countLock = NSLock()
    nonisolated(unsafe) private var _count = 0

    /// Nonisolated so `shared` can be first touched from any thread; every
    /// backend call still happens on main.
    nonisolated init(backend: RAVEMouseBackend) {
        self.backend = backend
    }

    /// How many mice are connected. Safe from any thread.
    nonisolated public var connectedCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return _count
    }

    /// Whether any mouse is connected — the signal to stand down system
    /// pointer paths that would deliver the same click a second time. Safe
    /// from any thread. Only maintained while someone is subscribed.
    nonisolated public var isConnected: Bool { connectedCount > 0 }

    /// Delivers every mouse event to `handler`, on the main queue, starting
    /// with a `.connected` for each mouse already connected.
    @discardableResult
    public func subscribe(_ handler: @escaping @MainActor (RAVEMouseEvent) -> Void) -> RAVEMouseSubscription {
        let id = nextID
        nextID += 1
        subscribers.append((id, handler))
        if !running {
            running = true
            backend.start(self)   // reports existing mice to everyone, this one included
        } else {
            for (i, device) in devices.enumerated() {
                handler(.connected(vendorName: device.vendorName, count: i + 1))
            }
        }
        return RAVEMouseSubscription(source: self, id: id)
    }

    func unsubscribe(_ id: Int) {
        subscribers.removeAll { $0.id == id }
        guard subscribers.isEmpty, running else { return }
        running = false
        backend.stop()
        devices.removeAll()
        setCount(0)
    }

    // MARK: Backend entry points

    func deviceConnected(_ id: ObjectIdentifier, vendorName: String?) {
        guard !devices.contains(where: { $0.id == id }) else { return }
        devices.append((id, vendorName))
        setCount(devices.count)
        emit(.connected(vendorName: vendorName, count: devices.count))
    }

    func deviceDisconnected(_ id: ObjectIdentifier) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let name = devices.remove(at: index).vendorName
        setCount(devices.count)
        emit(.disconnected(vendorName: name, count: devices.count))
    }

    func emit(_ event: RAVEMouseEvent) {
        // Snapshot: a handler may cancel itself (or subscribe another) mid-loop.
        for subscriber in subscribers { subscriber.handler(event) }
    }

    private func setCount(_ count: Int) {
        countLock.lock()
        _count = count
        countLock.unlock()
    }

    nonisolated private static func defaultBackend() -> RAVEMouseBackend {
        #if canImport(GameController)
        RAVEGameControllerMouseBackend()
        #else
        RAVENoMouseBackend()
        #endif
    }
}

/// No mouse support on this platform: never reports anything.
final class RAVENoMouseBackend: RAVEMouseBackend {
    nonisolated init() {}
    func start(_ source: RAVEMouseSource) {}
    func stop() {}
}

#if canImport(GameController)
/// The real backend: `GCMouseDidConnect` / `GCMouseDidDisconnect` plus the
/// per-device handler slots.
final class RAVEGameControllerMouseBackend: RAVEMouseBackend {
    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []

    nonisolated init() {}

    func start(_ source: RAVEMouseSource) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self, weak source] note in
            // Posted on the main queue (`queue: .main`), so the device never
            // leaves the thread it is used on.
            guard let device = note.object as? GCMouse else { return }
            nonisolated(unsafe) let mouse = device
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                self.attach(mouse, to: source)
            }
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self, weak source] note in
            // Posted on the main queue (`queue: .main`), so the device never
            // leaves the thread it is used on.
            guard let device = note.object as? GCMouse else { return }
            nonisolated(unsafe) let mouse = device
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                self.detach(mouse, from: source)
            }
        })
        for mouse in GCMouse.mice() { attach(mouse, to: source) }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for mouse in mice { Self.clearHandlers(mouse) }
        mice.removeAll()
    }

    private func attach(_ mouse: GCMouse, to source: RAVEMouseSource) {
        guard !mice.contains(where: { $0 === mouse }), let input = mouse.mouseInput else { return }
        mice.append(mouse)
        mouse.handlerQueue = .main
        Self.setHandlers(input, source: source)
        source.deviceConnected(ObjectIdentifier(mouse), vendorName: mouse.vendorName)
    }

    private func detach(_ mouse: GCMouse, from source: RAVEMouseSource) {
        Self.clearHandlers(mouse)
        mice.removeAll { $0 === mouse }
        source.deviceDisconnected(ObjectIdentifier(mouse))
    }

    // Built nonisolated so the closures aren't inferred MainActor-isolated;
    // they hop in explicitly, which holds because `handlerQueue` is main.
    nonisolated private static func setHandlers(_ input: GCMouseInput, source: RAVEMouseSource) {
        input.mouseMovedHandler = { [weak source] _, dx, dy in
            MainActor.assumeIsolated { source?.emit(.moved(dx: dx, dy: dy)) }
        }
        input.leftButton.pressedChangedHandler = button(.left, source)
        input.rightButton?.pressedChangedHandler = button(.right, source)
        input.middleButton?.pressedChangedHandler = button(.middle, source)
        if let aux = input.auxiliaryButtons {
            for (i, b) in aux.enumerated() {
                b.pressedChangedHandler = button(.auxiliary(i), source)
            }
        }
        input.scroll.yAxis.valueChangedHandler = { [weak source] _, value in
            MainActor.assumeIsolated { source?.emit(.scroll(x: 0, y: value)) }
        }
        input.scroll.xAxis.valueChangedHandler = { [weak source] _, value in
            MainActor.assumeIsolated { source?.emit(.scroll(x: value, y: 0)) }
        }
    }

    nonisolated private static func button(
        _ button: RAVEMouseButton, _ source: RAVEMouseSource
    ) -> GCControllerButtonValueChangedHandler {
        { [weak source] _, _, pressed in
            MainActor.assumeIsolated { source?.emit(.button(button, pressed: pressed)) }
        }
    }

    nonisolated private static func clearHandlers(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
        input.scroll.xAxis.valueChangedHandler = nil
        input.scroll.yAxis.valueChangedHandler = nil
    }
}
#endif
