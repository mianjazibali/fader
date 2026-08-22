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

    /// Behaviorally-inferred permission problem (see CoreAudioEngine) —
    /// system-audio-capture TCC status can't be queried directly, so it's
    /// detected from what actually happens (a tapped, active app staying
    /// silent). Surfaced as a dismissible banner + a status row in
    /// Settings, not a hard gate.
    var systemAudioCaptureLikelyBlocked: Bool = false
    /// "Not now" on the main-panel banner — resets on relaunch, so a still-
    /// unresolved permission surfaces again eventually without nagging on
    /// every popover open in the meantime. Settings always shows status
    /// regardless of this.
    var permissionBannerDismissed: Bool = false

    /// Set by `UpdateChecker` when GitHub's latest release tag is newer
    /// than the running build. Surfaced as a dismissible banner (re-shown
    /// next launch if still outdated — this is an ongoing state, not a
    /// one-time notice) plus the version line in Settings.
    var updateAvailable: (version: String, url: URL)?
    var updateBannerDismissed: Bool = false

    /// Set by `EngagementTracker` exactly once, ever, per install — see
    /// its doc comment for the cumulative-usage threshold and the
    /// permanent "don't ask again" bookkeeping.
    var showSupportPrompt: Bool = false

    /// Backing store for the three properties below — loaded once in
    /// `init`, written back on every change via each property's `didSet`.
    private let settingsStore = SettingsStore()
    private var duckingAmountSaveTask: Task<Void, Never>?

    var duckingEnabled: Bool = true {
        didSet {
            guard duckingEnabled != oldValue else { return }
            settingsStore.duckingEnabled = duckingEnabled
        }
    }
    var duckingAmount: Float = 0.5 {         // % to lower non-comm apps when ducking
        didSet {
            guard duckingAmount != oldValue else { return }
            // Debounced like VolumeStore — this is bound to a slider that
            // fires continuously while dragging, and UserDefaults doesn't
            // need to see every intermediate value.
            duckingAmountSaveTask?.cancel()
            let store = settingsStore
            let value = duckingAmount
            duckingAmountSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                store.duckingAmount = value
            }
        }
    }
    var duckingAttackMs: Double = 120
    var duckingReleaseMs: Double = 600

    /// Experimental, off by default. Normally Fader skips tap creation for
    /// any app with mic input AND output both active (a live call) — see
    /// CoreAudioEngine's `inLiveCall` check. Empirical testing (a
    /// mutedWhenTapped tap against a real WhatsApp call) showed real,
    /// non-zero audio content does come through rather than being zeroed,
    /// contradicting the original assumption — but whether
    /// `CATapMutedWhenTapped` actually silences the app's original output
    /// during a *live call* specifically (vs. a regular app) was never
    /// conclusively confirmed. If it doesn't, enabling this plays the
    /// original call audio AND Fader's gain-scaled rerouted copy at once —
    /// an audible echo/doubling. Opt-in so nobody hits that by surprise;
    /// the user who wants this can flip it on and immediately hear for
    /// themselves whether it's clean or echoes.
    var allowVolumeControlDuringCalls: Bool = false {
        didSet {
            guard allowVolumeControlDuringCalls != oldValue else { return }
            settingsStore.allowVolumeControlDuringCalls = allowVolumeControlDuringCalls
        }
    }

    init() {
        duckingEnabled = settingsStore.duckingEnabled
        duckingAmount = settingsStore.duckingAmount
        allowVolumeControlDuringCalls = settingsStore.allowVolumeControlDuringCalls
    }

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
