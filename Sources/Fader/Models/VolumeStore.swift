import Foundation

/// Persists per-app volume + mute state across launches, keyed by bundle ID.
/// Writes are debounced — a slider drag fires far more often than
/// UserDefaults needs to be touched.
@MainActor
final class VolumeStore {
    struct Entry: Codable {
        var volume: Float
        var isMuted: Bool
        var isBoosted: Bool

        init(volume: Float, isMuted: Bool, isBoosted: Bool) {
            self.volume = volume
            self.isMuted = isMuted
            self.isBoosted = isBoosted
        }

        // Custom decode so entries saved before `isBoosted` existed
        // (missing the key entirely) default to false instead of failing
        // to decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            volume = try c.decode(Float.self, forKey: .volume)
            isMuted = try c.decode(Bool.self, forKey: .isMuted)
            isBoosted = try c.decodeIfPresent(Bool.self, forKey: .isBoosted) ?? false
        }
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
    func update(bundleID: String, volume: Float, isMuted: Bool, isBoosted: Bool) {
        let new = Entry(volume: volume, isMuted: isMuted, isBoosted: isBoosted)
        guard saved[bundleID]?.volume != new.volume
           || saved[bundleID]?.isMuted != new.isMuted
           || saved[bundleID]?.isBoosted != new.isBoosted else { return }
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
