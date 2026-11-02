/*
 RAVE Engine — the gun hand's two thumb gestures, and how they are told apart.

 Free of ARKit and of any game: the caller measures one frame of the hand
 (`RAVEThumbGestures.Input`, plain numbers) and reads back two buttons.

 - **Reload:** curl the thumb down (thumb tip ↔ index knuckle, over palm
   length, below `thumbCurlOn`) with the index extended, and hold for
   `reloadHoldSeconds` while a ring fills (`reloadRing`, 0…1).

 - **Alt-fire:** touch the thumb tip to the side of the middle finger, the side
   nearest the thumb, and hold it there. The thumb moves on its own muscles, so
   the aim stays put. Contact is measured from the thumb tip to the middle
   finger's radial side: the polyline knuckle → intermediate base →
   intermediate tip, shifted `radialOffset` toward the index knuckle (ARKit
   joints sit on the bone's centre line). The closest point's position along it
   is `along`: 0 at the knuckle, 1 at the intermediate base, 2 at the
   intermediate tip. See `RAVEThumbContact.measure`.

 **How the two are told apart.** Both are a thumb moving down with the index
 out, and in a finger gun the curled middle finger's knuckle sits right beside
 the index knuckle the reload metric measures to, so distance alone cannot
 separate them. The rules:

 1. *Where on the middle finger.* A reload curl ends at the index knuckle, next
    to the middle knuckle, so it reads `along` ≈ 0. Contact only counts at
    `along ≥ minAlong` (past the middle of the proximal phalanx), where a curl
    in place does not reach.
 2. *Three zones:* contact (closer than `contactOn`), near (closer than
    `contactOff`, the hysteresis band) and clear. Alt-fire engages only after
    `settleSeconds` in contact. Near or in contact, the reload hold is vetoed
    (its timer resets, the ring goes away), so the ring can never complete
    while the thumb is on the middle finger.
 3. *Each locks the other out* until the thumb re-extends (thumb ratio above
    `thumbCurlOff`): a reload that fired blocks alt-fire, and an alt-fire that
    was pressed blocks the reload hold.
 4. *Ambiguous:* the thumb reaches the middle finger after a reload hold has
    already run for `reloadPathGrace` (the ring was visibly filling, so a
    reload was meant). Then neither fires until the thumb leaves the middle
    finger. A quick thumb move to the middle finger passes through the reload
    curl on the way, which is why there is a grace at all.

 **Guards for alt-fire, so a fist or a pinch cannot press it:**
 - the index must be extended (ratio above `indexExtended`) when it engages.
   Once held, a trigger pull keeps it down, so fire and alt-fire together are
   both buttons held. A fist (index curled, thumb wrapped over the middle
   finger) therefore never starts it.
 - the thumb tip must be at least `pinchGuard` from the index tip, which rules
   out a movement pinch (thumb to index tip, 2.5 cm) and a whole-hand "all
   tips near the thumb" wheel gesture (every tip within 5.5 cm of the thumb),
   whichever hand makes them.

 The caller passes `nil` while the gestures may not run (a menu is open, an
 arm swing owns the hand, the hand is lost) and both release at once.

 **Press and hold:** `altFire` is down for as long as contact holds, so a
 weapon that charges while held works and a tap is a tap. A press lasts at
 least `minHoldSeconds` (a game frame has to see it) and releases after
 `releaseSeconds` clear of the middle finger, so tracking jitter does not drop
 a charge early.
 */

import Foundation
import simd

public enum RAVEThumbContact {
    /// Thumb tip → middle finger radial side: the distance (m) and where along
    /// the finger the closest point lies (0 knuckle, 1 intermediate base, 2
    /// intermediate tip). `towardIndex` is the index knuckle; the line is
    /// shifted `radialOffset` toward it from the middle knuckle.
    public static func measure(
        thumbTip p: SIMD3<Float>,
        knuckle: SIMD3<Float>, intermediateBase: SIMD3<Float>,
        intermediateTip: SIMD3<Float>, towardIndex: SIMD3<Float>,
        radialOffset: Float
    ) -> (distance: Float, along: Float) {
        let side = towardIndex - knuckle
        let shift = simd_length(side) > 1e-5 ? simd_normalize(side) * radialOffset : .zero
        let a = knuckle + shift, b = intermediateBase + shift, c = intermediateTip + shift
        let (d1, t1) = segment(p, a, b)
        let (d2, t2) = segment(p, b, c)
        return d1 <= d2 ? (d1, t1) : (d2, 1 + t2)
    }

    /// Distance from `p` to segment a–b, and the closest point's 0…1 position.
    public static func segment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (Float, Float) {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        let t = len2 > 1e-10 ? min(max(simd_dot(p - a, ab) / len2, 0), 1) : 0
        return (simd_distance(p, a + ab * t), t)
    }
}

public struct RAVEThumbGestures: Sendable, Equatable {
    public struct Tuning: Sendable, Equatable {
        // Reload.
        /// Thumb ratio below this → the hold begins.
        public var thumbCurlOn: Float = 0.45
        /// Above this → the hold cancels and the locks clear.
        public var thumbCurlOff: Float = 0.60
        public var reloadHoldSeconds: Double = 0.75
        // Finger-gun index.
        /// Below: the trigger is pulled.
        public var indexCurled: Float = 0.55
        /// Above: the index is out (finger gun).
        public var indexExtended: Float = 0.75
        // Alt-fire.
        /// Alt-fire can be switched off outright.
        public var altFire = true
        /// m, thumb tip ↔ radial side to press.
        public var contactOn: Float = 0.020
        /// m, past this (after `releaseSeconds`) it releases.
        public var contactOff: Float = 0.032
        /// Contact only counts past the middle of the proximal phalanx.
        public var minAlong: Float = 0.5
        /// `along` may drop this far while held.
        public var alongSlack: Float = 0.10
        /// In contact this long before it presses.
        public var settleSeconds: Double = 0.05
        /// Clear this long before it releases.
        public var releaseSeconds: Double = 0.05
        /// A press lasts at least this long.
        public var minHoldSeconds: Double = 0.06
        /// m, the thumb tip must be this far from the index tip.
        public var pinchGuard: Float = 0.06
        /// A reload hold older than this makes contact ambiguous.
        public var reloadPathGrace: Double = 0.3

        public init() {}
    }

    /// One frame of the gun hand, measured by the caller.
    public struct Input: Sendable, Equatable {
        /// Index tip ↔ knuckle, over palm length.
        public var indexExt: Float
        /// Thumb tip ↔ index knuckle, over palm length.
        public var thumbExt: Float
        /// m, `RAVEThumbContact.measure` distance.
        public var contact: Float
        /// `RAVEThumbContact.measure` position along the middle finger.
        public var along: Float
        /// m, thumb tip to index tip.
        public var thumbToIndexTip: Float

        public init(indexExt: Float, thumbExt: Float, contact: Float, along: Float, thumbToIndexTip: Float) {
            self.indexExt = indexExt
            self.thumbExt = thumbExt
            self.contact = contact
            self.along = along
            self.thumbToIndexTip = thumbToIndexTip
        }
    }

    public enum AltState: String, Sendable {
        case off = "off", idle = "—", noIndex = "index curled", pinch = "pinch guard",
             near = "near", settle = "settle", held = "HELD", releasing = "release",
             lockedReload = "locked (reload)", ambiguous = "ambiguous"
    }

    /// The alt-fire button should be down.
    public private(set) var altFire = false
    /// The reload button should be down (from the hold completing until the
    /// thumb re-extends).
    public private(set) var reload = false
    /// The reload ring this frame (0 = none).
    public private(set) var reloadRing: Float = 0
    public private(set) var altState: AltState = .idle
    /// Reload is locked until the thumb re-extends (an alt-fire was pressed).
    public private(set) var reloadLocked = false

    private var reloadStart: Double?
    private var reloadLatched = false
    /// A reload fired; cleared when the thumb re-extends.
    private var altLocked = false
    private var wasNear = false
    private var ambiguous = false
    private var contactSince: Double?
    private var clearSince: Double?
    private var pressedAt: Double = 0

    public init() {}

    public mutating func reset() {
        self = RAVEThumbGestures()
    }

    /// Advance one frame. `nil` input = the gestures may not run: everything
    /// releases at once.
    public mutating func update(_ input: Input?, now: Double, tuning t: Tuning) {
        guard let h = input else {
            reset()
            if !t.altFire { altState = .off }
            return
        }
        let thumbOut = h.thumbExt > t.thumbCurlOff
        if thumbOut { reloadLocked = false; altLocked = false }

        // Alt-fire geometry, with hysteresis while it is pressed or settling.
        var near = false
        if t.altFire {
            let engaged = altFire || contactSince != nil
            let minAlong = engaged ? t.minAlong - t.alongSlack : t.minAlong
            let onFinger = h.along >= minAlong
            let contact = onFinger && h.contact < t.contactOn
            near = onFinger && h.contact < t.contactOff
            if near, !wasNear, !reloadLatched, let s = reloadStart, now - s > t.reloadPathGrace {
                ambiguous = true
            }
            if !near { ambiguous = false }
            wasNear = near

            if altFire {
                if near {
                    clearSince = nil
                    altState = .held
                } else {
                    if clearSince == nil { clearSince = now }
                    if now - (clearSince ?? now) >= t.releaseSeconds, now - pressedAt >= t.minHoldSeconds {
                        altFire = false
                        clearSince = nil
                        reloadLocked = !thumbOut
                        altState = .idle
                    } else {
                        altState = .releasing
                    }
                }
            } else {
                let indexOut = h.indexExt > t.indexExtended
                let pinchFree = h.thumbToIndexTip > t.pinchGuard
                if !contact || !indexOut || !pinchFree || altLocked || ambiguous {
                    contactSince = nil
                    altState = !near ? .idle
                        : ambiguous ? .ambiguous
                        : altLocked ? .lockedReload
                        : !indexOut ? .noIndex
                        : !pinchFree ? .pinch : .near
                } else {
                    if contactSince == nil { contactSince = now }
                    if now - (contactSince ?? now) >= t.settleSeconds {
                        altFire = true
                        pressedAt = now
                        contactSince = nil
                        altState = .held
                    } else {
                        altState = .settle
                    }
                }
            }
        } else {
            altFire = false
            contactSince = nil
            wasNear = false
            ambiguous = false
            altState = .off
        }

        // Reload hold, plus the veto and the lock.
        var hold = reloadStart != nil
        if h.indexExt < t.indexCurled {
            hold = false        // trigger pulled — never reload mid-fire
        } else if h.thumbExt < t.thumbCurlOn, h.indexExt > t.indexExtended {
            hold = true
        } else if thumbOut {
            hold = false
        }
        // else: inside a hysteresis band — keep the current state.
        if !reloadLatched, near || altFire || reloadLocked { hold = false }
        if hold {
            if reloadStart == nil { reloadStart = now }
            let progress = Float(min((now - (reloadStart ?? now)) / t.reloadHoldSeconds, 1.0))
            if progress >= 1, !reloadLatched {
                reloadLatched = true
                altLocked = true
                reload = true
            }
            // Hide the ring once fired: the full ring vanishing is the "it
            // took" cue, and holding longer must not re-arm.
            reloadRing = reloadLatched ? 0 : progress
        } else {
            reloadStart = nil
            reloadLatched = false
            reloadRing = 0
            reload = false
        }
    }
}
