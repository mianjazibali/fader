import Foundation
import AppKit

/// Audio process taps don't require TCC microphone permission, but reading
/// process bundle IDs / icons benefits from a couple of hooks. Phase 3 will
/// expand this with Audio capture entitlement checks if Apple tightens APIs.
@MainActor
final class PermissionsManager {
    enum Permission: String, CaseIterable {
        case accessibility      // for global hotkeys (AppKit-only path)
        case systemAudioCapture // Process Tap per-app audio capture (TCC, macOS 14.4+)

        var humanLabel: String {
            switch self {
            case .accessibility:      return "Accessibility (for global hotkeys)"
            case .systemAudioCapture: return "Screen & System Audio Recording"
            }
        }
    }

    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .systemAudioCapture:
            // No synchronous "check without prompting" API — see
            // AudioState's behavioral detection (real silence on an
            // installed, active tap) for how this is actually inferred.
            return true
        }
    }

    /// Prompts the user; returns immediately, system handles UI.
    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            // Avoid the global-var Sendable warning by using the literal key.
            let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(opts)
        case .systemAudioCapture:
            // Prompted implicitly the first time Fader actually starts the
            // capture IOProc — there's no separate explicit-request call.
            break
        }
    }

    func openSystemSettings(for permission: Permission) {
        let url: URL? = {
            switch permission {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .systemAudioCapture:
                // Same pane Apple renamed "Screen Recording" to "Screen &
                // System Audio Recording" in — the URL fragment stayed put.
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }()
        if let url { NSWorkspace.shared.open(url) }
    }
}
