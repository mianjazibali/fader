import Foundation
import CoreAudio
import AppKit

/// **Phase 3: per-app gain.**
///
/// Two IOProcs cooperate via a lock-free ring buffer:
///   • `AggregateOutputDevice` (capture half) — private aggregate with taps.
///     IOProc reads per-app tap audio, applies gain, mixes to stereo,
///     writes to ring buffer.
///   • `PlaybackDevice` (playback half) — IOProc on user's real default
///     output. Reads from ring buffer, mixes into the device's output
///     buffer (added to whatever non-tapped apps wrote).
///
/// We do NOT change the user's system default output. Apps continue to
/// target their normal output. Tapped apps' direct path is silenced via
/// `CATapMutedWhenTapped`; we route their audio back through our gain
/// pipeline. Non-tapped apps go straight through unchanged.
///
/// Active-set changes (an app starts/stops playing) rebuild the CAPTURE
/// side only — new `ProcessTap`s + a new aggregate device for the current
/// active set. The ring buffer and `PlaybackDevice` — what's actually
/// wired to the speakers — deliberately stay running across that rebuild
/// instead of being torn down and recreated too. A capture-side gap just
/// means the ring buffer briefly underflows (silence from the tapped-audio
/// contribution for a few ms, already-handled the same way an underrun
/// during steady state is), rather than the output device itself
/// stopping and restarting, which is the audible pop/glitch this used to
/// cause. Playback only gets torn down when the output DEVICE itself
/// changes (`rebuildForDeviceChange`) or when there's nothing left to
/// capture at all (`teardown`, `shutdown`).
///
/// This stops short of true in-place tap add/remove (mutating a running
/// aggregate's `kAudioAggregateDevicePropertyTapList` instead of
/// recreating it) — that path exists in CoreAudio but is under-documented
/// and under-tested enough that getting it wrong risks the realtime
/// callback reading a stale buffer-list layout. Decoupling playback
/// captures most of the actual audible benefit for a lot less risk.
@MainActor
final class AudioGainController {
    enum InstallState: Equatable {
        case idle
        case running(tapCount: Int)
        case failed(reason: String)
    }

    private(set) var state: InstallState = .idle

    /// Bundle ID -> gain slot, valid while `state == .running`.
    private var slotByBundle: [String: GainSlot] = [:]
    private var taps: [ProcessTap] = []
    private var captureDevice: AggregateOutputDevice?
    private var playbackDevice: PlaybackDevice?
    private var ringBuffer: FloatRingBuffer?
    private var lastActiveBundles: Set<String> = []
    private var statsTask: Task<Void, Never>?

    /// Which physical output device `playbackDevice` is currently bound
    /// to — lets `installTaps` tell "just the active app set changed"
    /// (leave playback alone) apart from "the output device itself
    /// changed" (must rebind playback too).
    private var currentOutputDeviceID: AudioObjectID?

    /// Remembered so a default-output-device change (headphones/Bluetooth
    /// plug/unplug) can force a rebuild even when the active app set hasn't
    /// changed. Without this, taps + the playback IOProc stay bound to the
    /// device that just disappeared and audio silently stops flowing.
    private var lastActiveApps: [AudioApp] = []
    private var lastProcessIDByBundle: [String: AudioObjectID] = [:]
    private let deviceChangeQueue = DispatchQueue(label: "com.fader.gain-controller.device-change")
    private var deviceChangeListener: ListenerHandle?

    init() {
        deviceChangeListener = CAObject.addListener(
            on: AudioObjectID(kAudioObjectSystemObject),
            selector: .defaultOutputDevice,
            queue: deviceChangeQueue
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.rebuildForDeviceChange()
            }
        }
    }

    // Kept for source-compat with the signal handler; no longer used since
    // we don't switch system default output. Leaving in for safety.
    nonisolated(unsafe) static var crashCleanupSavedDefault: AudioObjectID?

    /// `initialGains` — effective (post-ducking/master) gain per bundle, so a
    /// freshly (re)created tap starts at the right volume instead of
    /// GainSlot's `1.0` default. This path rebuilds EVERY tap whenever the
    /// active-app set changes at all — e.g. pausing one app and resuming it
    /// later — so without this, apps that didn't even change would briefly
    /// blast at full volume too.
    func apply(active: [AudioApp], processIDByBundle: [String: AudioObjectID], initialGains: [String: Float]) {
        lastActiveApps = active
        lastProcessIDByBundle = processIDByBundle

        let bundles = Set(active.map(\.id))
        guard bundles != lastActiveBundles else { return }
        log("active set changed: [\(bundles.sorted().joined(separator: ", "))]")
        lastActiveBundles = bundles

        guard !active.isEmpty else {
            // Nothing left to capture — full teardown, playback included,
            // rather than leaving an idle IOProc running for no reason.
            teardown()
            state = .idle
            return
        }

        do {
            try installTaps(for: active, processIDByBundle: processIDByBundle, initialGains: initialGains)
            state = .running(tapCount: taps.count)
            log("Phase 3 active: \(taps.count) tap(s) + ring buffer + playback IOProc")
            startStatsReporter()
        } catch {
            state = .failed(reason: String(describing: error))
            log("Phase 3 install failed: \(error)")
            teardown()
        }
    }

    func setGain(forBundle bundleID: String, effective: Float) {
        slotByBundle[bundleID]?.setGain(effective)
    }

    /// Real, audio-derived peak level (0...~1, pre-gain) for the app's tap,
    /// updated every IOProc cycle. Returns 0 for apps with no tap (e.g. a
    /// live call, which is never tapped — see CoreAudioEngine).
    func level(forBundle bundleID: String) -> Float {
        slotByBundle[bundleID]?.level ?? 0
    }

    /// True once a tap has actually been installed for this bundle — lets
    /// callers tell "no tap yet" apart from "tap installed but reading
    /// zero," which is exactly the shape of a silent TCC denial (see
    /// AudioState.systemAudioCaptureLikelyBlocked).
    func hasSlot(forBundle bundleID: String) -> Bool {
        slotByBundle[bundleID] != nil
    }

    func shutdown() {
        deviceChangeListener?.dispose()
        deviceChangeListener = nil
        teardown()
        statsTask?.cancel()
        statsTask = nil
        state = .idle
    }

    // MARK: - Private

    /// The default output device changed (e.g. Bluetooth connected/
    /// disconnected, headphones plugged in). `installTaps` re-reads the
    /// *current* default output device, so forcing a rebuild here is enough
    /// to rebind — even though the active app set itself hasn't changed.
    private func rebuildForDeviceChange() {
        guard !lastActiveApps.isEmpty else { return }
        log("default output device changed — rebuilding pipeline")
        // Carry forward whatever gain was already set on each slot — this is
        // just a device rebind, not a volume change, so the new taps should
        // start at the same level the old ones were at, not the 1.0 default.
        let currentGains = Dictionary(uniqueKeysWithValues: slotByBundle.map { ($0.key, $0.value.gain) })
        lastActiveBundles = []
        apply(active: lastActiveApps, processIDByBundle: lastProcessIDByBundle, initialGains: currentGains)
    }

    private func installTaps(for active: [AudioApp], processIDByBundle: [String: AudioObjectID], initialGains: [String: Float]) throws {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard let outputDeviceID: AudioObjectID = CAObject.read(sys, .defaultOutputDevice),
              let outputUID = CAObject.readString(outputDeviceID, .deviceUID) else {
            throw AggregateError.noDefaultOutputDevice
        }
        log("default output device: \(outputDeviceID) UID=\(outputUID)")

        // Tear down only the previous CAPTURE side (old taps + old
        // aggregate) — the ring buffer and playback IOProc are deliberately
        // left running across this; see the class doc comment for why.
        captureDevice?.stop()
        captureDevice = nil
        taps.forEach { $0.dispose() }
        taps.removeAll()
        slotByBundle.removeAll()

        var newTaps: [ProcessTap] = []
        var bundleOrder: [String] = []
        var callBoosted: [Bool] = []
        for app in active {
            guard let pobjID = processIDByBundle[app.id] else { continue }
            do {
                let tap = try ProcessTap(processObjectID: pobjID, bundleID: app.id)
                newTaps.append(tap)
                bundleOrder.append(app.id)
                callBoosted.append(app.isInLiveCall)
                log("created tap for \(app.id) → tapID=\(tap.tapID)")
            } catch {
                log("Tap creation failed for \(app.id): \(error). Skipping.")
            }
        }
        guard !newTaps.isEmpty else {
            throw AggregateError.creationFailed(status: kAudioHardwareUnsupportedOperationError)
        }

        // Reuse the existing ring buffer across a capture-only rebuild —
        // only allocate a fresh one the first time, or after a full
        // teardown. ~85ms of audio @ 48kHz stereo gives plenty of slack.
        let ring: FloatRingBuffer
        if let existing = ringBuffer {
            ring = existing
        } else {
            ring = FloatRingBuffer(requestedCapacity: 8192)
            ringBuffer = ring
        }

        let capture = try AggregateOutputDevice(
            outputDeviceUID: outputUID,
            taps: newTaps,
            callBoosted: callBoosted,
            ringBuffer: ring
        )

        // Prime every slot with its real gain BEFORE starting the IOProc.
        // The realtime capture thread can begin processing audio the
        // instant start() returns, and GainSlot defaults to 1.0 (full
        // volume) — this rebuild path fires for EVERY active app whenever
        // the set changes at all (e.g. one app pausing/resuming), so
        // without this, apps that didn't even change would also briefly
        // play at full volume until the next gain push lands on the main
        // thread a beat later.
        for (bundleID, slot) in zip(bundleOrder, capture.gainSlots) {
            slot.setGain(initialGains[bundleID] ?? 1.0)
        }
        // Also prime the click-suppression ramp's starting point to match
        // — otherwise a fresh tap would audibly ramp in from full volume
        // over the first ~7ms even though it was primed correctly above.
        capture.primeSmoothedGains()

        try capture.start()
        log("capture device started: aggID=\(capture.aggregateID)")

        // Only (re)bind playback when it isn't running yet, or when the
        // output device itself changed — a mere active-app-set change
        // must not touch it at all.
        if playbackDevice == nil || currentOutputDeviceID != outputDeviceID {
            playbackDevice?.stop()
            let playback = PlaybackDevice(deviceID: outputDeviceID, ringBuffer: ring)
            try playback.start()
            playbackDevice = playback
            currentOutputDeviceID = outputDeviceID
            log("playback device (re)started on deviceID=\(outputDeviceID)")
        }

        self.taps = newTaps
        self.captureDevice = capture
        self.slotByBundle = Dictionary(uniqueKeysWithValues: zip(bundleOrder, capture.gainSlots))
    }

    private func teardown() {
        playbackDevice?.stop()
        playbackDevice = nil
        currentOutputDeviceID = nil
        captureDevice?.stop()
        captureDevice = nil
        ringBuffer?.reset()
        ringBuffer = nil
        taps.forEach { $0.dispose() }
        taps.removeAll()
        slotByBundle.removeAll()
    }

    /// Stats reporter — opt-in via --debug.
    private func startStatsReporter() {
        guard CommandLine.arguments.contains("--debug")
           || CommandLine.arguments.contains("--test-gain-cycle") else { return }
        statsTask?.cancel()
        let cap = captureDevice
        let pb = playbackDevice
        let ring = ringBuffer
        let logFn = self.log
        var lastIn: UInt64 = 0
        var lastOut: UInt64 = 0
        var lastUnder: UInt64 = 0
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let cap, let pb, let ring, let self else { return }
                let inDelta = cap.framesReceived &- lastIn
                let outDelta = pb.samplesFromRing &- lastOut
                let underDelta = pb.underrunSamples &- lastUnder
                lastIn = cap.framesReceived
                lastOut = pb.samplesFromRing
                lastUnder = pb.underrunSamples
                let gainSummary = self.slotByBundle
                    .map { "\($0.key.suffix(20))=\(String(format: "%.2f", $0.value.gain))" }
                    .joined(separator: ", ")
                logFn("stats: tap=\(inDelta) ring=\(ring.fillLevel) playback=\(outDelta) underrun=\(underDelta) inputPeak=\(String(format: "%.4f", cap.lastInputPeak)) mixPeak=\(String(format: "%.4f", cap.lastMixPeak)) /2s | \(gainSummary)")
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[GainController] \(message)\n".utf8))
    }
}
