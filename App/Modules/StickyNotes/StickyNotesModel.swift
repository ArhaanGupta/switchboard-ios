import ActivityKit
import SwiftUI
import SwitchboardCore
import WidgetKit

@MainActor
@Observable
final class StickyNotesModel {
    private let store = StickyNoteStore.shared

    private(set) var notes: [StickyNote] = []
    private(set) var widgetNoteID: UUID?
    private(set) var liveNoteIDs: Set<UUID> = []
    var editing: StickyNote?
    var errorMessage: String?

    init() { reload() }

    func reload() {
        let db = store.database()
        notes = db.notes.sorted { $0.updatedAt > $1.updatedAt }
        widgetNoteID = db.widgetNoteID
        liveNoteIDs = Set(Activity<StickyNoteAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map(\.attributes.noteID))
    }

    var liveActivitiesAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func composeNew() {
        editing = StickyNote(color: NoteColor.allCases.randomElement() ?? .lemon)
    }

    func save(_ note: StickyNote) {
        let isFirst = notes.isEmpty
        store.upsert(note)
        if isFirst || widgetNoteID == nil { store.setWidgetNote(id: note.id) }
        reload()
        WidgetCenter.shared.reloadTimelines(ofKind: StickyNoteActivitySync.widgetKind)
        if liveNoteIDs.contains(note.id), let saved = store.note(id: note.id) {
            Task { await StickyNoteActivitySync.update(saved) }
        }
    }

    func delete(_ note: StickyNote) {
        stopLive(note)
        store.delete(id: note.id)
        reload()
        WidgetCenter.shared.reloadTimelines(ofKind: StickyNoteActivitySync.widgetKind)
    }

    func toggle(_ item: ChecklistItem, in note: StickyNote) {
        guard let updated = store.toggleItem(item.id, inNote: note.id) else { return }
        reload()
        WidgetCenter.shared.reloadTimelines(ofKind: StickyNoteActivitySync.widgetKind)
        Task { await StickyNoteActivitySync.update(updated) }
    }

    // MARK: Widget

    func showOnWidget(_ note: StickyNote) {
        store.setWidgetNote(id: note.id)
        reload()
        WidgetCenter.shared.reloadTimelines(ofKind: StickyNoteActivitySync.widgetKind)
        Haptics.success()
    }

    // MARK: Live Activity (Lock Screen + Dynamic Island)

    func startLive(_ note: StickyNote) {
        guard StickyNoteActivitySync.activity(for: note.id) == nil else { return }
        do {
            _ = try Activity.request(
                attributes: StickyNoteAttributes(noteID: note.id),
                content: ActivityContent(state: .init(note: note), staleDate: nil),
                pushType: nil
            )
            Haptics.success()
        } catch {
            errorMessage = "Couldn't pin the note: \(error.localizedDescription)"
        }
        reload()
    }

    func stopLive(_ note: StickyNote) {
        guard let activity = StickyNoteActivitySync.activity(for: note.id) else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            reload()
        }
    }

    func endAllActivities() {
        Task {
            for activity in Activity<StickyNoteAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            reload()
        }
    }
}
