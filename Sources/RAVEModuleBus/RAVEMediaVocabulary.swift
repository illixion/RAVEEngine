//
//  RAVEMediaVocabulary.swift
//  RAVEModuleBus
//
//  The shared words for "something is playing": the feeds a player module
//  publishes and the actions it offers, so a companion can watch along without
//  knowing which app is the player. Hypnos is the first publisher; a browser or
//  a streamed desktop could be another.
//

import Foundation
import simd

public struct RAVENowPlaying: Sendable, Equatable {
    public enum Kind: String, Sendable { case film, episode, video, music }

    public var title: String
    /// The episode's title, or a tagline.
    public var subtitle: String?
    public var overview: String?
    public var year: Int?
    public var kind: Kind
    public var genres: [String]
    /// Seconds into the item, and its length (0 when unknown).
    public var position: TimeInterval
    public var duration: TimeInterval
    public var isPlaying: Bool

    public init(title: String, subtitle: String? = nil, overview: String? = nil, year: Int? = nil,
                kind: Kind = .film, genres: [String] = [], position: TimeInterval = 0,
                duration: TimeInterval = 0, isPlaying: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.year = year
        self.kind = kind
        self.genres = genres
        self.position = position
        self.duration = duration
        self.isPlaying = isPlaying
    }
}

/// One line of dialogue or caption, in the item's own time.
public struct RAVESubtitleCue: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String?

    public init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// A thing with a place in the shared space that other modules may care about: a screen
/// to sit facing, a stream to stand beside. Pose is in the space's frame, metres.
public struct RAVESpaceObject: Sendable, Equatable {
    public var kind: String
    /// Centre of the object; +z points toward the viewer.
    public var transform: simd_float4x4
    /// Width and height in metres.
    public var size: SIMD2<Float>

    public init(kind: String, transform: simd_float4x4, size: SIMD2<Float>) {
        self.kind = kind
        self.transform = transform
        self.size = size
    }

    public var position: SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// The direction the object faces (toward the viewer).
    public var normal: SIMD3<Float> {
        simd_normalize(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
    }
}

public enum RAVEMediaFeeds {
    public static let nowPlaying = RAVEFeedKey<RAVENowPlaying>("media.nowPlaying", privacy: .personalText,
                                                                minInterval: 1)
    /// Cues as they come due, kept three minutes.
    public static let subtitle = RAVEFeedKey<RAVESubtitleCue>("media.subtitle", privacy: .personalText,
                                                               retention: 180, retainedLimit: 200)
    public static let screen = RAVEFeedKey<RAVESpaceObject>("media.screen", minInterval: 0.2)
}

public enum RAVEMediaActionID {
    public static let play = "media.play"
    public static let pause = "media.pause"
    /// Jump by a number of seconds (negative goes back).
    public static let skip = "media.skip"
    public static let next = "media.next"
}

/// What a player module implements once; `RAVEMediaActions.register` turns it into bus actions.
@MainActor
public protocol RAVEMediaControlling: AnyObject {
    var isPlaying: Bool { get }
    /// Something is loaded, so transport makes sense.
    var hasMedia: Bool { get }
    var canPlayNext: Bool { get }
    func play()
    func pause()
    func skip(by seconds: TimeInterval)
    func playNext()
}

public enum RAVEMediaActions {
    /// The skip a model may ask for, in seconds either way.
    public static let skipRange: ClosedRange<Double> = -300...300

    @MainActor
    public static func register(on bus: RAVEModuleBus, module: String, controller: RAVEMediaControlling) {
        bus.register(
            RAVEBusAction(id: RAVEMediaActionID.play, module: module, summary: "Resume the film or video."),
            isAvailable: { [weak controller] in controller.map { $0.hasMedia && !$0.isPlaying } ?? false },
            handler: { [weak controller] _ in
                guard let controller else { return .refused("The player is gone.") }
                controller.play()
                return .done("Playing.")
            })
        bus.register(
            RAVEBusAction(id: RAVEMediaActionID.pause, module: module, summary: "Pause the film or video."),
            isAvailable: { [weak controller] in controller.map { $0.hasMedia && $0.isPlaying } ?? false },
            handler: { [weak controller] _ in
                guard let controller else { return .refused("The player is gone.") }
                controller.pause()
                return .done("Paused.")
            })
        bus.register(
            RAVEBusAction(id: RAVEMediaActionID.skip, module: module,
                          summary: "Jump back or forward in the film, for example back 10 seconds to hear a line again.",
                          parameters: [RAVEBusParameter("seconds", .number(range: skipRange),
                                                        doc: "Seconds to jump; negative goes back.")]),
            isAvailable: { [weak controller] in controller?.hasMedia ?? false },
            handler: { [weak controller] args in
                guard let controller, let seconds = args["seconds"]?.number else { return .refused("Nothing to skip in.") }
                controller.skip(by: seconds)
                return .done("Skipped \(Int(seconds)) seconds.")
            })
        bus.register(
            RAVEBusAction(id: RAVEMediaActionID.next, module: module, summary: "Start the next episode."),
            isAvailable: { [weak controller] in controller?.canPlayNext ?? false },
            handler: { [weak controller] _ in
                guard let controller else { return .refused("The player is gone.") }
                controller.playNext()
                return .done("Playing the next episode.")
            })
    }
}

/// How a reader turns the media feeds into the few lines a model gets each turn.
public enum RAVEMediaDigest {
    /// "Watching: Title (2019), 41:20 of 1:52:00, playing." followed by what was said in
    /// the last `seconds`. Nil when nothing is playing, so a turn carries no media noise.
    /// `includeOverview` adds the synopsis (spoilers are allowed: the person chose that).
    @MainActor
    public static func text(bus: RAVEModuleBus, lastSeconds seconds: TimeInterval = 90,
                            includeOverview: Bool = true, maxCues: Int = 12) -> String? {
        guard let playing = bus.latest(RAVEMediaFeeds.nowPlaying)?.value else { return nil }
        var head = "Watching: \(playing.title)"
        if let sub = playing.subtitle, !sub.isEmpty { head += " – \(sub)" }
        if let year = playing.year { head += " (\(year))" }
        head += ", \(clock(playing.position))"
        if playing.duration > 0 { head += " of \(clock(playing.duration))" }
        head += playing.isPlaying ? ", playing." : ", paused."
        var lines = [head]
        if includeOverview, let o = playing.overview, !o.isEmpty { lines.append("About it: \(o)") }
        let cues = bus.window(RAVEMediaFeeds.subtitle, last: seconds).map(\.value)
        // Newest cues, in order; repeated lines (a caption shown twice) once.
        var seen = Set<String>()
        let recent = cues.suffix(maxCues).filter { seen.insert("\($0.speaker ?? "")|\($0.text)").inserted }
        if !recent.isEmpty {
            lines.append("Just said:")
            lines += recent.map { cue in cue.speaker.map { "\($0): \(cue.text)" } ?? cue.text }
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
