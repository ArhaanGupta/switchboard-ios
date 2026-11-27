import Foundation
import NetworkExtension
import ShieldCore
import SwitchboardCore

struct BlocklistSource: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var detail: String
    var url: URL
    var enabled: Bool

    static let defaults: [BlocklistSource] = [
        BlocklistSource(id: "stevenblack", name: "Steven Black Unified",
                        detail: "Ads + malware · about 80k domains · conservative",
                        url: URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!,
                        enabled: true),
        BlocklistSource(id: "hagezi-light", name: "HaGeZi Light",
                        detail: "Ads, tracking, metrics · rarely breaks apps",
                        url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/light.txt")!,
                        enabled: false),
        BlocklistSource(id: "adguard-dns", name: "AdGuard DNS Filter",
                        detail: "AdGuard's DNS-level ad & tracker list",
                        url: URL(string: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt")!,
                        enabled: false),
        BlocklistSource(id: "oisd-small", name: "OISD Small",
                        detail: "Curated to block ads without breaking sites",
                        url: URL(string: "https://small.oisd.nl/")!,
                        enabled: false),
    ]
}

struct ShieldConfig: Codable {
    var sources: [BlocklistSource] = BlocklistSource.defaults
    var allowlist: [String] = []
    var customBlocked: [String] = []
    var lastUpdated: Date?
    var domainCount: Int = ShieldFiles.starterDomains.count
}

enum UpstreamDNS: String, CaseIterable, Identifiable {
    case cloudflare = "1.1.1.1"
    case quad9 = "9.9.9.9"
    case google = "8.8.8.8"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .cloudflare: "Cloudflare (1.1.1.1)"
        case .quad9: "Quad9 (9.9.9.9) · blocks malware"
        case .google: "Google (8.8.8.8)"
        }
    }
}

/// Manages the on-device DNS filter (a VPN profile whose tunnel only carries DNS).
@MainActor
@Observable
final class ShieldController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var stats = ShieldStats()
    private(set) var isUpdatingLists = false
    private(set) var config: ShieldConfig
    var errorMessage: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private let configFile = JSONFile<ShieldConfig>(name: "shield-config.json")
    private let statsFile = JSONFile<ShieldStats>(name: ShieldFiles.stats)
    private let defaults = AppGroup.defaults

    init() {
        config = JSONFile<ShieldConfig>(name: "shield-config.json").load() ?? ShieldConfig()
        let shared = AppGroup.defaults
        upstream = UpstreamDNS(rawValue: shared.string(forKey: SharedKey.shieldUpstreamDNS) ?? "") ?? .cloudflare
        blockMode = BlockMode(rawValue: shared.string(forKey: SharedKey.shieldBlockMode) ?? "") ?? .nullIP
        ensureListFilesExist()
    }

    // MARK: Status

    var isOn: Bool { status == .connected || status == .connecting || status == .reasserting }
    var isInstalled: Bool { manager != nil }

    var statusText: String {
        switch status {
        case .connected: "Protecting · \(stats.blockedQueries.formatted()) blocked"
        case .connecting, .reasserting: "Starting…"
        case .disconnecting: "Stopping…"
        default: "Not running"
        }
    }

    var upstream: UpstreamDNS {
        didSet { defaults.set(upstream.rawValue, forKey: SharedKey.shieldUpstreamDNS); reloadTunnel() }
    }

    var blockMode: BlockMode {
        didSet { defaults.set(blockMode.rawValue, forKey: SharedKey.shieldBlockMode); reloadTunnel() }
    }

    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            observe()
            status = manager?.connection.status ?? .invalid
        } catch {
            errorMessage = error.localizedDescription
        }
        stats = statsFile.load() ?? ShieldStats()
    }

    // MARK: Start / stop

    func start() async {
        do {
            let manager = self.manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".Shield"
            proto.serverAddress = "On-device"
            proto.disconnectOnSleep = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = "Switchboard Shield"
            manager.isEnabled = true
            // Reconnect automatically after reboots or network changes.
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.isOnDemandEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            observe()
            try manager.connection.startVPNTunnel()
        } catch {
            errorMessage = "Couldn't start the Shield: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let manager else { return }
        manager.isOnDemandEnabled = false
        try? await manager.saveToPreferences()
        manager.connection.stopVPNTunnel()
    }

    func toggle() async {
        if isOn { await stop() } else { await start() }
    }

    private func observe() {
        guard statusObserver == nil, let connection = manager?.connection else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = self.manager?.connection.status ?? .invalid
            }
        }
    }

    // MARK: Stats

    func reloadStats() async {
        if let session = manager?.connection as? NETunnelProviderSession, status == .connected {
            let data: Data? = await withCheckedContinuation { cont in
                do {
                    try session.sendProviderMessage(Data("stats".utf8)) { cont.resume(returning: $0) }
                } catch {
                    cont.resume(returning: nil)
                }
            }
            if let data, let fresh = try? JSONDecoder.iso.decode(ShieldStats.self, from: data) {
                stats = fresh
                return
            }
        }
        stats = statsFile.load() ?? stats
    }

    func resetStats() {
        try? statsFile.save(ShieldStats())
        sendMessage("resetStats")
        stats = ShieldStats()
    }

    // MARK: Lists

    func setSource(_ id: String, enabled: Bool) {
        guard let i = config.sources.firstIndex(where: { $0.id == id }) else { return }
        config.sources[i].enabled = enabled
        saveConfig()
    }

    func allow(_ domain: String) {
        let d = domain.lowercased().trimmingCharacters(in: .whitespaces)
        guard BlocklistParser.isValidDomain(d), !config.allowlist.contains(d) else { return }
        config.allowlist.append(d)
        config.customBlocked.removeAll { $0 == d }
        saveConfig()
        writeAllowlist()
        reloadTunnel()
    }

    func block(_ domain: String) {
        let d = domain.lowercased().trimmingCharacters(in: .whitespaces)
        guard BlocklistParser.isValidDomain(d), !config.customBlocked.contains(d) else { return }
        config.customBlocked.append(d)
        config.allowlist.removeAll { $0 == d }
        saveConfig()
        writeAllowlist()
        Task { await updateBlocklists(downloading: false) }
    }

    func removeAllowed(at offsets: IndexSet) {
        config.allowlist.remove(atOffsets: offsets)
        saveConfig()
        writeAllowlist()
        reloadTunnel()
    }

    func removeCustomBlocked(at offsets: IndexSet) {
        config.customBlocked.remove(atOffsets: offsets)
        saveConfig()
        Task { await updateBlocklists(downloading: false) }
    }

    /// Downloads enabled lists, merges them with the starter list and custom
    /// rules, and hands the result to the tunnel.
    func updateBlocklists(downloading: Bool = true) async {
        isUpdatingLists = true
        defer { isUpdatingLists = false }

        let cacheDir = AppGroup.containerURL.appendingPathComponent("blocklist-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let enabled = config.sources.filter(\.enabled)

        let downloaded: [(String, String?)] = await withTaskGroup(of: (String, String?).self) { group in
            for source in enabled {
                group.addTask {
                    let cache = cacheDir.appendingPathComponent("\(source.id).txt")
                    if downloading,
                       let result = try? await URLSession.shared.data(from: source.url),
                       (result.1 as? HTTPURLResponse)?.statusCode == 200,
                       let text = String(data: result.0, encoding: .utf8) {
                        try? result.0.write(to: cache, options: .atomic)
                        return (source.name, text)
                    }
                    return (source.name, try? String(contentsOf: cache, encoding: .utf8))
                }
            }
            var results: [(String, String?)] = []
            for await r in group { results.append(r) }
            return results
        }

        let merged: (count: Int, text: String) = await Task.detached(priority: .userInitiated) { [config] in
            var set = Set(ShieldFiles.starterDomains)
            set.formUnion(config.customBlocked)
            for (_, text) in downloaded {
                guard let text else { continue }
                set.formUnion(BlocklistParser.domains(from: text))
            }
            // Keep the tunnel well under its memory limit.
            let capped = set.count > 400_000 ? Array(set.prefix(400_000)) : Array(set)
            return (capped.count, capped.joined(separator: "\n"))
        }.value

        let failures = downloaded.filter { $0.1 == nil }.map(\.0)
        let url = AppGroup.containerURL.appendingPathComponent(ShieldFiles.blocklist)
        do {
            try merged.text.write(to: url, atomically: true, encoding: .utf8)
            config.domainCount = merged.count
            if downloading { config.lastUpdated = .now }
            saveConfig()
            reloadTunnel()
        } catch {
            errorMessage = error.localizedDescription
        }
        if !failures.isEmpty {
            errorMessage = "Couldn't download: \(failures.joined(separator: ", ")). Using the last saved copy."
        }
    }

    // MARK: Plumbing

    private func ensureListFilesExist() {
        let url = AppGroup.containerURL.appendingPathComponent(ShieldFiles.blocklist)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? ShieldFiles.starterDomains.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        writeAllowlist()
    }

    private func writeAllowlist() {
        let url = AppGroup.containerURL.appendingPathComponent(ShieldFiles.allowlist)
        try? config.allowlist.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func saveConfig() { try? configFile.save(config) }

    private func reloadTunnel() { sendMessage("reload") }

    private func sendMessage(_ text: String) {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else { return }
        try? session.sendProviderMessage(Data(text.utf8)) { _ in }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
