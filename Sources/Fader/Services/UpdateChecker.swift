import Foundation

/// Checks GitHub's releases API for a newer tagged version than the
/// running build, and surfaces it via `AudioState.updateAvailable`.
///
/// Deliberately not a Sparkle-style silent background installer — Fader
/// is ad-hoc signed, not Developer ID + notarized, so a silent auto-
/// install would itself trip Gatekeeper the same way a fresh download
/// does. This just checks and prompts; the user still goes through the
/// normal (one-time, already-documented) first-launch approval on
/// whatever they download next.
@MainActor
final class UpdateChecker {
    private static let repo = "mianjazibali/fader"
    private static let lastCheckKey = "com.fader.lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private weak var state: AudioState?
    private var task: Task<Void, Never>?

    init(state: AudioState) {
        self.state = state
    }

    func start() {
        // Strong self-capture, deliberately — see EngagementTracker's
        // matching comment for why: this task is what keeps the checker
        // alive for the app's lifetime, not the @State var holding it.
        task = Task {
            // Give the app a moment to finish launching before the first
            // network call, then recheck once a day for as long as this
            // (typically long-running, menu-bar-only) process stays up.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self.checkIfDue()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func checkIfDue() async {
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval {
            return
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        await check()
    }

    private func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        else {
            return
        }

        let latest = Self.parseVersion(tag)
        let current = Self.parseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        guard Self.isNewer(latest, than: current) else { return }

        let display = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        state?.updateAvailable = (version: display, url: htmlURL)
    }

    /// Parses "v1.2.3" / "1.2.3" into [1, 2, 3]. Missing/non-numeric
    /// components read as 0, so "1.2" and "1.2.0" compare equal.
    private static func parseVersion(_ raw: String) -> [Int] {
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        return stripped.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
