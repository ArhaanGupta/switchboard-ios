import UIKit
import UserNotifications

/// Routes taps on Switchboard notifications (e.g. App Lock's "Unlock with
/// Face ID") to the deep link stored in the notification.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var openURL: ((URL) -> Void)?
    private var pendingURL: URL?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Delivers a URL that arrived before the UI was ready.
    func connect(_ handler: @escaping (URL) -> Void) {
        openURL = handler
        if let pendingURL {
            self.pendingURL = nil
            handler(pendingURL)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string) else { return }
        await MainActor.run {
            if let openURL { openURL(url) } else { pendingURL = url }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
