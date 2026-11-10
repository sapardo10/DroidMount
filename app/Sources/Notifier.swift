import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for the menu-bar agent's
/// user-facing alerts (mount / unmount / disconnect / transfer results).
/// An accessory app posts notifications the same way any app does.
final class Notifier {
    static let shared = Notifier()
    private init() {}

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(_ id: String, title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}