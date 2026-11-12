/*
 RAVE Engine — sleeve pages more than one app wears.

 A page here is a starting point an app adds to its own layout: the ids and
 actions are fixed so the glue is the same everywhere, the look is each app's.
 */

import Foundation

public enum RAVESleevePresets {
    /// Tile ids of `mediaRemote`, for the app's tile state.
    public enum MediaTile {
        public static let title = "media.title"
        public static let progress = "media.progress"
        public static let back = "media.back"
        public static let playPause = "media.playPause"
        public static let forward = "media.forward"
        public static let next = "media.next"
    }

    /// Action ids of `mediaRemote`. Play, pause, skip and next are RAVEModuleBus's
    /// `RAVEMediaActionID` values, so a player that registered
    /// `RAVEMediaActions` on a bus is driven by sending the event's action
    /// straight to it. `seek` carries the slider's fraction in the event.
    public enum MediaAction {
        public static let play = "media.play"
        public static let pause = "media.pause"
        public static let skip = "media.skip"
        public static let next = "media.next"
        public static let seek = "media.seek"
    }

    /// A remote for whatever is playing: the title, a seek bar, and back,
    /// play/pause, forward and next. Hypnos's HUD and Big Screen modes are
    /// the first wearers.
    ///
    /// The app keeps `MediaTile.title`'s text, `progress`'s fraction and
    /// `playPause`'s `isOn` (playing) current. A `.toggled(true)` on
    /// `playPause` means play, `.toggled(false)` pause; its action id is
    /// `MediaAction.play` either way.
    public static func mediaRemote(id: String = "media", skipSeconds: Int = 10) -> RAVESleevePage {
        RAVESleevePage(id, title: "Now Playing", rows: [
            [RAVESleeveTile(MediaTile.title, .label, span: 4)],
            [RAVESleeveTile(MediaTile.progress, .slider(RAVESleeveAction(MediaAction.seek)), span: 4)],
            [
                RAVESleeveTile(MediaTile.back, .button(RAVESleeveAction(MediaAction.skip, argument: "-\(skipSeconds)")),
                               label: "Back \(skipSeconds) s", icon: "gobackward.\(skipSeconds)"),
                RAVESleeveTile(MediaTile.playPause, .toggle(RAVESleeveAction(MediaAction.play)),
                               label: "Play", icon: "playpause.fill", role: .primary),
                RAVESleeveTile(MediaTile.forward, .button(RAVESleeveAction(MediaAction.skip, argument: "\(skipSeconds)")),
                               label: "Forward \(skipSeconds) s", icon: "goforward.\(skipSeconds)"),
                RAVESleeveTile(MediaTile.next, .button(RAVESleeveAction(MediaAction.next)),
                               label: "Next", icon: "forward.end.fill"),
            ],
        ])
    }
}
