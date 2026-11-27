import ManagedSettings
import UserNotifications

/// Handles the buttons on the lock screen. Extensions can't show Face ID, so
/// "Unlock" remembers which app was tapped and posts a notification that opens
/// Switchboard, where the user authenticates.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // An if-statement keeps this correct if Apple adds new button actions.
        if action == .primaryButtonPressed {
            AppLockEngine.setPending(application)
            postUnlockNotification { completionHandler(.defer) }
        } else {
            completionHandler(.close)
        }
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        // Websites are unlocked from inside Switchboard.
        if action == .primaryButtonPressed {
            postUnlockNotification { completionHandler(.defer) }
        } else {
            completionHandler(.close)
        }
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        if action == .primaryButtonPressed {
            postUnlockNotification { completionHandler(.defer) }
        } else {
            completionHandler(.close)
        }
    }

    private func postUnlockNotification(completion: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Unlock with Face ID"
        content.body = "Tap to confirm it's you."
        content.sound = nil
        content.interruptionLevel = .active
        content.userInfo = ["url": "switchboard://applock/unlock"]
        content.threadIdentifier = "applock"
        let request = UNNotificationRequest(identifier: "applock.unlock", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in completion() }
    }
}
