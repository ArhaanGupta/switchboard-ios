import SwiftUI
import SwitchboardCore

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    GlassEffectContainer(spacing: 14) {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(ModuleID.allCases) { module in
                                ModuleCard(module: module)
                            }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(backdrop)
            .navigationTitle("Switchboard")
            .navigationDestination(for: ModuleID.self) { module in
                ModuleScreen(module: module)
            }
        }
        .overlay(alignment: .top) { ToastView(toast: model.toast) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.enabledCount) of \(ModuleID.allCases.count) modules on")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Text("Turn on the power features you want. Everything runs on your iPhone. No account, and nothing leaves the device unless you send it.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        Text("Tip: add Switchboard controls to Control Center by long-pressing it and tapping \"Add a Control\".")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var backdrop: some View {
        ZStack {
            Color(.systemGroupedBackground)
            // Soft colour blobs give Liquid Glass something to refract.
            Circle().fill(Color.orange.opacity(0.25)).frame(width: 320).blur(radius: 90).offset(x: -140, y: -260)
            Circle().fill(Color.blue.opacity(0.22)).frame(width: 360).blur(radius: 100).offset(x: 150, y: 40)
            Circle().fill(Color.purple.opacity(0.18)).frame(width: 300).blur(radius: 90).offset(x: -120, y: 360)
        }
        .ignoresSafeArea()
    }
}

struct ModuleCard: View {
    @Environment(AppModel.self) private var model
    let module: ModuleID

    var body: some View {
        let on = model.isEnabled(module)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ModuleIcon(module: module, size: 42, active: on)
                Spacer()
                Toggle(module.title, isOn: Binding(
                    get: { model.isEnabled(module) },
                    set: { model.setEnabled($0, for: module) }
                ))
                .labelsHidden()
                .tint(module.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.headline)
                    .foregroundStyle(on ? .primary : .secondary)
                Text(module.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            StatusLine(module: module)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(on ? Glass.regular.tint(module.tint.opacity(0.15)).interactive() : Glass.regular.interactive(),
                     in: .rect(cornerRadius: 26, style: .continuous))
        .contentShape(.rect(cornerRadius: 26))
        .onTapGesture { model.path.append(module) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(module.title) settings")
    }
}

/// Live one-line status on each card.
private struct StatusLine: View {
    @Environment(AppModel.self) private var model
    let module: ModuleID

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(model.isEnabled(module) ? module.tint : .secondary)
            .lineLimit(1)
    }

    private var text: String {
        guard model.isEnabled(module) else { return "Off" }
        switch module {
        case .clipboard: return "\(model.clipboard.items.count) clips"
        case .stickyNotes: return "\(model.sticky.notes.count) notes"
        case .shield: return model.shield.statusText
        case .shareAnywhere: return model.share.isRunning ? "Visible as \(model.share.alias)" : "Ready"
        case .floatingWindow: return model.floating.isFloating ? "Floating now" : "Ready"
        }
    }

    private var symbol: String {
        model.isEnabled(module) ? "circle.fill" : "circle"
    }
}

private struct ToastView: View {
    let toast: AppModel.Toast?

    var body: some View {
        if let toast {
            Label(toast.message, systemImage: toast.symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
        }
    }
}
