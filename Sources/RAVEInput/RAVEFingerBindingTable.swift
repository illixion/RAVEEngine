/*
 RAVE Engine — the (hand × finger) → action binding table.

 Different apps bind pinches to their own kind of target — one to gameplay
 actions, another to virtual VR-controller inputs. The *targets* have nothing
 in common, so they stay in the apps — but the table around them was
 duplicated line for line: eight slots, one
 of them reserved for the locomotion joystick and rendered locked, `Codable`,
 persisted as one JSON blob in `UserDefaults`, with a `.defaults` value.

 The encoded form is deliberately the same named-field shape both apps already
 have on disk (`rightIndex`, `rightMiddle`, …), so adopting this reads existing
 user settings rather than resetting them. `leftIndex` decodes as optional
 because Longwave's table never stored it — its reserved slot is not a value it
 kept, and a table that refused to decode without it would silently reset every
 user's bindings.
 */

import Foundation

/// An action a pinch can be bound to.
///
/// `unassigned` is required because the reserved joystick slot and any unbound
/// finger must resolve to *something*, and the table should not have to know
/// which of the app's cases means "do nothing".
public protocol RAVEBindableAction: Codable, Equatable, Sendable {
    static var unassigned: Self { get }
}

/// One addressable binding position.
public struct RAVEBindingSlot: Hashable, Sendable {
    public var chirality: RAVEHandChirality
    public var finger: RAVEHandFinger

    public init(_ chirality: RAVEHandChirality, _ finger: RAVEHandFinger) {
        self.chirality = chirality
        self.finger = finger
    }

    /// Every slot, in the order a settings screen lists them.
    public static let all: [RAVEBindingSlot] = RAVEHandChirality.allCases.flatMap { chirality in
        RAVEHandFinger.allCases.map { RAVEBindingSlot(chirality, $0) }
    }
}

/// Persisted map from (hand × finger) pinch to an app-defined action.
public struct RAVEFingerBindingTable<Action: RAVEBindableAction>: Codable, Equatable, Sendable {
    public var rightIndex: Action
    public var rightMiddle: Action
    public var rightRing: Action
    public var rightLittle: Action
    public var leftIndex: Action
    public var leftMiddle: Action
    public var leftRing: Action
    public var leftLittle: Action

    /// The slot held by the locomotion joystick. It always resolves to
    /// `Action.unassigned` and refuses writes, so a settings screen can render
    /// it locked. Not encoded — it is a policy of the app, not a user setting.
    public var reservedSlot: RAVEBindingSlot?

    public init(
        rightIndex: Action,
        rightMiddle: Action,
        rightRing: Action,
        rightLittle: Action,
        leftIndex: Action = .unassigned,
        leftMiddle: Action,
        leftRing: Action,
        leftLittle: Action,
        reservedSlot: RAVEBindingSlot? = RAVEBindingSlot(.left, .index)
    ) {
        self.rightIndex = rightIndex
        self.rightMiddle = rightMiddle
        self.rightRing = rightRing
        self.rightLittle = rightLittle
        self.leftIndex = leftIndex
        self.leftMiddle = leftMiddle
        self.leftRing = leftRing
        self.leftLittle = leftLittle
        self.reservedSlot = reservedSlot
    }

    // MARK: Lookup

    public func action(for slot: RAVEBindingSlot) -> Action {
        guard slot != reservedSlot else { return .unassigned }
        return self[unchecked: slot]
    }

    public func action(for chirality: RAVEHandChirality, finger: RAVEHandFinger) -> Action {
        action(for: RAVEBindingSlot(chirality, finger))
    }

    public mutating func set(_ action: Action, for slot: RAVEBindingSlot) {
        guard slot != reservedSlot else { return }
        self[unchecked: slot] = action
    }

    public mutating func set(
        _ action: Action,
        for chirality: RAVEHandChirality,
        finger: RAVEHandFinger
    ) {
        set(action, for: RAVEBindingSlot(chirality, finger))
    }

    /// True when the slot cannot be edited.
    public func isReserved(_ slot: RAVEBindingSlot) -> Bool {
        slot == reservedSlot
    }

    private subscript(unchecked slot: RAVEBindingSlot) -> Action {
        get {
            switch (slot.chirality, slot.finger) {
            case (.right, .index):  return rightIndex
            case (.right, .middle): return rightMiddle
            case (.right, .ring):   return rightRing
            case (.right, .little): return rightLittle
            case (.left,  .index):  return leftIndex
            case (.left,  .middle): return leftMiddle
            case (.left,  .ring):   return leftRing
            case (.left,  .little): return leftLittle
            }
        }
        set {
            switch (slot.chirality, slot.finger) {
            case (.right, .index):  rightIndex = newValue
            case (.right, .middle): rightMiddle = newValue
            case (.right, .ring):   rightRing = newValue
            case (.right, .little): rightLittle = newValue
            case (.left,  .index):  leftIndex = newValue
            case (.left,  .middle): leftMiddle = newValue
            case (.left,  .ring):   leftRing = newValue
            case (.left,  .little): leftLittle = newValue
            }
        }
    }

    // MARK: Codable
    //
    // Hand-written so `reservedSlot` stays out of the payload and `leftIndex`
    // stays optional on the way in. Both apps' existing blobs decode unchanged.

    private enum CodingKeys: String, CodingKey {
        case rightIndex, rightMiddle, rightRing, rightLittle
        case leftIndex, leftMiddle, leftRing, leftLittle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rightIndex  = try container.decode(Action.self, forKey: .rightIndex)
        rightMiddle = try container.decode(Action.self, forKey: .rightMiddle)
        rightRing   = try container.decode(Action.self, forKey: .rightRing)
        rightLittle = try container.decode(Action.self, forKey: .rightLittle)
        leftIndex   = try container.decodeIfPresent(Action.self, forKey: .leftIndex) ?? .unassigned
        leftMiddle  = try container.decode(Action.self, forKey: .leftMiddle)
        leftRing    = try container.decode(Action.self, forKey: .leftRing)
        leftLittle  = try container.decode(Action.self, forKey: .leftLittle)
        reservedSlot = RAVEBindingSlot(.left, .index)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rightIndex, forKey: .rightIndex)
        try container.encode(rightMiddle, forKey: .rightMiddle)
        try container.encode(rightRing, forKey: .rightRing)
        try container.encode(rightLittle, forKey: .rightLittle)
        try container.encode(leftIndex, forKey: .leftIndex)
        try container.encode(leftMiddle, forKey: .leftMiddle)
        try container.encode(leftRing, forKey: .leftRing)
        try container.encode(leftLittle, forKey: .leftLittle)
    }
}

/// `UserDefaults`-backed persistence for a binding table — one round trip from
/// settings UI to storage to the input loop.
@MainActor
public struct RAVEFingerBindingStore<Action: RAVEBindableAction> {
    public let key: String
    /// Returned when nothing is stored, or when what is stored no longer decodes.
    public let fallback: RAVEFingerBindingTable<Action>
    public let defaults: UserDefaults

    public init(
        key: String,
        fallback: RAVEFingerBindingTable<Action>,
        defaults: UserDefaults = .standard
    ) {
        self.key = key
        self.fallback = fallback
        self.defaults = defaults
    }

    public func load() -> RAVEFingerBindingTable<Action> {
        guard let data = defaults.data(forKey: key),
              var table = try? JSONDecoder().decode(RAVEFingerBindingTable<Action>.self, from: data)
        else { return fallback }
        // The reservation is the app's policy, not the stored blob's.
        table.reservedSlot = fallback.reservedSlot
        return table
    }

    public func save(_ table: RAVEFingerBindingTable<Action>) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: key)
    }
}
