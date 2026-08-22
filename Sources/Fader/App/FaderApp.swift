import SwiftUI
import AppKit
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

    // Held here (not just started and dropped) so their internal, weakly-
    // self-referencing background Tasks stay alive for the app's lifetime
    // — see the `@State private var engine` pattern above for why.
    @State private var updateChecker: UpdateChecker?
    @State private var engagementTracker: EngagementTracker?

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
        //
        // A silent exit(0) here used to be genuinely confusing in
        // practice — double-click the app, nothing visibly happens, no
        // menu bar icon, no error. Now the user gets to choose.
        Self.resolveSingleInstance()

        // Engine must start before the menu bar opens — otherwise users with a
        // menu bar manager (Ice, Bartender) never trigger the .task hook and
        // detection/gain never come online.
        let e = engine
        // Constructed here (synchronously, in init's own body) rather than
        // inside the Task below — assigning to a @State property from
        // within an escaping closure captured during init isn't allowed
        // (mutating self), so the instances are made now and only
        // *started* asynchronously.
        let checker = UpdateChecker(state: e.state)
        let engagement = EngagementTracker(state: e.state)
        updateChecker = checker
        engagementTracker = engagement

        Task { @MainActor in
            try? await e.start()
            checker.start()
            engagement.start()
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

    /// If another Fader process already holds the lock, asks the user
    /// whether to quit it and continue, or cancel this launch, instead of
    /// silently exiting — a silent exit is indistinguishable from the app
    /// just being broken.
    private static func resolveSingleInstance() {
        if acquireSingleInstanceLock() { return }

        // `NSApp` (the C-style global) is still nil this early in the
        // SwiftUI App lifecycle — NSApplication hasn't been instantiated
        // yet at the point `init()` runs. `NSApplication.shared` is the
        // one that actually creates it on first access; using the global
        // here silently no-ops (methods on a nil AppKit global don't
        // trap the way you'd expect) and both the activation and the
        // alert never actually happen.
        //
        // Deliberately NOT touching activation policy here (no
        // `.regular`/`.accessory` flip) — Info.plist's LSUIElement
        // already makes this an accessory app, and accessory apps can
        // still activate and show alerts. Flipping policy back and forth
        // this early turned out to reliably break MenuBarExtra's status
        // item from ever registering afterward — the app would launch
        // and run with no crash, just with no menu bar icon, ever.
        let app = NSApplication.shared
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Fader is already running"
        alert.informativeText = "Only one copy of Fader can run at a time. You can quit the other one and open this one instead, or cancel."
        alert.addButton(withTitle: "Quit Other & Open")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else {
            exit(0)
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.fader.app")
            .filter { $0.processIdentifier != myPID }
        others.forEach { $0.terminate() }

        // terminate() is a request, not instant — the other process needs
        // a moment to actually release the flock on exit. A few short
        // retries covers that without risking a real hang.
        for _ in 0..<20 {
            if acquireSingleInstanceLock() { return }
            usleep(150_000)
        }

        // Still couldn't get it (the other instance didn't quit in time,
        // or something else entirely holds it) — bail instead of running
        // two instances against the same audio hardware.
        let failure = NSAlert()
        failure.messageText = "Couldn't take over from the other instance"
        failure.informativeText = "The other copy of Fader didn't quit in time. Try again in a moment."
        failure.alertStyle = .warning
        failure.runModal()
        exit(0)
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
        // A live SwiftUI Shape here (the original approach) renders fine
        // everywhere else — the in-app header badge, every preview
        // screenshot taken this session — but reliably came out as a
        // blank status item in the real menu bar: the NSStatusItem
        // reserved its slot correctly (confirmed via Control Center's own
        // status-item logs — the scene registers and reconnects with no
        // errors), the *content* just never rasterized. Pre-rendering the
        // same glyph as a real template NSImage (exactly how every SF
        // Symbol already works under the hood) sidesteps whatever that
        // rasterization gap is.
        Image(nsImage: state.apps.contains(where: { $0.isActive }) ? Self.activeIcon : Self.inactiveIcon)
    }

    private static let activeIcon = makeIcon(alpha: 1.0)
    private static let inactiveIcon = makeIcon(alpha: 0.55)

    /// Same glyph as `FaderMark`/the website's mark, drawn directly with
    /// NSBezierPath instead of a SwiftUI Path, and marked `isTemplate`
    /// so AppKit re-tints it for light/dark menu bars and the
    /// highlighted (menu-open) state automatically.
    private static func makeIcon(alpha: CGFloat) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            let scale = min(rect.width, rect.height) / 16
            let bars: [(x: CGFloat, y1: CGFloat, y2: CGFloat)] = [
                (3, 12, 4), (8, 13, 3), (13, 10, 6)
            ]
            for bar in bars {
                path.move(to: NSPoint(x: bar.x * scale, y: bar.y1 * scale))
                path.line(to: NSPoint(x: bar.x * scale, y: bar.y2 * scale))
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
