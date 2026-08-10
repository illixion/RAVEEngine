/*
 RAVE Engine — controller acquisition, and the visionOS gotcha that goes with it.

 Two apps discovered the same trap independently and wrote the same comment
 about it: on visionOS a `GCController` you merely *read* is not yours. Unless
 you register as a persistent consumer — set a player index and install a
 `valueChangedHandler`, even an empty one — the system keeps the pad for focus
 navigation, and polled values freeze the moment a stick is released. The other
 half of the fix lives in the app: `.handlesGameControllerEvents(matching: .gamepad)`
 on the view hosting the immersive content. Both halves are required.

 Deliberately not `Sendable`: each input loop owns one of these and polls it
 from its own thread — the main actor in one app, the render thread in another —
 and the whole point of the package is that neither has to convert.
 */

import GameController

/// Acquires whichever extended gamepad is current and claims it once per
/// connection.
public final class RAVEGamepadSource {

    /// Called once each time a new controller is claimed. Apps use it to log the
    /// connection; nothing in the poll path depends on it.
    public var onClaim: ((GCController) -> Void)?

    private weak var claimed: GCController?

    public init(onClaim: ((GCController) -> Void)? = nil) {
        self.onClaim = onClaim
    }

    /// The current controller, claiming it if it is new. Cheap enough to call
    /// every frame — `GCController` state reads are snapshot-based.
    @discardableResult
    public func controller() -> GCController? {
        // `GCController.current` stays nil until a pad becomes "current", so
        // fall back to the first connected one.
        let controller = GCController.current ?? GCController.controllers().first
        if let controller, controller !== claimed {
            claimed = controller
            controller.playerIndex = .index1
            // Registering *any* handler is what makes us a persistent input
            // consumer. It is intentionally empty — we poll.
            controller.extendedGamepad?.valueChangedHandler = { _, _ in }
            onClaim?(controller)
        }
        return controller
    }

    /// The current extended gamepad, or nil when nothing suitable is connected.
    public func extendedGamepad() -> GCExtendedGamepad? {
        controller()?.extendedGamepad
    }

    /// True while an extended gamepad is connected. Apps use this to suppress
    /// hand *action* gestures so a pad and hand tracking can coexist.
    public var isGamepadConnected: Bool {
        extendedGamepad() != nil
    }
}
