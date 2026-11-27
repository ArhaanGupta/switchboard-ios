import ActivityKit
import AppIntents
import SwiftUI
import SwitchboardCore
import WidgetKit

/// Sticky note on the Lock Screen and in the Dynamic Island.
struct StickyNoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StickyNoteAttributes.self) { context in
            LockScreenNoteView(state: context.state, noteID: context.attributes.noteID)
                .activityBackgroundTint(context.state.color.color.opacity(0.92))
                .activitySystemActionForegroundColor(.black)
                .widgetURL(DeepLink.module(.stickyNotes).url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "note.text")
                        .font(.title3)
                        .foregroundStyle(state.color.color)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let progress = state.progressText {
                        Text(progress).font(.headline.monospacedDigit()).foregroundStyle(state.color.color)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !state.body.isEmpty {
                            Text(state.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        ForEach(state.items.prefix(3)) { item in
                            ChecklistRow(item: item, noteID: context.attributes.noteID, tint: state.color.color)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "note.text").foregroundStyle(state.color.color)
            } compactTrailing: {
                if let progress = state.progressText {
                    Text(progress).font(.caption.monospacedDigit()).foregroundStyle(state.color.color)
                } else {
                    Text(state.title).font(.caption).lineLimit(1).frame(maxWidth: 64)
                }
            } minimal: {
                Image(systemName: "note.text").foregroundStyle(state.color.color)
            }
            .keylineTint(state.color.color)
        }
    }
}

private struct LockScreenNoteView: View {
    let state: StickyNoteAttributes.ContentState
    let noteID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(state.title, systemImage: "note.text")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let progress = state.progressText {
                    Text(progress).font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            if !state.body.isEmpty {
                Text(state.body).font(.subheadline).lineLimit(3).opacity(0.85)
            }
            ForEach(state.items.prefix(4)) { item in
                ChecklistRow(item: item, noteID: noteID, tint: .black)
            }
        }
        .foregroundStyle(.black.opacity(0.85))
        .padding(16)
    }
}

private struct ChecklistRow: View {
    let item: ChecklistItem
    let noteID: UUID
    let tint: Color

    var body: some View {
        Button(intent: ToggleChecklistItemIntent(noteID: noteID, itemID: item.id)) {
            HStack(spacing: 8) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(tint)
                Text(item.text)
                    .strikethrough(item.done)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
        }
        .buttonStyle(.plain)
    }
}
