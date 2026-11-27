import ClipboardCore
import Foundation
import ShieldCore
import SwitchboardCore

/// Seeds realistic sample content when the app is launched with `-demoData`.
/// Used by the UI tests to produce README screenshots; never runs otherwise.
enum DemoData {
    static let launchArgument = "-demoData"

    static var isRequested: Bool { CommandLine.arguments.contains(launchArgument) }

    static func seedIfRequested() {
        guard isRequested else { return }
        let flags = FeatureFlags()
        for module in ModuleID.allCases {
            flags.setEnabled(module != .shareAnywhere, for: module)
        }
        seedClipboard()
        seedNotes()
        seedShieldStats()
    }

    private static func seedClipboard() {
        let file = JSONFile<ClipboardDatabase>(name: "clipboard.json")
        let now = Date()
        let samples: [(String, TimeInterval, Bool)] = [
            ("Wi-Fi password: maple-harbor-42", -60 * 60 * 26, true),
            ("https://github.com/ArhaanGupta/switchboard-ios", -40, false),
            ("Meet at the north entrance at 6:30, I'll grab the tickets", -60 * 7, false),
            ("hello@example.com", -60 * 35, false),
            ("1600 Amphitheatre Parkway, Mountain View, CA", -60 * 60 * 3, false),
            ("Tracking: 1Z 999 AA1 01 2345 6784", -60 * 60 * 5, false),
        ]
        let items = samples.map { text, offset, pinned in
            ClipItem(text: text, isPinned: pinned, createdAt: now.addingTimeInterval(offset))
        }
        try? file.save(ClipboardDatabase(items: items))
    }

    private static func seedNotes() {
        let groceries = StickyNote(
            title: "Groceries",
            items: [ChecklistItem(text: "Oat milk", done: true),
                    ChecklistItem(text: "Coffee beans"),
                    ChecklistItem(text: "Avocados"),
                    ChecklistItem(text: "Sourdough", done: true)],
            color: .lemon)
        let trip = StickyNote(title: "Gate B22", body: "Boarding 7:45 · Seat 14A\nConfirmation QX7P2L", color: .sky)
        let idea = StickyNote(title: "App ideas", body: "QR module\nShare extension\nWidgets for Shield stats", color: .lavender)
        let call = StickyNote(title: "Call mom", body: "Ask about Sunday dinner", color: .rose)
        try? JSONFile<StickyNotesDatabase>(name: "sticky-notes.json")
            .save(StickyNotesDatabase(notes: [groceries, trip, idea, call], widgetNoteID: groceries.id))
    }

    private static func seedShieldStats() {
        var stats = ShieldStats()
        stats.since = Date().addingTimeInterval(-60 * 60 * 9)
        let domains: [(String, Bool)] = [
            ("api.weather.com", false), ("googleads.g.doubleclick.net", true), ("app-measurement.com", true),
            ("cdn.instagram.com", false), ("graph.facebook.com", false), ("analytics.tiktok.com", true),
            ("pagead2.googlesyndication.com", true), ("api.spotify.com", false), ("ads.yahoo.com", true),
        ]
        for i in 0..<1_248 {
            let (domain, blocked) = domains[i % domains.count]
            stats.record(domain: domain, blocked: blocked)
        }
        try? JSONFile<ShieldStats>(name: ShieldFiles.stats).save(stats)
    }
}
