import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import SwitchboardCore

/// Temporary access to one locked app after a successful Face ID unlock.
struct UnlockGrant: Codable, Hashable {
    var id = UUID()
    var token: ApplicationToken
    var until: Date
}

struct AppLockState: Codable {
    var selection = FamilyActivitySelection()
    var grants: [UnlockGrant] = []
    /// The app whose shield "Unlock" button was tapped most recently.
    var pendingToken: ApplicationToken?
    var unlockMinutes = 15
}

/// Shared by the app and the three App Lock extensions.
///
/// iOS enforces the lock itself through ManagedSettings, so Switchboard runs
/// nothing in the background: extensions are woken only when a locked app is
/// tapped or an unlock window ends.
enum AppLockEngine {
    static let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("switchboard.applock"))
    static let center = DeviceActivityCenter()
    static let relockPrefix = "switchboard.relock."
    /// DeviceActivity can't schedule intervals shorter than this.
    static let minimumMinutes = 15

    private static let file = JSONFile<AppLockState>(name: "app-lock.json")

    static func state() -> AppLockState { file.load() ?? AppLockState() }

    @discardableResult
    static func update(_ change: (inout AppLockState) -> Void) -> AppLockState {
        file.mutate(default: AppLockState(), change)
    }

    // MARK: Shielding

    /// Applies the current selection, leaving out apps with an active unlock.
    static func applyShield(now: Date = .now) {
        guard FeatureFlags().isEnabled(.appLock) else { return clearShield() }
        let current = update { $0.grants.removeAll { $0.until <= now } }
        let unlocked = Set(current.grants.map(\.token))
        let apps = current.selection.applicationTokens.subtracting(unlocked)
        let categories = current.selection.categoryTokens

        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories, except: unlocked)
        store.shield.webDomains = current.selection.webDomainTokens.isEmpty ? nil : current.selection.webDomainTokens
    }

    static func clearShield() {
        store.clearAllSettings()
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix(relockPrefix) })
    }

    // MARK: Unlocking

    static func setPending(_ token: ApplicationToken) {
        update { $0.pendingToken = token }
    }

    /// Unshields `token` for `minutes`, and asks DeviceActivity to wake the
    /// monitor extension when the window ends so the app is re-locked.
    static func grantUnlock(_ token: ApplicationToken, minutes: Int, now: Date = .now) throws {
        let minutes = max(minutes, minimumMinutes)
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        let grant = UnlockGrant(token: token, until: until)
        update {
            $0.grants.removeAll { $0.token == token || $0.until <= now }
            $0.grants.append(grant)
            $0.pendingToken = nil
        }
        applyShield(now: now)

        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: Calendar.current.dateComponents(components, from: now),
            intervalEnd: Calendar.current.dateComponents(components, from: until),
            repeats: false
        )
        do {
            try center.startMonitoring(DeviceActivityName(relockPrefix + grant.id.uuidString), during: schedule)
        } catch {
            // Without a relock timer the app would stay open; undo the grant.
            update { $0.grants.removeAll { $0.id == grant.id } }
            applyShield(now: now)
            throw error
        }
    }

    /// Called by the monitor extension when an unlock window ends.
    static func relock(activity: DeviceActivityName) {
        center.stopMonitoring([activity])
        applyShield()
    }

    static func relockAllNow() {
        update { $0.grants.removeAll() }
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix(relockPrefix) })
        applyShield()
    }
}
