import Foundation
import NetworkExtension
import os
import ShieldCore
import SwitchboardCore

/// DNS-only packet tunnel. The tunnel claims a single fake resolver address
/// (10.111.0.1) and becomes the system DNS server; only packets addressed to
/// it enter the tunnel, so normal traffic never passes through here.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let tunnelAddress = "10.111.0.2"
    private static let resolverAddress = "10.111.0.1"

    private let log = Logger(subsystem: "Switchboard", category: "Shield")
    private let queue = DispatchQueue(label: "shield.tunnel")
    private var rules = ShieldRules()
    private var blockMode: BlockMode = .nullIP
    private var forwarder: DNSForwarder?
    private var stats = ShieldStats()
    private var statsDirty = false
    private var flushTimer: DispatchSourceTimer?
    private var packetID: UInt16 = 1

    private let statsFile = JSONFile<ShieldStats>(name: ShieldFiles.stats)

    // MARK: Lifecycle

    override func startTunnel(options: [String: NSObject]?) async throws {
        stats = statsFile.load() ?? ShieldStats()
        queue.sync { loadConfiguration() }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [Self.tunnelAddress], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.resolverAddress, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [Self.resolverAddress])
        dns.matchDomains = [""] // all domains
        settings.dnsSettings = dns
        settings.mtu = 1500

        try await setTunnelNetworkSettings(settings)
        startFlushTimer()
        readPackets()
        log.info("Shield started with \(self.rules.blocked.count) blocked domains")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        queue.sync {
            flushStats()
            flushTimer?.cancel()
            forwarder?.stop()
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let message = String(decoding: messageData, as: UTF8.self)
        return queue.sync { () -> Data? in
            switch message {
            case "reload":
                loadConfiguration()
                return Data("ok".utf8)
            case "resetStats":
                stats = ShieldStats()
                statsDirty = true
                flushStats()
                return Data("ok".utf8)
            case "stats":
                return try? JSONFile<ShieldStats>.encoderForMessages.encode(stats)
            default:
                return nil
            }
        }
    }

    override func sleep() async {
        queue.sync { flushStats() }
    }

    // MARK: Configuration (call on `queue`)

    private func loadConfiguration() {
        let dir = AppGroup.containerURL
        let blocked = Self.readList(dir.appendingPathComponent(ShieldFiles.blocklist))
        let allowed = Self.readList(dir.appendingPathComponent(ShieldFiles.allowlist))
        rules = ShieldRules(blocked: DomainSet(blocked.isEmpty ? ShieldFiles.starterDomains : blocked),
                            allowed: DomainSet(allowed))

        let defaults = AppGroup.defaults
        blockMode = BlockMode(rawValue: defaults.string(forKey: SharedKey.shieldBlockMode) ?? "") ?? .nullIP
        let upstream = defaults.string(forKey: SharedKey.shieldUpstreamDNS) ?? "1.1.1.1"
        if forwarder?.server != upstream {
            forwarder?.stop()
            forwarder = DNSForwarder(server: upstream, queue: queue)
        }
    }

    private static func readList(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Packet loop

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                for packet in packets { self.handle(packet) }
            }
            self.readPackets()
        }
    }

    private func handle(_ data: Data) {
        guard let packet = IPv4UDP.parse([UInt8](data)), packet.destinationPort == 53,
              let query = DNSParser.parseQuery(packet.payload),
              let question = query.questions.first else { return }

        let enabled = FeatureFlags().isEnabled(.shield)
        let decision = enabled ? rules.decision(for: question.name) : .allow
        record(question.name, blocked: decision == .block)

        switch decision {
        case .block:
            write(packet.reply(with: DNSResponder.blockedResponse(for: query, mode: blockMode)))
        case .allow:
            guard let forwarder else {
                write(packet.reply(with: DNSResponder.serverFailure(for: query)))
                return
            }
            forwarder.resolve(packet.payload) { [weak self] response in
                // Called on `queue`.
                guard let self else { return }
                let answer = response ?? DNSResponder.serverFailure(for: query)
                self.write(packet.reply(with: answer))
            }
        }
    }

    private func write(_ packet: UDPPacket) {
        packetID &+= 1
        let bytes = IPv4UDP.build(packet, identification: packetID)
        packetFlow.writePackets([Data(bytes)], withProtocols: [NSNumber(value: AF_INET)])
    }

    // MARK: Stats

    private func record(_ domain: String, blocked: Bool) {
        stats.record(domain: domain, blocked: blocked)
        statsDirty = true
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.flushStats() }
        timer.resume()
        flushTimer = timer
    }

    private func flushStats() {
        guard statsDirty else { return }
        statsDirty = false
        try? statsFile.save(stats)
    }
}

extension JSONFile {
    static var encoderForMessages: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
