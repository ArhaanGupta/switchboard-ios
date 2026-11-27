import Foundation
import SwitchboardCore

/// Clipboard history + snippets, shared between the app and the keyboard.
/// Every mutation re-reads the file, so concurrent writers don't clobber
/// each other.
public final class ClipboardStore {
    public static let shared = ClipboardStore()

    private let file: JSONFile<ClipboardDatabase>

    public init(file: JSONFile<ClipboardDatabase> = JSONFile(name: "clipboard.json")) {
        self.file = file
    }

    // MARK: Reading

    public func database() -> ClipboardDatabase { file.load() ?? ClipboardDatabase() }

    /// Pinned first, then most recently used.
    public func items() -> [ClipItem] { Self.sorted(database().items) }

    public func snippets() -> [Snippet] { database().snippets }

    public func settings() -> ClipboardSettings { database().settings }

    public func search(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items() }
        return items().filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Writing

    /// Adds text to the history. Duplicates are moved to the top instead of
    /// being stored twice. Returns nil for empty/whitespace-only text.
    @discardableResult
    public func add(text: String, at date: Date = .now) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var result: ClipItem?
        file.mutate(default: ClipboardDatabase()) { db in
            if let i = db.items.firstIndex(where: { $0.text == text }) {
                db.items[i].lastUsedAt = date
                result = db.items[i]
            } else {
                let item = ClipItem(text: text, createdAt: date)
                db.items.append(item)
                result = item
            }
            db.items = Self.pruned(db.items, max: db.settings.maxItems)
        }
        return result
    }

    public func markUsed(_ id: UUID, at date: Date = .now) {
        update(id) { $0.lastUsedAt = date }
    }

    public func togglePin(_ id: UUID) {
        update(id) { $0.isPinned.toggle() }
    }

    public func delete(_ id: UUID) {
        file.mutate(default: ClipboardDatabase()) { db in db.items.removeAll { $0.id == id } }
    }

    public func clearUnpinned() {
        file.mutate(default: ClipboardDatabase()) { db in db.items.removeAll { !$0.isPinned } }
    }

    public func upsertSnippet(_ snippet: Snippet) {
        file.mutate(default: ClipboardDatabase()) { db in
            if let i = db.snippets.firstIndex(where: { $0.id == snippet.id }) {
                db.snippets[i] = snippet
            } else {
                db.snippets.append(snippet)
            }
        }
    }

    public func deleteSnippet(_ id: UUID) {
        file.mutate(default: ClipboardDatabase()) { db in db.snippets.removeAll { $0.id == id } }
    }

    public func moveSnippets(fromOffsets source: IndexSet, toOffset destination: Int) {
        file.mutate(default: ClipboardDatabase()) { db in
            let moving = source.sorted().map { db.snippets[$0] }
            for index in source.sorted(by: >) { db.snippets.remove(at: index) }
            let adjusted = destination - source.filter { $0 < destination }.count
            db.snippets.insert(contentsOf: moving, at: max(0, min(adjusted, db.snippets.count)))
        }
    }

    public func updateSettings(_ change: (inout ClipboardSettings) -> Void) {
        file.mutate(default: ClipboardDatabase()) { db in
            change(&db.settings)
            db.items = Self.pruned(db.items, max: db.settings.maxItems)
        }
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        file.mutate(default: ClipboardDatabase()) { db in
            if let i = db.items.firstIndex(where: { $0.id == id }) { change(&db.items[i]) }
        }
    }

    static func sorted(_ items: [ClipItem]) -> [ClipItem] {
        items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastUsedAt > $1.lastUsedAt
        }
    }

    /// Keeps every pinned item plus the newest unpinned items up to `max`.
    static func pruned(_ items: [ClipItem], max: Int) -> [ClipItem] {
        let pinned = items.filter(\.isPinned)
        let unpinned = items.filter { !$0.isPinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        return pinned + unpinned.prefix(Swift.max(0, max))
    }
}
