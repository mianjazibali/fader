import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService` (macOS 13+ — well within Fader's
/// 14.2+ floor), replacing the deprecated `SMLoginItemSetEnabled`.
@MainActor
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True once registered but the user still needs to approve it in
    /// System Settings → General → Login Items — `register()` doesn't
    /// fail in this case, it just doesn't take effect until approved.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data("[LoginItemManager] failed to \(enabled ? "register" : "unregister"): \(error)\n".utf8))
        }
    }
}
