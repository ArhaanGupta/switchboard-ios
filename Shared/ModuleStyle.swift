import SwiftUI
import SwitchboardCore

/// Presentation metadata for each module — shared by the app and widgets so
/// icons and colours stay consistent everywhere.
extension ModuleID {
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .stickyNotes: "Sticky Notes"
        case .shield: "Ad Shield"
        case .shareAnywhere: "Share Anywhere"
        case .floatingWindow: "Floating Window"
        }
    }

    var tagline: String {
        switch self {
        case .clipboard: "History, pins & snippets in a keyboard"
        case .stickyNotes: "Notes on your Lock Screen & Island"
        case .shield: "Block ads & trackers in every app"
        case .shareAnywhere: "Send files to Windows, Linux & Android"
        case .floatingWindow: "Timers & notes that float over apps"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard.fill"
        case .stickyNotes: "note.text"
        case .shield: "shield.lefthalf.filled"
        case .shareAnywhere: "dot.radiowaves.left.and.right"
        case .floatingWindow: "pip.fill"
        }
    }

    var tint: Color {
        switch self {
        case .clipboard: .orange
        case .stickyNotes: .yellow
        case .shield: .green
        case .shareAnywhere: .blue
        case .floatingWindow: .purple
        }
    }

    /// What Android feature this replaces — shown on the module detail page.
    var androidEquivalent: String {
        switch self {
        case .clipboard: "Gboard clipboard"
        case .stickyNotes: "Persistent notifications"
        case .shield: "Private DNS / AdGuard"
        case .shareAnywhere: "Quick Share"
        case .floatingWindow: "Bubbles & floating windows"
        }
    }
}

extension NoteColor {
    var color: Color {
        switch self {
        case .lemon: Color(red: 1.00, green: 0.86, blue: 0.35)
        case .mint: Color(red: 0.55, green: 0.90, blue: 0.75)
        case .sky: Color(red: 0.55, green: 0.78, blue: 1.00)
        case .rose: Color(red: 1.00, green: 0.62, blue: 0.70)
        case .lavender: Color(red: 0.76, green: 0.68, blue: 1.00)
        case .graphite: Color(red: 0.55, green: 0.57, blue: 0.62)
        }
    }

    var name: String { rawValue.capitalized }
}
