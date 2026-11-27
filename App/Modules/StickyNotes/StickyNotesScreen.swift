import SwiftUI
import SwitchboardCore

struct StickyNotesScreen: View {
    @Environment(AppModel.self) private var app

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        @Bindable var model = app.sticky
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !model.liveActivitiesAllowed {
                    GlassCard(tint: .orange) {
                        Label("Live Activities are turned off for Switchboard. Turn them on in Settings → Apps → Switchboard to pin notes to the Dynamic Island.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                    }
                }

                if model.notes.isEmpty {
                    EmptyStateView(symbol: "note.text",
                                   title: "No notes yet",
                                   message: "Create a note or checklist, then pin it to your Lock Screen, Dynamic Island or a widget.")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.notes) { note in
                            NoteCard(note: note,
                                     isLive: model.liveNoteIDs.contains(note.id),
                                     isWidget: model.widgetNoteID == note.id)
                                .onTapGesture { model.editing = note }
                                .contextMenu { menu(for: note) }
                        }
                    }
                }

                SectionHeader(title: "Where notes appear",
                              subtitle: "Pin: Lock Screen + Dynamic Island, for up to 8 hours at a time (an iOS limit). Widget: permanent, on your Lock Screen or Home Screen.")
            }
            .padding(16)
        }
        .moduleBackground(ModuleID.stickyNotes.tint)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { model.composeNew() } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glassProminent)
                .tint(.yellow)
            }
        }
        .sheet(item: $model.editing) { note in
            NoteEditor(note: note)
        }
        .alert("Sticky Notes", isPresented: Binding(get: { model.errorMessage != nil },
                                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private func menu(for note: StickyNote) -> some View {
        let model = app.sticky
        if model.liveNoteIDs.contains(note.id) {
            Button("Unpin from Lock Screen", systemImage: "pin.slash") { model.stopLive(note) }
        } else {
            Button("Pin to Lock Screen & Island", systemImage: "pin") { model.startLive(note) }
        }
        Button("Show in Widget", systemImage: "square.text.square") { model.showOnWidget(note) }
        ShareLink(item: note.shareText)
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(note) }
    }
}

private struct NoteCard: View {
    let note: StickyNote
    let isLive: Bool
    let isWidget: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if isLive { Image(systemName: "pin.fill").font(.caption) }
                if isWidget { Image(systemName: "square.text.square.fill").font(.caption) }
            }
            if !note.body.isEmpty {
                Text(note.body).font(.subheadline).lineLimit(4).opacity(0.85)
            }
            ForEach(note.items.prefix(4)) { item in
                Label(item.text, systemImage: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                    .strikethrough(item.done)
                    .lineLimit(1)
            }
            if note.items.count > 4 {
                Text("+\(note.items.count - 4) more").font(.caption2).opacity(0.7)
            }
        }
        .foregroundStyle(.black.opacity(0.82))
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(note.color.color.gradient, in: .rect(cornerRadius: 22, style: .continuous))
        .shadow(color: note.color.color.opacity(0.35), radius: 10, y: 6)
    }
}

private struct NoteEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var note: StickyNote
    @State private var newItem = ""
    @FocusState private var newItemFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $note.title).font(.headline)
                    TextField("Note", text: $note.body, axis: .vertical).lineLimit(3...10)
                }
                Section("Checklist") {
                    ForEach($note.items) { $item in
                        HStack {
                            Button { item.done.toggle() } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            TextField("Item", text: $item.text)
                        }
                    }
                    .onDelete { note.items.remove(atOffsets: $0) }
                    .onMove { note.items.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.yellow)
                        TextField("Add item", text: $newItem)
                            .focused($newItemFocused)
                            .submitLabel(.next)
                            .onSubmit(addItem)
                    }
                }
                Section("Colour") {
                    HStack(spacing: 12) {
                        ForEach(NoteColor.allCases, id: \.self) { c in
                            Circle()
                                .fill(c.color.gradient)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if c == note.color {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black.opacity(0.7))
                                    }
                                }
                                .onTapGesture { note.color = c }
                                .accessibilityLabel(c.name)
                                .accessibilityAddTraits(c == note.color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(note.title.isEmpty ? "Note" : note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        addItem()
                        app.sticky.save(note)
                        dismiss()
                    }
                    .disabled(note.title.isEmpty && note.body.isEmpty && note.items.isEmpty && newItem.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        note.items.append(ChecklistItem(text: text))
        newItem = ""
        newItemFocused = true
    }
}

extension StickyNote {
    var shareText: String {
        var lines = [displayTitle]
        if !body.isEmpty { lines.append(body) }
        lines += items.map { "\($0.done ? "☑︎" : "☐") \($0.text)" }
        return lines.joined(separator: "\n")
    }
}
