import DeviceActivity
import Foundation

/// Woken by iOS only when an unlock window ends; re-locks the app.
final class AppLockMonitorExtension: DeviceActivityMonitor {
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity.rawValue.hasPrefix(AppLockEngine.relockPrefix) else { return }
        AppLockEngine.relock(activity: activity)
    }
}
