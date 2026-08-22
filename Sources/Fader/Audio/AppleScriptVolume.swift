import Foundation
import AppKit

/// Stopgap per-app volume control via AppleScript for apps that expose it.
///
/// Used as a fallback while Phase 3 (CoreAudio Process Tap + aggregate
/// routing) is being finished. Apps that respond:
///   • Music         (set sound volume to 0...100)
///   • Spotify       (set sound volume to 0...100)
///   • TV / Podcasts (set sound volume to 0...100)
///
/// Failures are silent — apps without scripting support just don't respond.
enum AppleScriptVolume {
    /// Get the app's current volume (0...1) via AppleScript.
    /// Returns nil if the app isn't scriptable, isn't running, or denied
    /// permission. Synchronous — call from a background task.
    static func getVolume(for bundleID: String) -> Float? {
        guard let appName = scriptableByBundle[bundleID] else { return nil }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else {
            return nil
        }
        let script = "tell application \"\(appName)\" to get sound volume"
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error),
              error == nil else { return nil }
        let level = Int(result.int32Value)
        return Float(max(0, min(100, level))) / 100.0
    }

    /// Probe an app's AppleScript reachability without changing anything.
    /// If this returns false, the user hasn't granted Automation permission
    /// (System Settings → Privacy & Security → Automation → Fader).
    /// Probing also TRIGGERS the permission dialog the first time.
    static func probe(bundleID: String) -> Bool {
        guard let appName = scriptableByBundle[bundleID] else { return false }
        // Only probe if the app is currently running — querying a not-running
        // app would launch it.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else {
            return false
        }
        let script = "tell application \"\(appName)\" to get sound volume"
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let err = error {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            Self.lastErrorCode = code
            Self.lastError = "AppleScript error \(code) probing \(bundleID)"
            FileHandle.standardError.write(Data("[AppleScriptVolume] probe failed for \(bundleID): code \(code)\n".utf8))
            return false
        }
        Self.lastErrorCode = nil
        Self.lastError = nil
        FileHandle.standardError.write(Data("[AppleScriptVolume] probe ok for \(bundleID): vol=\(result?.int32Value ?? -1)\n".utf8))
        return true
    }

    /// Per-app scripting names that respond to `set sound volume`.
    private static let scriptableByBundle: [String: String] = [
        "com.apple.Music":       "Music",
        "com.spotify.client":    "Spotify",
        "com.apple.TV":          "TV",
        "com.apple.Podcasts":    "Podcasts",
        "com.apple.iTunes":      "iTunes"
    ]

    /// Returns true if this bundle ID responds to AppleScript volume control.
    static func canControl(bundleID: String) -> Bool {
        scriptableByBundle[bundleID] != nil
    }

    /// Coordinator for coalescing rapid volume changes. AppleScript is heavy
    /// (~30-100ms per call); without coalescing, dragging the slider queues
    /// dozens of sequential script runs.
    private actor Coalescer {
        var pending: [String: Int] = [:]
        var inflight: Set<String> = []

        func enqueue(_ value: Int, for bundleID: String) -> Bool {
            pending[bundleID] = value
            if inflight.contains(bundleID) { return false }
            inflight.insert(bundleID)
            return true
        }

        func nextOrDone(for bundleID: String) -> Int? {
            if let v = pending.removeValue(forKey: bundleID) { return v }
            inflight.remove(bundleID)
            return nil
        }
    }
    private static let coalescer = Coalescer()

    /// Set the app's volume (0.0 ... 1.0). Coalesces rapid changes — the
    /// most-recent value wins, intermediate values are dropped.
    static func setVolume(_ value: Float, for bundleID: String) {
        guard let appName = scriptableByBundle[bundleID] else { return }
        let level = Int((max(0, min(1, value)) * 100).rounded())

        Task.detached(priority: .utility) {
            let shouldDrain = await coalescer.enqueue(level, for: bundleID)
            guard shouldDrain else { return }
            while let target = await coalescer.nextOrDone(for: bundleID) {
                let script = "tell application \"\(appName)\" to set sound volume to \(target)"
                runSync(script)
            }
        }
    }

    /// Set or clear mute. Apps don't have a separate mute property — we use
    /// volume 0 for mute. Caller should remember the pre-mute volume.
    static func setMuted(_ muted: Bool, for bundleID: String, restoreTo value: Float) {
        if muted {
            setVolume(0, for: bundleID)
        } else {
            setVolume(value, for: bundleID)
        }
    }

    /// Set when an AppleScript-control attempt fails — tells the UI to show
    /// a "permission required" hint. Atomic-style read/write since multiple
    /// detached tasks may set it.
    static private(set) nonisolated(unsafe) var lastError: String?
    static private(set) nonisolated(unsafe) var lastErrorCode: Int?

    /// -1743 is macOS's fixed error number for "not authorized to send
    /// Apple events to X" — i.e. the user hasn't granted (or has denied)
    /// Automation permission for this specific target app. Any other code
    /// is a real script error, not a permission problem.
    static var isAutomationPermissionDenied: Bool { lastErrorCode == -1743 }

    /// Run synchronously (caller is on a detached task already).
    private static func runSync(_ source: String) {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let err = error {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg  = (err[NSAppleScript.errorMessage] as? String) ?? "unknown"
            let summary = "AppleScript error \(code): \(msg)"
            Self.lastError = summary
            Self.lastErrorCode = code
            FileHandle.standardError.write(Data("[AppleScriptVolume] \(summary)\n".utf8))
            FileHandle.standardError.write(Data("[AppleScriptVolume] → grant via System Settings → Privacy & Security → Automation → Fader → enable target app\n".utf8))
        } else {
            Self.lastError = nil
            Self.lastErrorCode = nil
        }
    }

    private static func run(_ source: String) {
        Task.detached(priority: .utility) { runSync(source) }
    }
}
