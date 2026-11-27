import Foundation

/// Structured content that can be encoded into, or decoded from, a QR code.
public enum QRPayload: Equatable, Sendable {
    case text(String)
    case url(URL)
    case wifi(WiFiNetwork)
    case contact(Contact)
    case email(String)
    case phone(String)

    public struct WiFiNetwork: Equatable, Sendable {
        public enum Security: String, CaseIterable, Sendable {
            case wpa = "WPA"
            case wep = "WEP"
            case open = "nopass"
        }

        public var ssid: String
        public var password: String
        public var security: Security
        public var hidden: Bool

        public init(ssid: String, password: String = "", security: Security = .wpa, hidden: Bool = false) {
            self.ssid = ssid
            self.password = password
            self.security = security
            self.hidden = hidden
        }
    }

    public struct Contact: Equatable, Sendable {
        public var name: String
        public var phone: String
        public var email: String
        public var organization: String

        public init(name: String, phone: String = "", email: String = "", organization: String = "") {
            self.name = name
            self.phone = phone
            self.email = email
            self.organization = organization
        }
    }

    // MARK: Encoding

    /// The string to put in the QR code.
    public var encoded: String {
        switch self {
        case .text(let text):
            return text
        case .url(let url):
            return url.absoluteString
        case .email(let address):
            return "mailto:\(address)"
        case .phone(let number):
            return "tel:\(number.filter { $0.isNumber || $0 == "+" })"
        case .wifi(let wifi):
            // Format from the ZXing spec: WIFI:T:WPA;S:name;P:pass;H:true;;
            var s = "WIFI:T:\(wifi.security.rawValue);S:\(Self.escapeWiFi(wifi.ssid));"
            if wifi.security != .open { s += "P:\(Self.escapeWiFi(wifi.password));" }
            if wifi.hidden { s += "H:true;" }
            return s + ";"
        case .contact(let c):
            var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:\(Self.escapeVCard(c.name))"]
            if !c.organization.isEmpty { lines.append("ORG:\(Self.escapeVCard(c.organization))") }
            if !c.phone.isEmpty { lines.append("TEL:\(Self.escapeVCard(c.phone))") }
            if !c.email.isEmpty { lines.append("EMAIL:\(Self.escapeVCard(c.email))") }
            lines.append("END:VCARD")
            return lines.joined(separator: "\r\n")
        }
    }

    static func escapeWiFi(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\;,:\"".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func escapeVCard(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: Decoding

    /// Classifies a scanned QR string.
    public static func parse(_ raw: String) -> QRPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        if upper.hasPrefix("WIFI:"), let wifi = parseWiFi(trimmed) { return .wifi(wifi) }
        if upper.hasPrefix("BEGIN:VCARD"), let contact = parseVCard(trimmed) { return .contact(contact) }
        if upper.hasPrefix("MAILTO:") {
            let address = String(trimmed.dropFirst(7)).components(separatedBy: "?").first ?? ""
            return .email(address.removingPercentEncoding ?? address)
        }
        if upper.hasPrefix("TEL:") { return .phone(String(trimmed.dropFirst(4))) }
        let lower = trimmed.lowercased()
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")),
           !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), url.host != nil {
            return .url(url)
        }
        return .text(raw)
    }

    /// Splits "key:value;key:value" honouring backslash escapes.
    static func parseWiFi(_ raw: String) -> WiFiNetwork? {
        var fields: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var escaping = false
        for ch in raw.dropFirst(5) {
            if escaping {
                if readingKey { key.append(ch) } else { value.append(ch) }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if readingKey && ch == ":" {
                readingKey = false
            } else if ch == ";" {
                if !key.isEmpty { fields[key.uppercased()] = value }
                key = ""; value = ""; readingKey = true
            } else if readingKey {
                key.append(ch)
            } else {
                value.append(ch)
            }
        }
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        let security: WiFiNetwork.Security
        switch fields["T"]?.uppercased() {
        case "WEP": security = .wep
        case "NOPASS", "", nil: security = fields["P"].map { $0.isEmpty ? .open : .wpa } ?? .open
        default: security = .wpa
        }
        return WiFiNetwork(ssid: ssid, password: fields["P"] ?? "", security: security,
                           hidden: fields["H"]?.lowercased() == "true")
    }

    static func parseVCard(_ raw: String) -> Contact? {
        var contact = Contact(name: "")
        for line in raw.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            // "TEL;TYPE=CELL:+1..." → key "TEL"
            let key = line[..<colon].split(separator: ";").first.map { $0.uppercased() } ?? ""
            let value = String(line[line.index(after: colon)...])
                .replacingOccurrences(of: "\\,", with: ",")
                .replacingOccurrences(of: "\\;", with: ";")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
            switch key {
            case "FN": contact.name = value
            case "N" where contact.name.isEmpty:
                let parts = value.split(separator: ";", omittingEmptySubsequences: false)
                contact.name = [parts.count > 1 ? parts[1] : "", parts.first ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            case "TEL" where contact.phone.isEmpty: contact.phone = value
            case "EMAIL" where contact.email.isEmpty: contact.email = value
            case "ORG": contact.organization = value.replacingOccurrences(of: ";", with: " ").trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return contact.name.isEmpty && contact.phone.isEmpty && contact.email.isEmpty ? nil : contact
    }

    // MARK: Display

    public var kindName: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .wifi: "Wi-Fi"
        case .contact: "Contact"
        case .email: "Email"
        case .phone: "Phone"
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .wifi: "wifi"
        case .contact: "person.crop.circle"
        case .email: "envelope"
        case .phone: "phone"
        }
    }

    /// Short human-readable summary.
    public var summary: String {
        switch self {
        case .text(let t): t
        case .url(let u): u.host.map { $0 + u.path } ?? u.absoluteString
        case .wifi(let w): w.ssid
        case .contact(let c): c.name.isEmpty ? (c.phone.isEmpty ? c.email : c.phone) : c.name
        case .email(let e): e
        case .phone(let p): p
        }
    }
}

/// One scanned or created code, persisted in history.
public struct QRHistoryItem: Codable, Identifiable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case scanned, created }

    public var id: UUID
    public var raw: String
    public var source: Source
    public var date: Date
    public var isFavorite: Bool

    public init(id: UUID = UUID(), raw: String, source: Source, date: Date = .now, isFavorite: Bool = false) {
        self.id = id
        self.raw = raw
        self.source = source
        self.date = date
        self.isFavorite = isFavorite
    }

    public var payload: QRPayload { QRPayload.parse(raw) }
}

/// Keeps history newest-first, de-duplicated, capped.
public struct QRHistory: Codable, Sendable {
    public var items: [QRHistoryItem] = []
    public static let limit = 300

    public init(items: [QRHistoryItem] = []) { self.items = items }

    public mutating func record(_ raw: String, source: QRHistoryItem.Source, date: Date = .now) {
        let favorite = items.first { $0.raw == raw }?.isFavorite ?? false
        items.removeAll { $0.raw == raw }
        items.insert(QRHistoryItem(raw: raw, source: source, date: date, isFavorite: favorite), at: 0)
        if items.count > Self.limit {
            // Drop the oldest non-favourites first.
            var overflow = items.count - Self.limit
            items = items.reversed().filter { item in
                if overflow > 0 && !item.isFavorite { overflow -= 1; return false }
                return true
            }.reversed()
        }
    }
}
