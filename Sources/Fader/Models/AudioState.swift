import Foundation
import Observation

/// Single source of truth for the UI. Engines push updates here; views observe.
@Observable
@MainActor
final class AudioState {
    var apps: [AudioApp] = []

    /// Mirrors the real macOS output volume (synced by `SystemVolumeListener`,
    /// read-only from the UI's perspective — there is no in-app master
    /// control, the user drives this via the system volume keys / Control
    /// Center, same as any other app).
    var systemVolume: Float = 1.0

    /// Behaviorally-inferred permission problems (see CoreAudioEngine) —
    /// neither Automation nor system-audio-capture TCC status can be
    /// queried directly, so both are detected from what actually happens
    /// (an AppleScript -1743 error; a tapped app staying silent). Surfaced
    /// as a dismissible banner + a status row in Settings, not a hard gate.
    var automationPermissionDenied: Bool = false
    var systemAudioCaptureLikelyBlocked: Bool = false
    /// "Not now" on the main-panel banner — resets on relaunch, so a still-
    /// unresolved permission surfaces again eventually without nagging on
    /// every popover open in the meantime. Settings always shows status
    /// regardless of this.
    var permissionBannerDismissed: Bool = false

    var duckingEnabled: Bool = true
    var duckingAmount: Float = 0.5         // % to lower non-comm apps when ducking
    var duckingAttackMs: Double = 120
    var duckingReleaseMs: Double = 600

    /// The user-perceived volume for an app: its own slider (0...100%),
    /// then ducking. Deliberately NOT multiplied by systemVolume here —
    /// tapped audio is written directly into the real output device's
    /// buffer (PlaybackDevice), and macOS's system volume is a
    /// device-level property that gets applied to whatever's in that
    /// buffer regardless of which client wrote it. The hardware already
    /// scales tapped apps by systemVolume once, same as everything else;
    /// multiplying it in here too meant tapped apps got attenuated by
    /// systemVolume TWICE (systemVolume² vs untapped apps' systemVolume¹)
    /// — at 100% that made every tapped app quieter than its own native,
    /// untapped volume instead of matching it. Hardware scaling alone is
    /// enough to keep tapped apps in sync with F11/F12 and Control Center.
    func effectiveVolume(for app: AudioApp) -> Float {
        guard !app.isMuted else { return 0 }
        let base = app.volume
        if duckingEnabled, isAnyCommunicationActive, app.category != .communication {
            return base * (1.0 - duckingAmount)
        }
        return base
    }

    var isAnyCommunicationActive: Bool {
        apps.contains { $0.category == .communication && $0.isActive }
    }

    /// Replace or insert an app entry, preserving order.
    func upsert(_ app: AudioApp) {
        if let idx = apps.firstIndex(where: { $0.id == app.id }) {
            apps[idx] = app
        } else {
            apps.append(app)
        }
    }

    func remove(id: String) {
        apps.removeAll { $0.id == id }
    }

    func setVolume(_ value: Float, for id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].volume = max(0, min(1, value))
    }

    func setMuted(_ muted: Bool, for id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].isMuted = muted
    }
}
