import Foundation
import AppKit
import CoreAudio

/// Phase 3 engine: real process detection AND real per-app gain via CoreAudio
/// Process Taps + a private aggregate device.
///
/// Phase 1 (mock) → Phase 2 (detection) → Phase 3 (gain) all live behind the
/// same `AudioEngine` protocol so the UI is unchanged across phases.
@MainActor
final class CoreAudioEngine: AudioEngine {
    let state = AudioState()
    let gainController = AudioGainController()
    private let volumeStore = VolumeStore()

    /// Phase 3 (per-app tap → ring buffer → playback) is on by default.
    /// Pass `--no-gain` to disable for debugging Phase 2 detection in isolation.
    private let gainEnabled = !CommandLine.arguments.contains("--no-gain")

    private var detector: AudioProcessDetector?
    private var systemVolumeListener: SystemVolumeListener?
    private var pulseTask: Task<Void, Never>?

    /// True while we're WRITING the system volume from a UI slider drag.
    /// Suppresses the listener echo so we don't fight the user's input.
    private var suppressSystemVolumeEcho = false

    /// HAL process-object-ID by bundle ID — needed to feed the gain controller.
    private var processIDByBundle: [String: AudioObjectID] = [:]

    /// When each currently-tapped bundle's level last read as silent.
    /// System-audio-capture TCC denial is invisible to every CoreAudio
    /// status code — the tap's buffers just stay zero forever — so this is
    /// the only real signal: a bundle with an installed tap whose level
    /// hasn't shown *any* signal for several seconds while genuinely
    /// active is almost certainly not actually being captured.
    private var silentSinceByBundle: [String: Date] = [:]
    private let silenceBlockedThreshold: TimeInterval = 6.0

    func start() async throws {
        let det = AudioProcessDetector { [weak self] processes in
            Task { @MainActor [weak self] in
                self?.merge(processes)
            }
        }
        self.detector = det
        det.start()

        // Track the real system output volume — app-level gain is relative
        // to this (see AudioState.effectiveVolume).
        let volListener = SystemVolumeListener { [weak self] sysVol in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if abs(self.state.systemVolume - sysVol) > 0.01 {
                    self.state.systemVolume = sysVol
                }
            }
        }
        self.systemVolumeListener = volListener
        volListener.start()

        startPulseLoop()
    }

    func stop() {
        detector?.stop()
        detector = nil
        systemVolumeListener?.stop()
        systemVolumeListener = nil
        pulseTask?.cancel()
        pulseTask = nil
        gainController.shutdown()
    }

    func applyGain(_ value: Float, to appId: String) {
        state.setVolume(value, for: appId)
        pushGain(for: appId)
        persistVolume(for: appId)
    }

    func setMuted(_ muted: Bool, for appId: String) {
        state.setMuted(muted, for: appId)
        pushGain(for: appId)
        persistVolume(for: appId)
    }

    private func persistVolume(for appId: String) {
        guard let app = state.apps.first(where: { $0.id == appId }) else { return }
        volumeStore.update(bundleID: appId, volume: app.volume, isMuted: app.isMuted)
    }

    func resyncAllGains() {
        for app in state.apps { pushGain(for: app.id) }
    }

    // MARK: - Reconciliation

    private func merge(_ processes: [AudioProcess]) {
        var byBundle: [String: AudioProcess] = [:]
        for p in processes {
            guard let b = p.bundleID, !b.isEmpty else { continue }
            byBundle[b] = p
        }

        // Drop apps that left the HAL.
        let toRemove = state.apps.map(\.id).filter { byBundle[$0] == nil }
        for id in toRemove {
            state.remove(id: id)
            processIDByBundle.removeValue(forKey: id)
        }

        // Upsert each known process.
        for (bundleID, p) in byBundle {
            let existing = state.apps.first { $0.id == bundleID }
            // The detector merges audio sub-processes into the parent bundle,
            // but `p.pid` still points at the audio-producing helper (which
            // is correct for tap creation). For DISPLAY purposes we want the
            // main app — find any running instance with the parent bundle ID
            // and a "regular" activation policy (i.e. has a dock entry).
            let parentApp = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.activationPolicy == .regular })
            let helperApp = NSRunningApplication(processIdentifier: p.pid)
            let running = parentApp ?? helperApp
            let category = AppCategorizer.category(for: bundleID)

            // Only output-running counts as "playing audio". Earlier we treated
            // any running stream (incl. mic input) as active for comm apps so
            // ducking would fire during calls — but that incorrectly fires for
            // idle Slack/Zoom that just have their mic stream registered.
            // Comm apps trigger ducking only when they're actually outputting
            // audio (someone's voice coming through).
            let active = p.isRunningOutput

            if existing == nil && !active {
                continue
            }

            processIDByBundle[bundleID] = p.objectID

            // Apps simultaneously running mic input AND output are in a live
            // call (voice/video). macOS silently zeroes Process Tap content
            // for that audio (a wiretap/privacy protection, not a bug we can
            // work around) while `CATapMutedWhenTapped` still mutes the app's
            // real output the moment we start reading — net effect: tapping
            // a call goes completely silent, worse than doing nothing. So we
            // skip tap creation for these and leave their real audio path
            // alone; the slider just goes disabled with a "—" for the call's
            // duration (see AppRowView's `supportsVolumeControl` handling).
            let inLiveCall = p.isRunningInput && p.isRunningOutput

            // Every app — including Music, Spotify, TV, and Podcasts, which
            // used to also get an AppleScript write to their own volume
            // slider — is controlled purely through the tap pipeline now.
            // Fader's slider is a relative gain multiplier on top of
            // whatever the app is actually outputting; it never reaches
            // into and overwrites the app's own volume setting. (The old
            // AppleScript path did both at once for those four apps: the
            // tap already scaled their output by Fader's gain, AND the
            // AppleScript write scaled their *own* volume by the same
            // amount again — so 50% on Fader's slider compounded into 25%
            // of the app's real output instead of the 50% it displayed.)
            let supports = !inLiveCall && gainEnabled

            let app = AudioApp(
                id: bundleID,
                displayName: existing?.displayName
                    ?? running?.localizedName
                    ?? Self.fallbackName(for: bundleID),
                category: category,
                pid: p.pid,
                icon: existing?.icon ?? running?.icon ?? Self.iconForBundle(bundleID),
                volume: existing?.volume ?? volumeStore.entry(for: bundleID)?.volume ?? 1.0,
                isMuted: existing?.isMuted ?? volumeStore.entry(for: bundleID)?.isMuted ?? false,
                isActive: active,
                levelMeter: existing?.levelMeter ?? 0,
                supportsVolumeControl: supports
            )
            state.upsert(app)
        }

        // Reconcile gain controller to the new active set — only if Phase 3
        // gain is opt-in. Without this, taps would silence the original output
        // and audibility would depend on our routing being correct.
        // `supportsVolumeControl` is also false for apps mid-call — see the
        // `inLiveCall` note above — so those never get a tap installed.
        if gainEnabled {
            let activeApps = state.apps.filter { $0.isActive }
            let tappableApps = activeApps.filter { $0.supportsVolumeControl }
            let initialGains = Dictionary(uniqueKeysWithValues: tappableApps.map { ($0.id, state.effectiveVolume(for: $0)) })
            gainController.apply(active: tappableApps, processIDByBundle: processIDByBundle, initialGains: initialGains)
            for app in activeApps {
                pushGain(for: app.id)
            }
        }
    }

    /// Compute master * volume * ducking, push to the realtime gain table.
    private func pushGain(for bundleID: String) {
        guard let app = state.apps.first(where: { $0.id == bundleID }) else { return }
        let effective = state.effectiveVolume(for: app)
        gainController.setGain(forBundle: bundleID, effective: effective)
    }

    /// Behavioral system-audio-capture health check — see the
    /// `silentSinceByBundle` doc comment for why this can't be a status
    /// code check. Only bundles with an actually-installed tap
    /// (`hasSlot`) count, so "no tap yet" (still installing, or genuinely
    /// failed for an unrelated reason already logged elsewhere) can't be
    /// mistaken for "tap installed but TCC is silently dropping it."
    private func updateCaptureHealthCheck() {
        guard gainEnabled else { return }
        let tapped = state.apps.filter { $0.isActive && gainController.hasSlot(forBundle: $0.id) }

        let now = Date()
        var stillTracked: Set<String> = []
        for app in tapped {
            stillTracked.insert(app.id)
            let raw = gainController.level(forBundle: app.id)
            if raw > 0.001 {
                silentSinceByBundle.removeValue(forKey: app.id)
            } else if silentSinceByBundle[app.id] == nil {
                silentSinceByBundle[app.id] = now
            }
        }
        // Bundles that stopped being tapped (quit, paused, tap torn down)
        // shouldn't keep contributing a stale timer.
        silentSinceByBundle = silentSinceByBundle.filter { stillTracked.contains($0.key) }

        let blocked = silentSinceByBundle.values.contains {
            now.timeIntervalSince($0) > silenceBlockedThreshold
        }
        if state.systemAudioCaptureLikelyBlocked != blocked {
            state.systemAudioCaptureLikelyBlocked = blocked
        }
    }

    private static func fallbackName(for bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }

    private static func iconForBundle(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    // MARK: - Level meter — real audio, smoothed for display

    /// Reads real peak levels from the gain controller's per-tap taps
    /// (AggregateOutputDevice.captureCallback publishes these every IOProc
    /// cycle, ~10ms) and applies simple VU-style attack/release smoothing
    /// before publishing to the UI. 40ms keeps the visible steps small
    /// enough to read as smooth motion without needing SwiftUI-level
    /// `.animation()` on the displayed value, which is what actually
    /// caused the popover resize-loop bugs — this only touches how often
    /// we hand SwiftUI a new (already-settled) number.
    private func startPulseLoop() {
        pulseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                self?.tickPulse()
            }
        }
    }

    private func tickPulse() {
        let hasActive = state.apps.contains(where: { $0.isActive })
        let hasMovingMeter = state.apps.contains(where: { $0.levelMeter > 0.001 })
        updateCaptureHealthCheck()
        guard hasActive || hasMovingMeter else { return }

        for i in state.apps.indices {
            let app = state.apps[i]
            if app.isActive, app.supportsVolumeControl {
                let raw = min(1, gainController.level(forBundle: app.id))
                let target = raw * state.effectiveVolume(for: app)
                let current = app.levelMeter
                // Fast attack, slower release — rises quickly on a real
                // transient, falls smoothly instead of snapping to 0.
                let coeff: Float = target > current ? 0.55 : 0.22
                state.apps[i].levelMeter = current + (target - current) * coeff
            } else if app.levelMeter > 0.001 {
                state.apps[i].levelMeter = max(0, app.levelMeter - 0.06)
            } else if app.levelMeter != 0 {
                state.apps[i].levelMeter = 0
            }
        }
    }
}
