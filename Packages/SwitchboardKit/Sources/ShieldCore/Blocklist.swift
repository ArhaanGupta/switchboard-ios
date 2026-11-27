import Foundation

/// A set of domains where an entry also matches every subdomain:
/// blocking `doubleclick.net` blocks `ad.doubleclick.net`.
public struct DomainSet: Sendable {
    private var domains: Set<String>

    public init<S: Sequence>(_ domains: S) where S.Element == String {
        self.domains = Set(domains.map(DomainSet.normalize))
    }

    public init() { self.domains = [] }

    public var count: Int { domains.count }

    public func matches(_ name: String) -> Bool {
        guard !domains.isEmpty else { return false }
        var candidate = Substring(DomainSet.normalize(name))
        while true {
            if domains.contains(String(candidate)) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    static func normalize(_ name: String) -> String {
        var n = name.lowercased()
        while n.hasSuffix(".") { n.removeLast() }
        return n
    }
}

public enum ShieldDecision: Equatable, Sendable {
    case allow, block
}

public struct ShieldRules: Sendable {
    public var blocked: DomainSet
    public var allowed: DomainSet

    public init(blocked: DomainSet = DomainSet(), allowed: DomainSet = DomainSet()) {
        self.blocked = blocked
        self.allowed = allowed
    }

    /// The allowlist always wins.
    public func decision(for name: String) -> ShieldDecision {
        if allowed.matches(name) { return .allow }
        return blocked.matches(name) ? .block : .allow
    }
}

/// Parses the common blocklist formats into bare domains:
/// - hosts files: `0.0.0.0 ads.example.com`
/// - plain lists: `ads.example.com` / `*.ads.example.com`
/// - Adblock-style DNS rules: `||ads.example.com^`
public enum BlocklistParser {
    private static let hostsPrefixes: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1", "::0"]
    private static let ignored: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
        "ip6-loopback", "0.0.0.0", "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes",
        "ip6-allrouters", "ip6-allhosts",
    ]

    public static func domains(from text: String) -> [String] {
        var result: [String] = []
        text.enumerateLines { line, _ in
            if let domain = parseLine(line) { result.append(domain) }
        }
        return result
    }

    public static func parseLine(_ rawLine: String) -> String? {
        var line = Substring(rawLine).drop(while: { $0 == " " || $0 == "\t" })
        if line.hasPrefix("#") { return nil }
        // Only treat "#" as a comment when it follows whitespace, so cosmetic
        // filters like "example.com##.banner" are rejected instead of being
        // misread as "example.com".
        if let comment = line.range(of: " #") ?? line.range(of: "\t#") {
            line = line[..<comment.lowerBound]
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("["),
              !trimmed.hasPrefix("@@") else { return nil }

        var candidate: String
        if trimmed.hasPrefix("||") {
            // Only accept pure domain rules: ||example.com^ (optionally $important)
            var rule = trimmed.dropFirst(2)
            if let dollar = rule.firstIndex(of: "$") {
                let options = rule[rule.index(after: dollar)...]
                guard options == "important" else { return nil }
                rule = rule[..<dollar]
            }
            guard rule.hasSuffix("^") else { return nil }
            candidate = String(rule.dropLast())
        } else {
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, hostsPrefixes.contains(String(parts[0])) {
                candidate = String(parts[1])
            } else if parts.count == 1 {
                candidate = String(parts[0])
            } else {
                return nil
            }
        }

        if candidate.hasPrefix("*.") { candidate.removeFirst(2) }
        candidate = candidate.lowercased()
        while candidate.hasSuffix(".") { candidate.removeLast() }
        guard isValidDomain(candidate), !ignored.contains(candidate) else { return nil }
        return candidate
    }

    public static func isValidDomain(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 253, s.contains("."),
              !s.hasPrefix("."), !s.hasPrefix("-") else { return false }
        // Reject raw IPv4 addresses.
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "0"..."9", "-", ".", "_": return true
            default: return false
            }
        }
    }
}

/// Counters the tunnel writes and the app displays.
public struct ShieldStats: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID = UUID()
        public var domain: String
        public var blocked: Bool
        public var date: Date

        public init(domain: String, blocked: Bool, date: Date = .now) {
            self.domain = domain
            self.blocked = blocked
            self.date = date
        }
    }

    public var totalQueries: Int = 0
    public var blockedQueries: Int = 0
    public var since: Date = .now
    public var recent: [Entry] = []

    public static let recentLimit = 150

    public init() {}

    public mutating func record(domain: String, blocked: Bool, date: Date = .now) {
        totalQueries += 1
        if blocked { blockedQueries += 1 }
        recent.insert(Entry(domain: domain, blocked: blocked, date: date), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    public var blockedPercent: Double {
        totalQueries == 0 ? 0 : Double(blockedQueries) / Double(totalQueries) * 100
    }
}

/// File names shared between the app and the tunnel extension.
public enum ShieldFiles {
    public static let blocklist = "shield-blocklist.txt"
    public static let allowlist = "shield-allowlist.txt"
    public static let stats = "shield-stats.json"

    /// Small built-in list so the Shield is useful before any download.
    public static let starterDomains: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "app-measurement.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "ads.yahoo.com", "analytics.yahoo.com", "scorecardresearch.com", "adnxs.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "amazon-adsystem.com",
        "moatads.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "applovin.com", "unityads.unity3d.com", "adcolony.com", "inmobi.com",
        "chartboost.com", "vungle.com", "supersonicads.com", "mopub.com", "flurry.com",
        "quantserve.com", "hotjar.com", "mixpanel.com", "branch-attribution.com",
        "ads-twitter.com", "ads.linkedin.com", "analytics.tiktok.com", "ads.tiktok.com",
        "connect.facebook.net", "an.facebook.com", "pixel.facebook.com",
    ]
}
