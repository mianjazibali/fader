import Foundation
import AppKit

/// Category drives ducking behavior. Communication apps duck everything else
/// when they go active.
enum AppCategory: String, Codable, Sendable {
    case communication
    case media
    case browser
    case game
    case other
}

/// One audio-producing application as known to Fader.
/// Identified by bundle ID; PIDs are unstable (apps relaunch).
///
/// Not Sendable because `NSImage` isn't. The whole graph is owned by the
/// main actor (`AudioState`), so cross-actor passing isn't a concern.
struct AudioApp: Identifiable, Equatable {
    let id: String              // bundle identifier
    var displayName: String
    var category: AppCategory
    var pid: pid_t?             // current pid, if running
    var icon: NSImage?
    var volume: Float           // 0.0 ... 1.0 normally, 0.0 ... 2.0 when isBoosted
    var isMuted: Bool

    /// User opt-in, per app, off by default. Extends this app's own
    /// slider range to 200% instead of the normal 100% ceiling — for
    /// something that's quiet even at full volume. Deliberately per-app
    /// rather than a blanket range extension for everyone, so every other
    /// app's "100%" stays exactly what it's always meant.
    var isBoosted: Bool = false
    var isActive: Bool          // currently producing audio
    var levelMeter: Float       // 0.0 ... 1.0, instantaneous output level

    /// True if Fader can actually control this app's volume right now.
    /// False means the slider/mute should be disabled with an explanatory
    /// indicator (Phase 3 routing is the proper fix; until then we're honest
    /// about which apps we can drive).
    var supportsVolumeControl: Bool

    /// True when this app currently has mic input AND output both active
    /// (a live call) — independent of whether the user has opted into
    /// controlling it (`AudioState.allowVolumeControlDuringCalls`). Used
    /// to scope the call-specific gain boost to only the apps that
    /// actually need it; see CoreAudioEngine's `gainBoost`.
    var isInLiveCall: Bool = false

    /// True if the user has muted this app or turned its volume down from
    /// the default — worth keeping visible even while it's gone quiet, so
    /// muting an app can't make it (and the ability to undo the mute)
    /// disappear the next time it stops playing.
    var hasCustomSettings: Bool {
        isMuted || volume < 0.995
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id &&
        lhs.volume == rhs.volume &&
        lhs.isMuted == rhs.isMuted &&
        lhs.isActive == rhs.isActive &&
        lhs.levelMeter == rhs.levelMeter &&
        lhs.pid == rhs.pid &&
        lhs.supportsVolumeControl == rhs.supportsVolumeControl &&
        lhs.isInLiveCall == rhs.isInLiveCall &&
        lhs.isBoosted == rhs.isBoosted
    }
}
