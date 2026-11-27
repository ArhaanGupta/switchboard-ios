import ClipboardCore
import SwiftUI
import SwitchboardCore
import UIKit

@MainActor
@Observable
final class ClipboardModel {
    private let store = ClipboardStore.shared
    private let defaults = AppGroup.defaults

    private(set) var items: [ClipItem] = []
    private(set) var snippets: [Snippet] = []
    private(set) var settings = ClipboardSettings()
    var query = ""
    var returnAfterPaste: Bool {
        didSet { defaults.set(returnAfterPaste, forKey: SharedKey.keyboardReturnAfterPaste) }
    }

    init() {
        returnAfterPaste = AppGroup.defaults.object(forKey: SharedKey.keyboardReturnAfterPaste) as? Bool ?? true
        reload()
    }

    var filteredItems: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    func reload() {
        let db = store.database()
        items = ClipboardStore.sortedForDisplay(db.items)
        snippets = db.snippets
        settings = db.settings
    }

    // MARK: Capture

    /// Saves whatever is on the clipboard now. iOS shows its paste-permission
    /// prompt unless the user chose "Allow" for Switchboard in Settings.
    @discardableResult
    func saveCurrentClipboard() -> Bool {
        let board = UIPasteboard.general
        guard board.hasStrings || board.hasURLs, let text = board.string ?? board.url?.absoluteString else {
            return false
        }
        defaults.set(board.changeCount, forKey: SharedKey.pasteboardChangeCount)
        return add(text)
    }

    /// Called from `PasteButton`, which never triggers the permission prompt.
    func savePasted(_ strings: [String]) {
        for s in strings { add(s) }
    }

    func captureOnOpenIfNeeded() {
        guard settings.captureOnAppOpen else { return }
        let count = UIPasteboard.general.changeCount
        guard count != defaults.integer(forKey: SharedKey.pasteboardChangeCount) else { return }
        saveCurrentClipboard()
    }

    @discardableResult
    private func add(_ text: String) -> Bool {
        let added = store.add(text: text) != nil
        reload()
        return added
    }

    // MARK: Actions

    func copy(_ item: ClipItem) {
        UIPasteboard.general.string = item.text
        // Don't re-capture our own copy.
        defaults.set(UIPasteboard.general.changeCount, forKey: SharedKey.pasteboardChangeCount)
        store.markUsed(item.id)
        Haptics.success()
        reload()
    }

    func togglePin(_ item: ClipItem) { store.togglePin(item.id); reload() }
    func delete(_ item: ClipItem) { store.delete(item.id); reload() }
    func clearUnpinned() { store.clearUnpinned(); reload() }

    func save(_ snippet: Snippet) { store.upsertSnippet(snippet); reload() }
    func deleteSnippets(at offsets: IndexSet) {
        for i in offsets { store.deleteSnippet(snippets[i].id) }
        reload()
    }
    func moveSnippets(from: IndexSet, to: Int) { store.moveSnippets(fromOffsets: from, toOffset: to); reload() }

    func setCaptureOnOpen(_ on: Bool) { store.updateSettings { $0.captureOnAppOpen = on }; reload() }
    func setMaxItems(_ n: Int) { store.updateSettings { $0.maxItems = n }; reload() }

    // MARK: Keyboard status (written by the keyboard extension)

    var keyboardSeen: Bool { defaults.object(forKey: SharedKey.keyboardLastSeen) != nil }
    var keyboardHasFullAccess: Bool { defaults.bool(forKey: SharedKey.keyboardHasFullAccess) }
}

extension ClipboardStore {
    static func sortedForDisplay(_ items: [ClipItem]) -> [ClipItem] {
        items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastUsedAt > $1.lastUsedAt
        }
    }
}
