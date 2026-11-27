import ActivityKit
import AppIntents
import Foundation
import SwitchboardCore
import WidgetKit

/// Live Activity that pins a note to the Lock Screen and Dynamic Island.
struct StickyNoteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var body: String
        var items: [ChecklistItem]
        var color: NoteColor

        init(note: StickyNote) {
            title = note.displayTitle
            body = note.body
            items = note.items
            color = note.color
        }

        var progressText: String? {
            items.isEmpty ? nil : "\(items.filter(\.done).count)/\(items.count)"
        }
    }

    var noteID: UUID
}

/// Ticks a checklist item from the Live Activity or the widget without
/// opening the app.
struct ToggleChecklistItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Checklist Item"
    static let isDiscoverable = false

    @Parameter(title: "Note ID") var noteID: String
    @Parameter(title: "Item ID") var itemID: String

    init() {}

    init(noteID: UUID, itemID: UUID) {
        self.noteID = noteID.uuidString
        self.itemID = itemID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let noteUUID = UUID(uuidString: noteID), let itemUUID = UUID(uuidString: itemID),
              let note = StickyNoteStore.shared.toggleItem(itemUUID, inNote: noteUUID) else {
            return .result()
        }
        await StickyNoteActivitySync.update(note)
        WidgetCenter.shared.reloadTimelines(ofKind: StickyNoteActivitySync.widgetKind)
        return .result()
    }
}

enum StickyNoteActivitySync {
    static let widgetKind = "StickyNoteWidget"

    static func activity(for noteID: UUID) -> Activity<StickyNoteAttributes>? {
        Activity<StickyNoteAttributes>.activities.first { $0.attributes.noteID == noteID }
    }

    static func update(_ note: StickyNote) async {
        guard let activity = activity(for: note.id) else { return }
        await activity.update(ActivityContent(state: .init(note: note), staleDate: nil))
    }
}
