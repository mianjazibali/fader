import Foundation

/// Tracks cumulative time Fader has actually been running (summed across
/// every launch, not wall-clock time since install) and surfaces a
/// support prompt exactly once, ever, after 24 hours of that.
///
/// The "shown" flag is written to `UserDefaults` the instant the prompt
/// becomes eligible — not when the user dismisses it — so it can never
/// reappear on a later launch even if the app quits before they act on
/// it. This is a one-shot lifetime ask, not a recurring nag.
@MainActor
final class EngagementTracker {
    private static let cumulativeSecondsKey = "com.fader.cumulativeUsageSeconds"
    private static let promptShownKey = "com.fader.supportPromptShown"
    private static let threshold: TimeInterval = 24 * 60 * 60
    private static let tickInterval: TimeInterval = 30

    private weak var state: AudioState?
    private var task: Task<Void, Never>?

    init(state: AudioState) {
        self.state = state
    }

    func start() {
        guard !UserDefaults.standard.bool(forKey: Self.promptShownKey) else { return }

        // Strong self-capture, deliberately: this tracker is meant to run
        // for the app's whole lifetime, and the task itself is what keeps
        // it alive — `stop()` cancels it, which lets the next loop check
        // exit and release the reference naturally.
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                self.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.promptShownKey) else {
            stop()
            return
        }

        let cumulative = defaults.double(forKey: Self.cumulativeSecondsKey) + Self.tickInterval
        defaults.set(cumulative, forKey: Self.cumulativeSecondsKey)

        guard cumulative >= Self.threshold else { return }

        // Mark shown immediately, before the user has seen or acted on
        // anything — eligibility itself is the one-time event.
        defaults.set(true, forKey: Self.promptShownKey)
        state?.showSupportPrompt = true
        stop()
    }
}
