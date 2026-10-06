/*
 RAVE Engine — a physical mouse, as plain events and the arithmetic every
 consumer of one ended up writing.

 Converged from two apps that read `GCMouse` independently: LambdaVision
 (`MouseInput`: buttons and the wheel become engine key events, motion turns
 the view) and Longwave, twice over (`MoonlightMouseManager` forwards to a
 Moonlight host, `MacNativeMouseBridge` drives a streamed Mac's cursor). All
 three agreed on the raw facts and differed only in what they did with them:

   - GCMouse reports motion and the wheel with +Y **up / away from the user**
     (the controller convention). Screen space is +Y down, so a consumer that
     moves a cursor inverts Y; one that turns a view does not. The events here
     keep the raw convention and leave the sign to the app.
   - Motion and the wheel arrive in fractions (a trackpad's wheel, a slow
     drag after a divisor). Truncating each event to an integer drops slow
     movement entirely, so every copy carried the remainder between events:
     `RAVEMouseStepAccumulator`.
   - `GCMouse` knows nothing about the app's UI, so a click on the app's own
     controls also reaches whatever the mouse drives. Both Longwave copies hold
     presses back while the pointer is over their controls, and then had to
     release only what they actually pressed, or a press made over the content
     and released over a control stuck down: `RAVEMouseButtonGate`.
   - visionOS also delivers a physical click as a system pointer event (a
     SwiftUI tap, a spatial event). Consumers that read `GCMouse` stand those
     paths down while a mouse is connected — `RAVEMouseSource.isConnected` and
     the `.connected` / `.disconnected` events are that signal.

 Kept out on purpose, because each is one app's policy: speed divisors and
 acceleration curves, turn sensitivity, wheel-step clamps, menu cursors and
 any wire encoding (Moonlight's button codes and high-res scroll units).

 Isolation: the value types carry none; `RAVEMouseMotionAccumulator` is a
 lock-guarded class so a render thread can drain what the main queue adds.
 */

import Foundation

/// A mouse button, by position. GameController exposes the side buttons as
/// `auxiliaryButtons`; `auxiliary(0)` is the first of them (usually "back").
public enum RAVEMouseButton: Hashable, Sendable {
    case left
    case right
    case middle
    case auxiliary(Int)
}

/// One thing a mouse did. Delivered on the main queue by `RAVEMouseSource`.
public enum RAVEMouseEvent: Equatable, Sendable {
    /// A mouse appeared. `count` is how many are connected now, this one included.
    case connected(vendorName: String?, count: Int)
    /// A mouse went away. `count` is how many are left.
    case disconnected(vendorName: String?, count: Int)
    /// Raw relative motion in device counts, +Y up. Unaccelerated: the
    /// system pointer-speed curve never sees it.
    case moved(dx: Float, dy: Float)
    case button(RAVEMouseButton, pressed: Bool)
    /// One wheel axis changed: about 1.0 per notch on a wheel, fractions on a
    /// trackpad. +Y away from the user. Each event carries one axis; the
    /// other is 0.
    case scroll(x: Float, y: Float)
}

/// Accumulates fractional values and hands out whole steps, carrying the
/// remainder so slow input isn't truncated to nothing. Steps truncate toward
/// zero, so a remainder never exceeds ±1 and a reversal cancels it first.
public struct RAVEMouseStepAccumulator: Equatable, Sendable {
    public private(set) var remainder: Float = 0

    public init() {}

    /// Adds `value` and returns the whole steps now available (signed).
    public mutating func add(_ value: Float) -> Int {
        remainder += value
        let steps = Int(remainder)
        remainder -= Float(steps)
        return steps
    }

    /// Drops the remainder, e.g. so the next gesture starts clean.
    public mutating func reset() { remainder = 0 }
}

/// Which presses were forwarded, so the matching release is forwarded too —
/// and only then. A press is let through only when the caller allows it (the
/// pointer is over the content, the session has focus, the stream is live);
/// its release is always let through, wherever the pointer has gone since, so
/// nothing sticks. A second press of a button already down (two mice) is
/// dropped, so the far end never sees two presses and one release.
public struct RAVEMouseButtonGate: Equatable, Sendable {
    public private(set) var held: Set<RAVEMouseButton> = []

    public init() {}

    /// Whether a press should be forwarded. Records it if so.
    public mutating func press(_ button: RAVEMouseButton, allowed: Bool) -> Bool {
        guard allowed else { return false }
        return held.insert(button).inserted
    }

    /// Whether a release should be forwarded: only if its press was.
    public mutating func release(_ button: RAVEMouseButton) -> Bool {
        held.remove(button) != nil
    }

    /// Everything still down, cleared — for the caller to release when its
    /// target goes away (stream stopped, mouse disconnected, capture off).
    public mutating func releaseAll() -> [RAVEMouseButton] {
        defer { held.removeAll() }
        return Array(held)
    }

    /// Forgets every held button without releasing anything.
    public mutating func clear() { held.removeAll() }
}

/// Motion summed between polls, for a consumer that applies it once a frame on
/// its own thread (a render loop) rather than per event. Lock-guarded: `add`
/// from the main queue, `take` from anywhere.
public final class RAVEMouseMotionAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var dx: Float = 0
    private var dy: Float = 0

    public init() {}

    public func add(dx: Float, dy: Float) {
        lock.lock()
        self.dx += dx
        self.dy += dy
        lock.unlock()
    }

    /// The motion since the last call, in the units added (GCMouse's: +Y up),
    /// and zero after.
    public func take() -> (dx: Float, dy: Float) {
        lock.lock(); defer { lock.unlock() }
        let motion = (dx, dy)
        dx = 0
        dy = 0
        return motion
    }
}
