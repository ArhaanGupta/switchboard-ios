import SwiftUI
import SwitchboardCore

/// Root state: which modules are on, navigation, and the per-module models.
@MainActor
@Observable
final class AppModel {
    private let flags = FeatureFlags()
    private(set) var enabled: [ModuleID: Bool] = [:]

    var path: [ModuleID] = []
    var toast: Toast?

    let clipboard = ClipboardModel()
    let sticky = StickyNotesModel()
    let shield = ShieldController()
    let share = LocalSendService()
    let floating = FloatingController()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let symbol: String
        let message: String
    }

    init() {
        for module in ModuleID.allCases { enabled[module] = flags.isEnabled(module) }
    }

    func isEnabled(_ module: ModuleID) -> Bool { enabled[module] ?? module.enabledByDefault }

    var enabledCount: Int { ModuleID.allCases.filter(isEnabled).count }

    func setEnabled(_ on: Bool, for module: ModuleID) {
        guard isEnabled(module) != on else { return }
        enabled[module] = on
        flags.setEnabled(on, for: module)
        Haptics.tap()
        if !on { tearDown(module) }
    }

    /// Stops anything running in the background when a module is switched off.
    private func tearDown(_ module: ModuleID) {
        switch module {
        case .clipboard, .stickyNotes:
            if module == .stickyNotes { sticky.endAllActivities() }
        case .shield:
            Task { await shield.stop() }
        case .shareAnywhere:
            share.stop()
        case .floatingWindow:
            floating.stop()
        }
    }

    // MARK: Lifecycle

    func appBecameActive() {
        clipboard.reload()
        sticky.reload()
        if isEnabled(.clipboard) { clipboard.captureOnOpenIfNeeded() }
        if isEnabled(.shield) { Task { await shield.refresh() } }
    }

    // MARK: Deep links

    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        let module = link.module
        if !isEnabled(module) { setEnabled(true, for: module) }
        path = [module]
        switch link {
        case .saveClipboard:
            if clipboard.saveCurrentClipboard() {
                show("doc.on.clipboard.fill", "Saved to clipboard history")
            }
        case .newStickyNote:
            sticky.composeNew()
        case .floating(let raw):
            if let mode = FloatingController.Mode(rawValue: raw) { floating.mode = mode }
        case .receiveFiles:
            share.start()
        case .module:
            break
        }
    }

    func show(_ symbol: String, _ message: String) {
        withAnimation(.bouncy) { toast = Toast(symbol: symbol, message: message) }
        let id = toast?.id
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast?.id == id { withAnimation(.smooth) { toast = nil } }
        }
    }
}
