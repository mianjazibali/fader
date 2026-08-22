import Foundation

/// Persists the Settings panel's toggles/sliders across launches. Per-app
/// volumes are VolumeStore's job — this is everything else in Settings
/// (ducking, the call-control opt-in). Plain UserDefaults reads/writes;
/// nothing here is hot enough to need VolumeStore's debounce-and-batch
/// treatment except `duckingAmount`, which AudioState debounces itself
/// before calling in here.
@MainActor
struct SettingsStore {
    private static let duckingEnabledKey = "com.fader.duckingEnabled"
    private static let duckingAmountKey = "com.fader.duckingAmount"
    private static let allowCallControlKey = "com.fader.allowVolumeControlDuringCalls"

    private let defaults = UserDefaults.standard

    var duckingEnabled: Bool {
        get { defaults.object(forKey: Self.duckingEnabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.duckingEnabledKey) }
    }

    var duckingAmount: Float {
        get {
            guard defaults.object(forKey: Self.duckingAmountKey) != nil else { return 0.5 }
            return defaults.float(forKey: Self.duckingAmountKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.duckingAmountKey) }
    }

    var allowVolumeControlDuringCalls: Bool {
        get { defaults.object(forKey: Self.allowCallControlKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.allowCallControlKey) }
    }
}
