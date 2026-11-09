import Foundation
import Testing
import simd
@testable import RAVEModuleBus

@MainActor
private final class FakeClock {
    var t: TimeInterval = 100
    func advance(_ s: TimeInterval) { t += s }
}

@MainActor
private final class FakePlayer: RAVEMediaControlling {
    var isPlaying = false
    var hasMedia = true
    var canPlayNext = false
    var skipped: [TimeInterval] = []
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func skip(by seconds: TimeInterval) { skipped.append(seconds) }
    func playNext() {}
}

@MainActor
private func makeBus() -> (RAVEModuleBus, FakeClock) {
    let clock = FakeClock()
    return (RAVEModuleBus(clock: { clock.t }), clock)
}

private let counter = RAVEFeedKey<Int>("test.counter", minInterval: 1)
private let cues = RAVEFeedKey<String>("test.cues", retention: 10, retainedLimit: 3)

@MainActor
@Suite struct RAVEFeedTests {
    @Test func latestIsTheNewestPublish() {
        let (bus, clock) = makeBus()
        #expect(bus.latest(counter) == nil)
        bus.publish(counter, 1, from: "a")
        clock.advance(2)
        bus.publish(counter, 2, from: "a")
        #expect(bus.latest(counter)?.value == 2)
        #expect(bus.latest(counter)?.publisher == "a")
    }

    @Test func publishesSoonerThanTheIntervalAreDropped() {
        let (bus, clock) = makeBus()
        #expect(bus.publish(counter, 1, from: "a"))
        clock.advance(0.5)
        #expect(!bus.publish(counter, 2, from: "a"))
        #expect(bus.latest(counter)?.value == 1)
        #expect(bus.publish(counter, 3, from: "a", force: true))
        #expect(bus.latest(counter)?.value == 3)
        clock.advance(1)
        #expect(bus.publish(counter, 4, from: "a"))
    }

    @Test func windowKeepsRecentSamplesOldestFirstAndHonoursTheCaps() {
        let (bus, clock) = makeBus()
        for word in ["one", "two", "three", "four"] {
            bus.publish(cues, word, from: "a")
            clock.advance(2)
        }
        // The cap of 3 dropped "one".
        #expect(bus.window(cues, last: 100).map(\.value) == ["two", "three", "four"])
        // "four" was published 2 s ago ("three" 4 s ago), so a 3 s window holds only "four".
        #expect(bus.window(cues, last: 3).map(\.value) == ["four"])
        clock.advance(20)
        bus.publish(cues, "five", from: "a")
        // Retention (10 s) expired everything older.
        #expect(bus.window(cues, last: 100).map(\.value) == ["five"])
    }

    @Test func aFeedWithoutRetentionKeepsOnlyTheLatest() {
        let (bus, _) = makeBus()
        let k = RAVEFeedKey<Int>("test.single", minInterval: 0)
        bus.publish(k, 1, from: "a")
        bus.publish(k, 2, from: "a")
        #expect(bus.window(k, last: 100).map(\.value) == [2])
    }

    @Test func subscribersGetTheLatestFirstThenEachPublish() {
        let (bus, clock) = makeBus()
        bus.publish(counter, 1, from: "a")
        clock.advance(2)
        var seen: [Int] = []
        let sub = bus.subscribe(counter) { seen.append($0.value) }
        #expect(seen == [1])
        bus.publish(counter, 2, from: "a")
        #expect(seen == [1, 2])
        sub.cancel()
        clock.advance(2)
        bus.publish(counter, 3, from: "a")
        #expect(seen == [1, 2])
    }

    @Test func retiringAModuleForgetsItsSamplesButKeepsSubscribers() {
        let (bus, clock) = makeBus()
        var seen: [Int] = []
        bus.subscribe(counter) { seen.append($0.value) }
        bus.publish(counter, 1, from: "player")
        bus.retire(module: "player")
        #expect(bus.latest(counter) == nil)
        clock.advance(2)
        bus.publish(counter, 2, from: "player")
        #expect(seen == [1, 2])
    }

    @Test func retiringOneModuleLeavesAnothersSamples() {
        let (bus, _) = makeBus()
        let k = RAVEFeedKey<String>("test.both", retention: 60)
        bus.publish(k, "from a", from: "a")
        bus.publish(k, "from b", from: "b")
        bus.retire(module: "a")
        #expect(bus.window(k, last: 60).map(\.value) == ["from b"])
    }

    @Test func liveFeedsListOnlyFeedsWithContent() {
        let (bus, _) = makeBus()
        bus.subscribe(counter) { _ in }
        #expect(bus.liveFeeds.isEmpty)
        bus.publish(RAVEMediaFeeds.nowPlaying, RAVENowPlaying(title: "T"), from: "hypnos")
        #expect(bus.liveFeeds.map(\.name) == ["media.nowPlaying"])
        #expect(bus.liveFeeds.first?.privacy == .personalText)
    }
}

@MainActor
@Suite struct RAVEActionTests {
    private let seek = RAVEBusAction(
        id: "t.seek", module: "m", summary: "Seek",
        parameters: [
            RAVEBusParameter("seconds", .number(range: -10...10), doc: "How far"),
            RAVEBusParameter("mode", .string(choices: ["by", "to"]), doc: "Relative or absolute", required: false),
        ])

    @Test func validationNamesTheProblem() {
        #expect(seek.validate(["seconds": .number(5)]) == nil)
        #expect(seek.validate([:])?.contains("needs seconds") == true)
        #expect(seek.validate(["seconds": .number(50)])?.contains("within") == true)
        #expect(seek.validate(["seconds": .string("5")])?.contains("wrong type") == true)
        #expect(seek.validate(["seconds": .number(1), "mode": .string("sideways")])?.contains("one of") == true)
        #expect(seek.validate(["seconds": .number(1), "extra": .bool(true)])?.contains("no parameter") == true)
        #expect(seek.validate(["seconds": .number(.nan)]) != nil)
    }

    @Test func invokeRunsAValidActionAndRefusesOthers() async {
        let (bus, _) = makeBus()
        var got: Double?
        bus.register(seek) { args in
            got = args["seconds"]?.number
            return .done("ok")
        }
        #expect(await bus.invoke("t.seek", ["seconds": .number(3)]) == .done("ok"))
        #expect(got == 3)
        #expect(await bus.invoke("t.seek", ["seconds": .number(99)]).succeeded == false)
        #expect(await bus.invoke("t.nothing").succeeded == false)
    }

    @Test func unavailableActionsAreHiddenAndRefused() async {
        let (bus, _) = makeBus()
        var enabled = false
        bus.register(seek, isAvailable: { enabled }) { _ in .done(nil) }
        #expect(bus.availableActions().isEmpty)
        #expect(await bus.invoke("t.seek", ["seconds": .number(1)]).succeeded == false)
        enabled = true
        #expect(bus.availableActions().map(\.id) == ["t.seek"])
    }

    @Test func retiringAModuleRemovesItsActions() {
        let (bus, _) = makeBus()
        bus.register(seek) { _ in .done(nil) }
        bus.retire(module: "m")
        #expect(bus.availableActions().isEmpty)
    }
}

@MainActor
@Suite struct RAVEMediaTests {
    @Test func mediaActionsFollowThePlayersState() async {
        let (bus, _) = makeBus()
        let player = FakePlayer()
        RAVEMediaActions.register(on: bus, module: "hypnos", controller: player)
        #expect(bus.availableActions().map(\.id) == ["media.play", "media.skip"])
        _ = await bus.invoke("media.play")
        #expect(player.isPlaying)
        #expect(bus.availableActions().map(\.id) == ["media.pause", "media.skip"])
        let skip = await bus.invoke("media.skip", ["seconds": .number(-10)])
        #expect(skip.succeeded)
        #expect(player.skipped == [-10])
        // A model asking for an hour is refused before the player hears of it.
        #expect(await bus.invoke("media.skip", ["seconds": .number(3600)]).succeeded == false)
        #expect(player.skipped == [-10])
        player.canPlayNext = true
        #expect(bus.availableActions().map(\.id).contains("media.next"))
    }

    @Test func digestIsNilWhenNothingPlays() {
        let (bus, _) = makeBus()
        #expect(RAVEMediaDigest.text(bus: bus) == nil)
    }

    @Test func digestSummarisesTheItemAndTheRecentDialogue() {
        let (bus, clock) = makeBus()
        bus.publish(RAVEMediaFeeds.nowPlaying,
                    RAVENowPlaying(title: "Heat", overview: "A heist.", year: 1995, kind: .film,
                                   position: 2480, duration: 6720, isPlaying: true),
                    from: "hypnos")
        bus.publish(RAVEMediaFeeds.subtitle, RAVEMediaCue(text: "Old line", start: 0, end: 2), from: "hypnos")
        clock.advance(200)   // beyond the 90 s window
        bus.publish(RAVEMediaFeeds.subtitle, RAVEMediaCue(text: "Don't get attached.", start: 1, end: 3, speaker: "Neil"), from: "hypnos")
        bus.publish(RAVEMediaFeeds.subtitle, RAVEMediaCue(text: "Don't get attached.", start: 1, end: 3, speaker: "Neil"), from: "hypnos")
        let text = RAVEMediaDigest.text(bus: bus)
        #expect(text?.contains("Watching: Heat (1995), 41:20 of 1:52:00, playing.") == true)
        #expect(text?.contains("About it: A heist.") == true)
        #expect(text?.contains("Neil: Don't get attached.") == true)
        #expect(text?.contains("Old line") == false)
        // The repeated caption appears once.
        #expect(text?.components(separatedBy: "Don't get attached.").count == 2)
        #expect(RAVEMediaDigest.text(bus: bus, includeOverview: false)?.contains("About it") == false)
    }

    @Test func spaceObjectReadsPositionAndFacing() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(1, 1.5, -3, 1)
        let screen = RAVESpaceObject(kind: "screen", transform: m, size: [4, 2.25])
        #expect(screen.position == SIMD3(1, 1.5, -3))
        #expect(screen.normal == SIMD3(0, 0, 1))
    }
}
