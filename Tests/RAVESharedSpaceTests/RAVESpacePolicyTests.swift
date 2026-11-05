import Testing
@testable import RAVESharedSpace

@Suite struct RAVESpacePolicyTests {
    @Test func nobodyMeansNoSpace() {
        #expect(RAVESpacePolicy.resolve([]) == nil)
    }

    @Test func immersionFollowsTheNewest() throws {
        let resolved = try #require(RAVESpacePolicy.resolve([
            ("character", .init(immersion: .full)),
            ("cinema", .init(immersion: .mixed)),
        ]))
        #expect(resolved.immersion == .mixed)
        #expect(resolved.members == ["character", "cinema"])
    }

    @Test func armsHideIfAnyoneHidesThem() throws {
        let resolved = try #require(RAVESpacePolicy.resolve([
            ("pcvr", .init(hidesUpperLimbs: true)),
            ("character", .init()),
        ]))
        #expect(resolved.upperLimbsHidden)
    }

    @Test func surroundingsFollowTheNewestWithAPreference() throws {
        let resolved = try #require(RAVESpacePolicy.resolve([
            ("cinema", .init(surroundings: .systemDark)),
            ("character", .init()),
        ]))
        #expect(resolved.surroundings == .systemDark)
        let dimmer = try #require(RAVESpacePolicy.resolve([
            ("cinema", .init(surroundings: .systemDark)),
            ("reader", .init(surroundings: .dim(intensity: 0.5))),
        ]))
        #expect(dimmer.surroundings == .dim(intensity: 0.5))
    }

    @Test func handsRunIfAnyoneNeedsThem() throws {
        let resolved = try #require(RAVESpacePolicy.resolve([("a", .init(needsHands: true)), ("b", .init())]))
        #expect(resolved.needsHands)
    }
}

@Suite @MainActor struct RAVESpaceBrokerTests {
    /// A fake space: opens when asked, records calls.
    final class FakeSpace {
        var opens = 0, dismissals = 0
    }

    private func broker(_ space: FakeSpace) -> RAVESpaceBroker {
        let broker = RAVESpaceBroker()
        broker.openSpace = { space.opens += 1; return true }
        broker.dismissSpace = { space.dismissals += 1 }
        return broker
    }

    @Test func updatingKeepsTheOrderSoImmersionStaysWithTheNewest() {
        let broker = broker(FakeSpace())
        broker.request("character", .init(immersion: .mixed))
        broker.request("cinema", .init(immersion: .full))
        broker.update("character", .init(immersion: .mixed, surroundings: .tint(red: 1, green: 0.2, blue: 0.2)))
        #expect(broker.members == ["character", "cinema"])
        #expect(broker.resolution?.immersion == .full)
        #expect(broker.resolution?.surroundings == .tint(red: 1, green: 0.2, blue: 0.2))
        broker.update("absent", .init(immersion: .full))
        #expect(broker.members == ["character", "cinema"])
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func opensForTheFirstAndClosesAfterTheLast() async {
        let space = FakeSpace()
        let broker = broker(space)
        broker.request("a")
        broker.request("b")
        await settle()
        #expect(space.opens == 1)
        #expect(broker.phase == .open)
        broker.release("a")
        await settle()
        #expect(space.dismissals == 0)
        broker.release("b")
        await settle()
        #expect(space.dismissals == 1)
        #expect(broker.phase == .closed)
    }

    @Test func askingAgainMakesAModuleTheNewest() {
        let broker = broker(FakeSpace())
        broker.request("a", .init(immersion: .full))
        broker.request("b")
        broker.request("a", .init(immersion: .full))
        #expect(broker.members == ["b", "a"])
        #expect(broker.resolution?.immersion == .full)
    }

    @Test func aSpaceClosedByTheSystemTellsEveryMember() async {
        let space = FakeSpace()
        let broker = broker(space)
        var told: [String] = []
        broker.onTakenAway = { told = $0 }
        broker.request("a")
        broker.request("b")
        await settle()
        broker.spaceDidAppear()
        broker.spaceDidDisappear()
        #expect(told == ["a", "b"])
        #expect(broker.members.isEmpty)
        #expect(broker.phase == .closed)
    }

    @Test func aClosingAfterTheLastReleaseIsNotATakeaway() async {
        let broker = broker(FakeSpace())
        var told: [String]?
        broker.onTakenAway = { told = $0 }
        broker.request("a")
        await settle()
        broker.release("a")
        await settle()
        broker.spaceDidDisappear()
        #expect(told == nil)
    }

    @Test func aRefusedOpenSaysSo() async {
        let broker = RAVESpaceBroker()
        broker.openSpace = { false }
        broker.request("a")
        await settle()
        #expect(broker.phase == .closed)
        #expect(broker.lastError != nil)
    }
}
