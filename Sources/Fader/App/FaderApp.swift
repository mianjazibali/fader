import SwiftUI
import Darwin

@main
struct FaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Engine selection:
    /// - default: live CoreAudio detection + gain (Phases 2 + 3)
    /// - `--mock`: 6-app fixture (handy for design / screenshots)
    @State private var engine: any AudioEngine = {
        if CommandLine.arguments.contains("--mock") {
            return MockAudioEngine()
        }
        return CoreAudioEngine()
    }()

    init() {
        // Only one Fader process may run at a time. A second one would spin
        // up its own CoreAudioEngine — a second set of Process Taps and its
        // own aggregate device — fighting the first over the exact same
        // audio routing, on top of showing a duplicate menu bar icon. This
        // is a real risk in practice: the LaunchAgent instance is always
        // running, so launching another copy (double-click, `open -a`, a
        // `--preview` build) would collide with it.
        //
        // flock() on a fixed file, held for the process's entire lifetime.
        // The kernel releases the lock automatically when the file
        // descriptor closes — on clean quit, crash, or `kill -9` alike —
        // so a stale lock can never strand a future launch.
        guard Self.acquireSingleInstanceLock() else {
            exit(0)
        }

        // Engine must start before the menu bar opens — otherwise users with a
        // menu bar manager (Ice, Bartender) never trigger the .task hook and
        // detection/gain never come online.
        let e = engine
        Task { @MainActor in
            try? await e.start()
            if CommandLine.arguments.contains("--test-gain-cycle") {
                await Self.runGainCycleTest(engine: e)
            }
        }
    }

    /// Returns false if another Fader process already holds the lock.
    private static func acquireSingleInstanceLock() -> Bool {
        let path = NSTemporaryDirectory() + "com.fader.app.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true } // Can't even open it — don't block launch over that.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        // Deliberately never closed: the open fd IS the lock, held until
        // this process exits.
        return true
    }

    /// Verification helper: every 3s, set the first detected app's volume to
    /// a different value (0.25, 1.0, 0.0, 1.0, 0.5) so logs show gain changes.
    /// Useful for asserting the IOProc is using updated values.
    @MainActor
    private static func runGainCycleTest(engine: any AudioEngine) async {
        let cycle: [(label: String, value: Float)] = [
            ("25%", 0.25), ("100%", 1.0), ("MUTE", 0.0), ("100%", 1.0), ("50%", 0.5)
        ]
        // Wait for at least one app to be detected.
        for _ in 0..<10 {
            if !engine.state.apps.isEmpty { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let target = engine.state.apps.first(where: { $0.isActive }) else {
            FileHandle.standardError.write(Data("[GainCycle] no active app to test\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("[GainCycle] cycling gain on \(target.id)\n".utf8))
        for (label, value) in cycle {
            try? await Task.sleep(for: .seconds(3))
            FileHandle.standardError.write(Data("[GainCycle] -> \(label) (\(value))\n".utf8))
            engine.applyGain(value, to: target.id)
        }
        FileHandle.standardError.write(Data("[GainCycle] done\n".utf8))
    }

    var body: some Scene {
        MenuBarExtra {
            ControlCenterView(engine: engine)
        } label: {
            MenuBarLabel(state: engine.state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon that lives in the menu bar. Always the fader glyph — single
/// consistent identity, matching the app icon and in-app brand mark. We do
/// not switch to a speaker glyph based on state because users found it
/// confusing.
struct MenuBarLabel: View {
    @Bindable var state: AudioState

    var body: some View {
        Image(systemName: "slider.vertical.3")
            .symbolRenderingMode(.hierarchical)
            // Subtle visual cue when any app is producing output, without
            // changing the icon's silhouette.
            .foregroundStyle(state.apps.contains(where: { $0.isActive }) ? .primary : .secondary)
    }
}
