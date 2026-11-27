import ClipboardCore
import SwiftUI
import SwitchboardCore

struct KeyboardRootView: View {
    let state: KeyboardState
    @State private var tab: Tab = .recent

    enum Tab: String, CaseIterable {
        case recent = "Recent", pinned = "Pinned", snippets = "Snippets"
        var symbol: String {
            switch self {
            case .recent: "clock"
            case .pinned: "pin"
            case .snippets: "text.badge.star"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                if !state.moduleEnabled {
                    message(symbol: "power", title: "Clipboard is off",
                            body: "Turn on the Clipboard module in the Switchboard app.")
                } else if !state.hasFullAccess {
                    message(symbol: "lock.open", title: "Allow Full Access",
                            body: "Settings → General → Keyboard → Keyboards → Switchboard → Allow Full Access. Needed to read your clipboard; nothing is sent anywhere.")
                } else {
                    content
                }
            }
            .frame(maxHeight: .infinity)
            bottomRow
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // MARK: Pieces

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Label(t.rawValue, systemImage: t.symbol)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(tab == t ? Color.white : Color.primary)
                        .background(tab == t ? Color.orange : Color.clear, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: state.actions.dismiss) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.body)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide keyboard")
        }
        .padding(.top, 6)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .recent: clipGrid(state.items.filter { !$0.isPinned })
        case .pinned: clipGrid(state.items.filter(\.isPinned))
        case .snippets: snippetGrid
        }
    }

    private func clipGrid(_ items: [ClipItem]) -> some View {
        Group {
            if items.isEmpty {
                message(symbol: tab == .pinned ? "pin" : "doc.on.clipboard",
                        title: tab == .pinned ? "No pinned clips" : "Nothing copied yet",
                        body: tab == .pinned ? "Long-press a clip to pin it." : "Copy text anywhere. It shows up here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(items) { item in
                            KeyTile(text: item.preview, pinned: item.isPinned) {
                                state.actions.insert(item.text)
                                ClipboardStore.shared.markUsed(item.id)
                            }
                            .contextMenu {
                                Button(item.isPinned ? "Unpin" : "Pin", systemImage: "pin") { state.actions.togglePin(item) }
                                Button("Delete", systemImage: "trash", role: .destructive) { state.actions.delete(item) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var snippetGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(state.snippets) { snippet in
                    KeyTile(text: snippet.title, subtitle: state.render(snippet), pinned: false) {
                        state.actions.insert(state.render(snippet))
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if state.showsGlobe {
                SystemKey(symbol: "globe", action: state.actions.nextKeyboard)
                    .accessibilityLabel("Next keyboard")
            }
            Button(action: state.actions.space) {
                Text("space")
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Color(.systemBackground).opacity(0.9), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            RepeatingKey(symbol: "delete.left", action: state.actions.deleteBackward)
                .accessibilityLabel("Delete")
            SystemKey(symbol: "return", action: state.actions.newline)
                .accessibilityLabel("Return")
        }
    }

    private func message(symbol: String, title: String, body: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeyTile: View {
    let text: String
    var subtitle: String? = nil
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text(text)
                        .font(.footnote.weight(subtitle == nil ? .regular : .semibold))
                        .lineLimit(subtitle == nil ? 3 : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                }
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(Color(.systemBackground).opacity(0.92), in: .rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct SystemKey: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 52, height: 42)
                .background(Color(.systemGray3).opacity(0.8), in: .rect(cornerRadius: 8))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Delete key that repeats while held, like the system keyboard.
private struct RepeatingKey: View {
    let symbol: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .frame(width: 52, height: 42)
            .background(Color(.systemGray3).opacity(0.8), in: .rect(cornerRadius: 8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        action()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in action() }
                        }
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
