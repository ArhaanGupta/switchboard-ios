import ClipboardCore
import SwiftUI
import SwitchboardCore

struct ClipboardScreen: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .history
    @State private var editingSnippet: Snippet?
    @State private var confirmClear = false

    enum Tab: String, CaseIterable { case history = "History", snippets = "Snippets", setup = "Setup" }

    private var model: ClipboardModel { app.clipboard }

    var body: some View {
        @Bindable var model = app.clipboard
        List {
            Section {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            switch tab {
            case .history: historySection
            case .snippets: snippetSection
            case .setup: setupSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .moduleBackground(ModuleID.clipboard.tint)
        .searchable(text: $model.query, prompt: "Search clips")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        model.savePasted(strings)
                        app.show("tray.and.arrow.down.fill", "Saved")
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(ModuleID.clipboard.tint)
            }
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditor(snippet: snippet) { model.save($0) }
        }
        .confirmationDialog("Clear all unpinned clips?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Unpinned", role: .destructive) { model.clearUnpinned() }
        }
    }

    // MARK: History

    @ViewBuilder private var historySection: some View {
        if model.filteredItems.isEmpty {
            Section {
                EmptyStateView(symbol: "doc.on.clipboard",
                               title: model.query.isEmpty ? "No clips yet" : "No matches",
                               message: "Copy something, then tap Paste below, or use the Switchboard keyboard, which saves your clips automatically.")
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(model.filteredItems) { item in
                    ClipRow(item: item)
                        .contentShape(.rect)
                        .onTapGesture {
                            model.copy(item)
                            app.show("checkmark.circle.fill", "Copied")
                        }
                        .swipeActions(edge: .leading) {
                            Button { model.togglePin(item) } label: {
                                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.delete(item) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { model.copy(item) }
                            Button(item.isPinned ? "Unpin" : "Pin", systemImage: "pin") { model.togglePin(item) }
                            ShareLink(item: item.text)
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(item) }
                        }
                }
            } header: {
                HStack {
                    Text("\(model.items.count) clips")
                    Spacer()
                    Button("Clear") { confirmClear = true }
                        .font(.caption.weight(.semibold))
                }
            } footer: {
                Text("Tap to copy. Swipe right to pin. Pinned clips are never deleted automatically.")
            }
        }
    }

    // MARK: Snippets

    @ViewBuilder private var snippetSection: some View {
        Section {
            ForEach(model.snippets) { snippet in
                Button { editingSnippet = snippet } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snippet.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(TemplateRenderer().render(snippet.body))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { model.deleteSnippets(at: $0) }
            .onMove { model.moveSnippets(from: $0, to: $1) }

            Button {
                editingSnippet = Snippet(title: "", body: "")
            } label: {
                Label("New Snippet", systemImage: "plus.circle.fill")
            }
        } footer: {
            Text("Snippets appear in the Switchboard keyboard. Tokens: \(TemplateRenderer.tokens.joined(separator: " "))")
        }
    }

    // MARK: Setup

    @ViewBuilder private var setupSection: some View {
        Section("Keyboard") {
            SetupStep(title: "Add the Switchboard keyboard",
                      detail: "Settings → General → Keyboard → Keyboards → Add New Keyboard → Switchboard.",
                      done: model.keyboardSeen,
                      actionTitle: "Open Settings") { openSettings() }
            SetupStep(title: "Allow Full Access",
                      detail: "Lets the keyboard read and save your clipboard and sync with the app. Switchboard has no network code in the keyboard. Your clips never leave the device.",
                      done: model.keyboardHasFullAccess,
                      actionTitle: "Open Settings") { openSettings() }
            SetupStep(title: "Switch to it with 🌐",
                      detail: "Tap or hold the globe key in any app. Your clips and snippets appear in one tap.",
                      done: model.keyboardSeen)
        }

        Section {
            Toggle("Save clipboard when opening Switchboard", isOn: Binding(
                get: { model.settings.captureOnAppOpen },
                set: { model.setCaptureOnOpen($0) }
            ))
            Picker("Keep history", selection: Binding(
                get: { model.settings.maxItems },
                set: { model.setMaxItems($0) }
            )) {
                ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0) clips") }
            }
        } header: {
            Text("Capture")
        } footer: {
            Text("To stop iOS asking every time, go to Settings → Apps → Switchboard → Paste from Other Apps → Allow. You can also add the \"Save Clipboard\" control to Control Center.")
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ModuleID.clipboard.tint)
                .frame(width: 28, height: 28)
                .background(ModuleID.clipboard.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.preview)
                    .font(.subheadline)
                    .lineLimit(3)
                Text(item.lastUsedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch item.kind {
        case .link: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .text: "text.alignleft"
        }
    }
}

private struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet
    let onSave: (Snippet) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $snippet.title)
                Section("Text") {
                    TextEditor(text: $snippet.body)
                        .frame(minHeight: 140)
                }
                Section("Insert token") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(TemplateRenderer.tokens, id: \.self) { token in
                                Button(token) { snippet.body += token }
                                    .buttonStyle(.glass)
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
                Section("Preview") {
                    Text(TemplateRenderer(clipboard: "‹clipboard›").render(snippet.body))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(snippet.title.isEmpty ? "New Snippet" : snippet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if snippet.title.isEmpty { snippet.title = String(snippet.body.prefix(24)) }
                        onSave(snippet)
                        dismiss()
                    }
                    .disabled(snippet.body.isEmpty)
                }
            }
        }
    }
}
