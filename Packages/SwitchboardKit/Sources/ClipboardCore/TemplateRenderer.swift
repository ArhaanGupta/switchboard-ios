import Foundation

/// Expands tokens inside snippets:
///
/// | Token        | Example output          |
/// |--------------|-------------------------|
/// | `{date}`     | Nov 27, 2026            |
/// | `{time}`     | 3:41 PM                 |
/// | `{datetime}` | Nov 27, 2026 at 3:41 PM |
/// | `{isodate}`  | 2026-11-27              |
/// | `{weekday}`  | Friday                  |
/// | `{clipboard}`| current clipboard text  |
/// | `{uuid}`     | random UUID             |
public struct TemplateRenderer {
    public var now: Date
    public var locale: Locale
    public var timeZone: TimeZone
    public var clipboard: String?

    public init(now: Date = .now, locale: Locale = .current,
                timeZone: TimeZone = .current, clipboard: String? = nil) {
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
        self.clipboard = clipboard
    }

    public static let tokens = ["{date}", "{time}", "{datetime}", "{isodate}", "{weekday}", "{clipboard}", "{uuid}"]

    public func render(_ template: String) -> String {
        guard template.contains("{") else { return template }
        var output = template
        let replacements: [(String, () -> String)] = [
            ("{datetime}", { format(date: .medium, time: .short) }),
            ("{isodate}", { iso() }),
            ("{date}", { format(date: .medium, time: .none) }),
            ("{time}", { format(date: .none, time: .short) }),
            ("{weekday}", { weekday() }),
            ("{clipboard}", { clipboard ?? "" }),
            ("{uuid}", { UUID().uuidString }),
        ]
        for (token, value) in replacements where output.contains(token) {
            output = output.replacingOccurrences(of: token, with: value())
        }
        return output
    }

    private func format(date: DateFormatter.Style, time: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = date
        f.timeStyle = time
        return f.string(from: now)
    }

    private func iso() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    private func weekday() -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "EEEE"
        return f.string(from: now)
    }
}
