import FamilyControls
import LocalAuthentication
import ManagedSettings
import SwiftUI
import SwitchboardCore
import UserNotifications

@MainActor
@Observable
final class AppLockModel {
    private(set) var authorization: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
    private(set) var notificationsAllowed = false
    private(set) var selection = FamilyActivitySelection()
    private(set) var grants: [UnlockGrant] = []
    private(set) var pendingToken: ApplicationToken?
    private(set) var unlockMinutes = AppLockEngine.minimumMinutes
    var errorMessage: String?

    init() { reload() }

    var isAuthorized: Bool { authorization == .approved }

    var lockedCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
    }

    var activeGrants: [UnlockGrant] { grants.filter { $0.until > .now } }

    var statusText: String {
        guard isAuthorized else { return "Needs Screen Time access" }
        guard lockedCount > 0 else { return "No apps chosen" }
        return "\(lockedCount) locked"
    }

    func reload() {
        authorization = AuthorizationCenter.shared.authorizationStatus
        let state = AppLockEngine.state()
        selection = state.selection
        grants = state.grants
        pendingToken = state.pendingToken
        unlockMinutes = state.unlockMinutes
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsAllowed = settings.authorizationStatus == .authorized
        }
    }

    // MARK: Setup

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            errorMessage = "Screen Time access wasn't granted. \(error.localizedDescription)"
        }
        authorization = AuthorizationCenter.shared.authorizationStatus
        if isAuthorized { AppLockEngine.applyShield() }
    }

    func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])) ?? false
        notificationsAllowed = granted
    }

    func setSelection(_ newValue: FamilyActivitySelection) {
        selection = newValue
        AppLockEngine.update { $0.selection = newValue }
        AppLockEngine.applyShield()
    }

    func setUnlockMinutes(_ minutes: Int) {
        unlockMinutes = minutes
        AppLockEngine.update { $0.unlockMinutes = minutes }
    }

    // MARK: Lock / unlock

    func moduleEnabled() {
        if isAuthorized { AppLockEngine.applyShield() }
    }

    func moduleDisabled() {
        AppLockEngine.clearShield()
    }

    func relockAll() {
        AppLockEngine.relockAllNow()
        reload()
        Haptics.success()
    }

    /// Face ID (or passcode), then unlock the pending app for `unlockMinutes`.
    func unlockPending() async {
        reload()
        guard let token = pendingToken else { return }
        guard await authenticate(reason: "Unlock the app you just tapped") else { return }
        do {
            try AppLockEngine.grantUnlock(token, minutes: unlockMinutes)
            Haptics.success()
        } catch {
            errorMessage = "Couldn't unlock: \(error.localizedDescription)"
        }
        reload()
    }

    func cancelPending() {
        AppLockEngine.update { $0.pendingToken = nil }
        reload()
    }

    /// Changing what's locked also requires Face ID, so nobody can quietly remove a lock.
    func authenticateToEdit() async -> Bool {
        lockedCount == 0 ? true : await authenticate(reason: "Change which apps are locked")
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            if (error as? LAError)?.code != .userCancel {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }
}
