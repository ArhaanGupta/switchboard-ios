import SwiftUI
import SwitchboardCore

/// Wraps every module page: shows a hero + "Turn on" when the module is off,
/// otherwise the module's own screen.
struct ModuleScreen: View {
    @Environment(AppModel.self) private var model
    let module: ModuleID

    var body: some View {
        Group {
            if model.isEnabled(module) {
                content
            } else {
                DisabledModuleView(module: module)
            }
        }
        .navigationTitle(module.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(module.title, isOn: Binding(
                    get: { model.isEnabled(module) },
                    set: { model.setEnabled($0, for: module) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(module.tint)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .animation(.smooth, value: model.isEnabled(module))
    }

    @ViewBuilder private var content: some View {
        switch module {
        case .clipboard: ClipboardScreen()
        case .stickyNotes: StickyNotesScreen()
        case .shield: ShieldScreen()
        case .shareAnywhere: ShareScreen()
        case .floatingWindow: FloatingScreen()
        case .qrCode: QRScreen()
        case .appLock: AppLockScreen()
        }
    }
}

private struct DisabledModuleView: View {
    @Environment(AppModel.self) private var model
    let module: ModuleID

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ModuleIcon(module: module, size: 96)
                    .padding(.top, 40)
                Text(module.tagline)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Like \(module.androidEquivalent) on Android.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    model.setEnabled(true, for: module)
                } label: {
                    Label("Turn On \(module.title)", systemImage: "power")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(module.tint)
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .moduleBackground(module.tint)
    }
}
