import Foundation

public struct ChecklistItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var done: Bool

    public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

public enum NoteColor: String, Codable, CaseIterable, Sendable, Hashable {
    case lemon, mint, sky, rose, lavender, graphite
}

public struct StickyNote: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var items: [ChecklistItem]
    public var color: NoteColor
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "", body: String = "",
                items: [ChecklistItem] = [], color: NoteColor = .lemon,
                createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.body = body
        self.items = items
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled note" : firstLine
    }

    public var completedCount: Int { items.filter(\.done).count }
}

public struct StickyNotesDatabase: Codable, Sendable {
    public var notes: [StickyNote] = []
    /// The note shown by the Lock Screen / Home Screen widget.
    public var widgetNoteID: UUID?

    public init(notes: [StickyNote] = [], widgetNoteID: UUID? = nil) {
        self.notes = notes
        self.widgetNoteID = widgetNoteID
    }
}

/// Shared persistence for sticky notes (app, widgets and Live Activity intents).
public final class StickyNoteStore {
    public static let shared = StickyNoteStore()

    private let file: JSONFile<StickyNotesDatabase>

    public init(file: JSONFile<StickyNotesDatabase> = JSONFile(name: "sticky-notes.json")) {
        self.file = file
    }

    public func database() -> StickyNotesDatabase { file.load() ?? StickyNotesDatabase() }

    public func notes() -> [StickyNote] {
        database().notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func note(id: UUID) -> StickyNote? { database().notes.first { $0.id == id } }

    public func widgetNote() -> StickyNote? {
        let db = database()
        guard let id = db.widgetNoteID else { return nil }
        return db.notes.first { $0.id == id }
    }

    public func upsert(_ note: StickyNote) {
        var note = note
        note.updatedAt = .now
        file.mutate(default: StickyNotesDatabase()) { db in
            if let i = db.notes.firstIndex(where: { $0.id == note.id }) {
                db.notes[i] = note
            } else {
                db.notes.append(note)
            }
        }
    }

    public func delete(id: UUID) {
        file.mutate(default: StickyNotesDatabase()) { db in
            db.notes.removeAll { $0.id == id }
            if db.widgetNoteID == id { db.widgetNoteID = nil }
        }
    }

    public func setWidgetNote(id: UUID?) {
        file.mutate(default: StickyNotesDatabase()) { $0.widgetNoteID = id }
    }

    /// Toggles a checklist item and returns the updated note.
    @discardableResult
    public func toggleItem(_ itemID: UUID, inNote noteID: UUID) -> StickyNote? {
        var updated: StickyNote?
        file.mutate(default: StickyNotesDatabase()) { db in
            guard let n = db.notes.firstIndex(where: { $0.id == noteID }),
                  let i = db.notes[n].items.firstIndex(where: { $0.id == itemID }) else { return }
            db.notes[n].items[i].done.toggle()
            db.notes[n].updatedAt = .now
            updated = db.notes[n]
        }
        return updated
    }
}
