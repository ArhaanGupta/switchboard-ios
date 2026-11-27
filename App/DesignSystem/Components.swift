import SwiftUI
import SwitchboardCore

/// Rounded "squircle" icon used for modules across the app.
struct ModuleIcon: View {
    let module: ModuleID
    var size: CGFloat = 44
    var active = true

    var body: some View {
        Image(systemName: module.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(active ? module.tint.gradient : Color.gray.opacity(0.45).gradient)
            )
            .shadow(color: active ? module.tint.opacity(0.35) : .clear, radius: 8, y: 4)
            .animation(.smooth, value: active)
    }
}

/// A Liquid Glass card container.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(glass, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private var glass: Glass {
        guard let tint else { return .regular }
        return Glass.regular.tint(tint.opacity(0.18))
    }
}

/// Section title used inside module screens.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// A row in a setup checklist ("Add the keyboard", "Allow Full Access"...).
struct SetupStep: View {
    let title: String
    let detail: String
    let done: Bool
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action, !done {
                    Button(actionTitle, action: action)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Big number + caption, used for stats.
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

/// Empty-state placeholder.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

extension View {
    /// Standard page background: a soft wash of the module's colour.
    func moduleBackground(_ tint: Color) -> some View {
        background {
            LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.04), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
