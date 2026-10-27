import AppKit
import UserNotifications

/// Posts "exported" notifications through UserNotifications.
///
/// Authorization is requested the first time a notification is about to be posted, not at
/// launch. File notifications carry the file URL; clicking one reveals the file in Finder, and
/// the "Open" action opens it in its default app.
@MainActor
final class NotificationController: NSObject {
    static let shared = NotificationController()

    nonisolated private static let fileCategory = "ScreenshotPro.file"
    nonisolated private static let revealAction = "ScreenshotPro.reveal"
    nonisolated private static let openAction = "ScreenshotPro.open"
    nonisolated private static let fileURLKey = "fileURL"

    private var isConfigured = false

    /// UserNotifications needs a real app bundle; `swift run` executables have none and would crash.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Sets the delegate (so notifications show while the app is active) and the file actions.
    func configure() {
        guard isAvailable, !isConfigured else { return }
        isConfigured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder")
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open")
        let category = UNNotificationCategory(identifier: Self.fileCategory, actions: [reveal, open],
                                              intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    /// Posts one notification. `fileURL` makes it a file notification with Finder actions.
    func post(title: String, body: String, fileURL: URL?) {
        guard isAvailable else { return }
        configure()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL {
            content.categoryIdentifier = Self.fileCategory
            content.userInfo = [Self.fileURLKey: fileURL.path]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            // Prompts only the first time; afterwards it returns the stored decision.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    fileprivate func handle(action: String, path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if action == Self.openAction {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let path = response.notification.request.content.userInfo[NotificationController.fileURLKey] as? String
        completionHandler()
        guard action != UNNotificationDismissActionIdentifier else { return }
        Task { @MainActor in
            NotificationController.shared.handle(action: action, path: path)
        }
    }
}
