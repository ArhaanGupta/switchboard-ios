import AppIntents
import SwiftUI
import SwitchboardCore
import WidgetKit

struct StickyNoteEntry: TimelineEntry {
    let date: Date
    let note: StickyNote?
    let moduleEnabled: Bool
}

struct StickyNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> StickyNoteEntry {
        StickyNoteEntry(date: .now, note: .sample, moduleEnabled: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StickyNoteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StickyNoteEntry>) -> Void) {
        // The app and intents reload this widget whenever the note changes.
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> StickyNoteEntry {
        StickyNoteEntry(date: .now,
                        note: StickyNoteStore.shared.widgetNote(),
                        moduleEnabled: FeatureFlags().isEnabled(.stickyNotes))
    }
}

/// Permanent sticky note for the Lock Screen and Home Screen.
struct StickyNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StickyNoteActivitySync.widgetKind, provider: StickyNoteProvider()) { entry in
            StickyNoteWidgetView(entry: entry)
                .widgetURL(DeepLink.module(.stickyNotes).url)
        }
        .configurationDisplayName("Sticky Note")
        .description("Keep a note or checklist on your Lock Screen or Home Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .systemSmall, .systemMedium, .systemLarge])
    }
}

struct StickyNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StickyNoteEntry

    var body: some View {
        Group {
            if !entry.moduleEnabled {
                placeholder("Sticky Notes is off")
            } else if let note = entry.note {
                switch family {
                case .accessoryInline:
                    Label(note.displayTitle, systemImage: "note.text")
                case .accessoryRectangular:
                    rectangular(note)
                default:
                    full(note)
                }
            } else {
                placeholder("Tap to create a note")
            }
        }
        .containerBackground(for: .widget) {
            if let note = entry.note, entry.moduleEnabled {
                note.color.color.gradient
            } else {
                Color.yellow.opacity(0.4).gradient
            }
        }
    }

    private func rectangular(_ note: StickyNote) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(note.displayTitle).font(.headline).widgetAccentable().lineLimit(1)
            if note.items.isEmpty {
                Text(note.body).font(.caption).lineLimit(2)
            } else {
                ForEach(note.items.filter { !$0.done }.prefix(2)) { item in
                    Text("◦ \(item.text)").font(.caption).lineLimit(1)
                }
                if note.items.allSatisfy(\.done) {
                    Text("All done ✓").font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func full(_ note: StickyNote) -> some View {
        let limit = family == .systemLarge ? 9 : (family == .systemMedium ? 4 : 3)
        return VStack(alignment: .leading, spacing: 6) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(family == .systemSmall ? 2 : 1)
            if !note.body.isEmpty {
                Text(note.body).font(.caption).lineLimit(note.items.isEmpty ? 6 : 2).opacity(0.85)
            }
            ForEach(note.items.prefix(limit)) { item in
                Button(intent: ToggleChecklistItemIntent(noteID: note.id, itemID: item.id)) {
                    HStack(spacing: 6) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        Text(item.text).strikethrough(item.done).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black.opacity(0.82))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Label(text, systemImage: "note.text")
            .font(.caption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension StickyNote {
    static let sample = StickyNote(title: "Groceries",
                                   items: [ChecklistItem(text: "Oat milk"),
                                           ChecklistItem(text: "Coffee beans", done: true),
                                           ChecklistItem(text: "Avocados")],
                                   color: .lemon)
}
