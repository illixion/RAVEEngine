import Foundation
import Testing
@testable import RAVEInput

private enum TestAction: String, RAVEBindableAction, CaseIterable {
    case none, fire, jump, menu
    static var unassigned: TestAction { .none }
}

private func table() -> RAVEFingerBindingTable<TestAction> {
    RAVEFingerBindingTable(
        rightIndex: .fire,
        rightMiddle: .jump,
        rightRing: .menu,
        rightLittle: .none,
        leftMiddle: .jump,
        leftRing: .menu,
        leftLittle: .fire
    )
}

@Suite("Finger binding table")
struct RAVEFingerBindingTableTests {

    @Test("Every non-reserved slot round-trips through lookup")
    func lookup() {
        let bindings = table()
        #expect(bindings.action(for: .right, finger: .index) == .fire)
        #expect(bindings.action(for: .right, finger: .little) == .none)
        #expect(bindings.action(for: .left, finger: .little) == .fire)
    }

    @Test("The reserved joystick slot always reads unassigned and refuses writes")
    func reservationIsEnforced() {
        var bindings = table()
        #expect(bindings.isReserved(RAVEBindingSlot(.left, .index)))
        #expect(bindings.action(for: .left, finger: .index) == .none)

        bindings.set(.fire, for: .left, finger: .index)
        #expect(bindings.action(for: .left, finger: .index) == .none)
    }

    @Test("Clearing the reservation makes the slot ordinary")
    func reservationIsPolicy() {
        var bindings = table()
        bindings.reservedSlot = nil
        bindings.set(.fire, for: .left, finger: .index)
        #expect(bindings.action(for: .left, finger: .index) == .fire)
    }

    @Test("Encoding uses the named-field shape both apps already have on disk")
    func encodedShape() throws {
        let data = try JSONEncoder().encode(table())
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(json.keys) == [
            "rightIndex", "rightMiddle", "rightRing", "rightLittle",
            "leftIndex", "leftMiddle", "leftRing", "leftLittle",
        ])
        // The reservation is app policy, not a stored setting.
        #expect(json["reservedSlot"] == nil)
    }

    @Test("A blob without leftIndex still decodes — Longwave never stored it")
    func decodesLegacyBlobMissingLeftIndex() throws {
        let legacy = """
        {"rightIndex":"fire","rightMiddle":"jump","rightRing":"menu","rightLittle":"none",
         "leftMiddle":"jump","leftRing":"menu","leftLittle":"fire"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RAVEFingerBindingTable<TestAction>.self, from: legacy)
        #expect(decoded.leftIndex == .none)
        #expect(decoded.action(for: .right, finger: .index) == .fire)
        #expect(decoded.action(for: .left, finger: .little) == .fire)
    }

    @Test("A round trip preserves every binding")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(table())
        let decoded = try JSONDecoder().decode(RAVEFingerBindingTable<TestAction>.self, from: data)
        #expect(decoded == table())
    }

    @Test("All eight slots are enumerable for a settings screen")
    func slotEnumeration() {
        #expect(RAVEBindingSlot.all.count == 8)
        #expect(Set(RAVEBindingSlot.all).count == 8)
    }
}

@MainActor
@Suite("Binding persistence")
struct RAVEFingerBindingStoreTests {

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "rave.tests.\(name)")!
        defaults.removePersistentDomain(forName: "rave.tests.\(name)")
        return defaults
    }

    @Test("An empty store returns the fallback")
    func emptyStoreFallsBack() {
        let store = RAVEFingerBindingStore(
            key: "bindings.v1",
            fallback: table(),
            defaults: scratchDefaults("empty")
        )
        #expect(store.load() == table())
    }

    @Test("Saved bindings survive a reload, and the reservation is re-applied")
    func savesAndLoads() {
        let store = RAVEFingerBindingStore(
            key: "bindings.v1",
            fallback: table(),
            defaults: scratchDefaults("roundtrip")
        )
        var edited = table()
        edited.set(.menu, for: .right, finger: .index)
        store.save(edited)

        let loaded = store.load()
        #expect(loaded.action(for: .right, finger: .index) == .menu)
        #expect(loaded.reservedSlot == RAVEBindingSlot(.left, .index))
    }

    @Test("An undecodable blob falls back instead of throwing away input")
    func corruptBlobFallsBack() {
        let defaults = scratchDefaults("corrupt")
        defaults.set(Data("not json".utf8), forKey: "bindings.v1")
        let store = RAVEFingerBindingStore(
            key: "bindings.v1",
            fallback: table(),
            defaults: defaults
        )
        #expect(store.load() == table())
    }
}

@Suite("Edge tracker")
struct RAVEEdgeTrackerTests {

    @Test("Press and release each report once")
    func edges() {
        var tracker = RAVEEdgeTracker<String>()
        let press = tracker.update("jump", pressed: true)
        let hold = tracker.update("jump", pressed: true)
        let heldMidway = tracker.isHeld("jump")
        let release = tracker.update("jump", pressed: false)
        let idle = tracker.update("jump", pressed: false)
        #expect(press == .began)
        #expect(hold == .steady)
        #expect(heldMidway)
        #expect(release == .ended)
        #expect(idle == .steady)
        #expect(!tracker.isHeld("jump"))
    }

    @Test("Keys are independent")
    func keysAreIndependent() {
        var tracker = RAVEEdgeTracker<String>()
        let firstA = tracker.pressed("a", true)
        let firstB = tracker.pressed("b", true)
        let secondA = tracker.pressed("a", true)
        #expect(firstA)
        #expect(firstB)
        #expect(!secondA)
        #expect(tracker.isHeld("b"))
    }

    @Test("Reset re-arms a still-held key")
    func resetRearms() {
        var tracker = RAVEEdgeTracker<String>()
        let first = tracker.pressed("fire", true)
        tracker.reset()
        let afterReset = tracker.pressed("fire", true)
        #expect(first)
        #expect(afterReset)
    }
}
