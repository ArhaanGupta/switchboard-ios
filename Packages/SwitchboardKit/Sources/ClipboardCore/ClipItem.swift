import Foundation

public struct ClipItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, link, email, phone
    }

    public var id: UUID
    public var text: String
    public var kind: Kind
    public var isPinned: Bool
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), text: String, isPinned: Bool = false,
                createdAt: Date = .now, lastUsedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.kind = ClipItem.detectKind(text)
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
    }

    /// Single-line preview suitable for chips and list rows.
    public var preview: String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 160 ? String(collapsed.prefix(160)) + "…" : collapsed
    }

    public static func detectKind(_ text: String) -> Kind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return .text }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"),
           let url = URL(string: t), url.host != nil {
            return .link
        }
        if t.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
            return .email
        }
        let digits = t.filter(\.isNumber)
        if digits.count >= 7, digits.count <= 15,
           t.range(of: #"^\+?[0-9()\-.\s]+$"#, options: .regularExpression) != nil {
            return .phone
        }
        return .text
    }
}

public struct Snippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// May contain tokens such as `{date}` — see `TemplateRenderer`.
    public var body: String

    public init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

public struct ClipboardSettings: Codable, Hashable, Sendable {
    public var maxItems: Int = 200
    /// Capture the clipboard automatically whenever the app comes to the foreground.
    public var captureOnAppOpen: Bool = false

    public init(maxItems: Int = 200, captureOnAppOpen: Bool = false) {
        self.maxItems = maxItems
        self.captureOnAppOpen = captureOnAppOpen
    }
}

public struct ClipboardDatabase: Codable, Sendable {
    public var items: [ClipItem] = []
    public var snippets: [Snippet] = ClipboardDatabase.starterSnippets
    public var settings = ClipboardSettings()

    public init(items: [ClipItem] = [], snippets: [Snippet] = ClipboardDatabase.starterSnippets,
                settings: ClipboardSettings = ClipboardSettings()) {
        self.items = items
        self.snippets = snippets
        self.settings = settings
    }

    public static let starterSnippets: [Snippet] = [
        Snippet(title: "Today's date", body: "{date}"),
        Snippet(title: "Running late", body: "Running about 10 minutes late — be there soon!"),
        Snippet(title: "Timestamp", body: "{datetime}"),
    ]
}
