import Foundation

/// Persists per-app volume + mute state across launches, keyed by bundle ID.
/// Writes are debounced — a slider drag fires far more often than
/// UserDefaults needs to be touched.
@MainActor
final class VolumeStore {
    struct Entry: Codable {
        var volume: Float
        var isMuted: Bool
    }

    private static let key = "com.fader.savedVolumes"

    private(set) var saved: [String: Entry]
    private var saveTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            saved = decoded
        } else {
            saved = [:]
        }
    }

    func entry(for bundleID: String) -> Entry? { saved[bundleID] }

    /// Only schedules a write when something actually changed, so restoring
    /// a value we just loaded doesn't immediately re-trigger a save.
    func update(bundleID: String, volume: Float, isMuted: Bool) {
        let new = Entry(volume: volume, isMuted: isMuted)
        guard saved[bundleID]?.volume != new.volume || saved[bundleID]?.isMuted != new.isMuted else { return }
        saved[bundleID] = new
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
