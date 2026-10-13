import UserNotifications

/// Posts link alerts; shows them as banners even while NetTorque's window is in front.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// The system asks once; afterwards the choice lives in System Settings → Notifications.
    func requestPermission(then done: @escaping () -> Void = {}) {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in DispatchQueue.main.async(execute: done) }
    }

    /// On the main queue: true when notifications are turned off for NetTorque.
    func checkDenied(_ done: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { done(denied) }
        }
    }

    func post(_ alert: LinkAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
