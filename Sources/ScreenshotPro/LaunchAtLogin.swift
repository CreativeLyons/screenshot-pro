import Combine
import ScreenshotProCore
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (macOS 13+). The service's status is the
/// source of truth (the user can change it in System Settings > General > Login Items);
/// `settings.launchAtLogin` only mirrors it.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// The last register/unregister error, for the Settings window.
    @Published private(set) var lastError: String?

    private init() { refresh() }

    /// True when registered, including while macOS waits for the user's approval.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// Reads the service status and mirrors it into the settings (bundled app only).
    func refresh() {
        status = SMAppService.mainApp.status
        if status != .notFound, SettingsStore.shared.settings.launchAtLogin != isOn {
            SettingsStore.shared.update { $0.launchAtLogin = isOn }
        }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// A short description of the current state for the Settings window.
    var statusText: String {
        switch status {
        case .enabled: return "Screenshot Pro opens when you log in."
        case .requiresApproval:
            return "Waiting for approval: turn on Screenshot Pro in System Settings > General > Login Items."
        case .notFound: return "Launch at login is only available for the installed app bundle."
        case .notRegistered: return "Screenshot Pro does not open at login."
        @unknown default: return "Launch at login status is unknown."
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
