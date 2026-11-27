import Foundation
import LocalSendCore
import Network
import SwitchboardCore
import UIKit

/// Thread-safe box for state shared with the server queue.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func read<T>(_ body: (Value) throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body(value) }
    func write<T>(_ body: (inout Value) throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body(&value) }
}

/// LocalSend-compatible sending and receiving.
@MainActor
@Observable
final class LocalSendService {
    struct IncomingRequest: Identifiable {
        let id = UUID()
        let sender: DeviceInfo
        let files: [FileMetadata]
        let respond: (Bool) -> Void
        var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    struct Transfer: Identifiable {
        enum Direction { case incoming, outgoing }
        enum State: Equatable { case running, done, failed(String) }
        let id = UUID()
        let peerName: String
        let direction: Direction
        var fileCount: Int
        var totalBytes: Int64
        var doneBytes: Int64 = 0
        var state: State = .running
        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    }

    // UI state
    private(set) var isRunning = false
    private(set) var peers: [Peer] = []
    private(set) var transfers: [Transfer] = []
    private(set) var receivedFiles: [URL] = []
    private(set) var isScanning = false
    private(set) var multicastAvailable: Bool?
    var incoming: IncomingRequest?
    var errorMessage: String?

    var alias: String {
        didSet { defaults.set(alias, forKey: "share.alias"); publishInfo() }
    }
    var autoAccept: Bool {
        didSet { defaults.set(autoAccept, forKey: "share.autoAccept") }
    }

    private let defaults = AppGroup.defaults
    private let fingerprint: String
    private let serverInfo: Locked<DeviceInfo>
    private let sessions = Locked(ReceiveSessionManager())
    private var server: HTTPServer?
    private var multicast: NWConnectionGroup?
    private var pendingTransferID: UUID?
    @ObservationIgnored private var cachedClient: LocalSendClient?

    /// Rebuilt whenever our device info (e.g. the alias) changes.
    private var client: LocalSendClient {
        if let cachedClient, cachedClient.me == myInfo { return cachedClient }
        let fresh = LocalSendClient(me: myInfo)
        cachedClient = fresh
        return fresh
    }

    nonisolated static var receivedDirectory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        let d = AppGroup.defaults
        let fp = d.string(forKey: "share.fingerprint") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        d.set(fp, forKey: "share.fingerprint")
        fingerprint = fp
        let storedAlias = d.string(forKey: "share.alias") ?? AliasGenerator.make()
        alias = storedAlias
        autoAccept = d.bool(forKey: "share.autoAccept")
        serverInfo = Locked(DeviceInfo(alias: storedAlias, deviceModel: "iPhone", deviceType: .mobile,
                                       fingerprint: fp, transport: "http"))
        refreshReceived()
    }

    private var myInfo: DeviceInfo { serverInfo.read { $0 } }

    private func publishInfo() {
        let alias = self.alias
        serverInfo.write { $0.alias = alias }
    }

    // MARK: Start / stop

    func start() {
        guard !isRunning else { return }
        let server = HTTPServer(port: LocalSend.defaultPort) { [weak self] head, host in
            self?.route(head, host: host) ?? .respond(.status(503))
        }
        server.onStateChange = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor in
                    self?.errorMessage = "Couldn't start receiving: \(error.localizedDescription)"
                    self?.stop()
                }
            }
        }
        do {
            try server.start()
            self.server = server
            isRunning = true
            UIApplication.shared.isIdleTimerDisabled = true
            startMulticast()
            Task { await refreshPeers() }
        } catch {
            errorMessage = "Couldn't start receiving: \(error.localizedDescription)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
        multicast?.cancel()
        multicast = nil
        isRunning = false
        peers = []
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Discovery

    private func startMulticast() {
        do {
            let group = try NWMulticastGroup(for: [.hostPort(host: .init(LocalSend.multicastGroup),
                                                             port: .init(rawValue: LocalSend.defaultPort)!)])
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let connection = NWConnectionGroup(with: group, using: params)
            connection.setReceiveHandler(maximumMessageSize: 16_384, rejectOversizedMessages: true) { [weak self] message, content, _ in
                guard let content, let info = try? JSONDecoder().decode(DeviceInfo.self, from: content) else { return }
                var host = ""
                if case let .hostPort(h, _) = message.remoteEndpoint { host = "\(h)" }
                Task { @MainActor in self?.didDiscover(info, host: host) }
            }
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.multicastAvailable = true
                        self?.announce()
                    case .failed, .waiting:
                        // Usually means the multicast entitlement is missing; fall back to scanning.
                        self?.multicastAvailable = false
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
            multicast = connection
        } catch {
            multicastAvailable = false
        }
    }

    private func announce() {
        guard let multicast, let data = try? JSONEncoder().encode(myInfo.announcing(true)) else { return }
        multicast.send(content: data) { _ in }
    }

    private func didDiscover(_ info: DeviceInfo, host: String) {
        guard info.fingerprint != fingerprint, !host.isEmpty else { return }
        addPeer(Peer(info: info, host: host))
        if info.announce == true {
            // Answer like LocalSend does: register with them over HTTP(S).
            Task { await register(with: Peer(info: info, host: host)) }
        }
    }

    private func addPeer(_ peer: Peer) {
        if let i = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[i] = peer
        } else {
            peers.append(peer)
            peers.sort { $0.info.alias.localizedCaseInsensitiveCompare($1.info.alias) == .orderedAscending }
        }
    }

    /// Announce via multicast and, as a fallback, sweep the local /24 subnet.
    func refreshPeers() async {
        announce()
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        await client.scanSubnet { [weak self] peer in
            Task { @MainActor in self?.addPeer(peer) }
        }
    }

    private func register(with peer: Peer) async {
        await client.register(with: peer)
    }

    // MARK: Server routing (runs on the server queue)

    nonisolated private func route(_ head: HTTPRequestHead, host: String) -> RouteAction {
        guard head.method == "POST" || head.method == "GET" else { return .respond(.status(405)) }
        switch head.path {
        case LocalSend.Endpoint.register:
            return .buffer(maxBytes: 64 * 1024) { [weak self] body, reply in
                guard let self else { return reply(.status(503)) }
                if let info = try? JSONDecoder().decode(DeviceInfo.self, from: body) {
                    Task { @MainActor in self.didDiscover(info.announcing(false), host: host) }
                }
                reply(.json(self.serverInfo.read { $0 }))
            }

        case LocalSend.Endpoint.info:
            return .respond(.json(serverInfo.read { $0 }))

        case LocalSend.Endpoint.prepareUpload:
            return .buffer(maxBytes: 2 * 1024 * 1024) { [weak self] body, reply in
                guard let self else { return reply(.status(503)) }
                guard let request = try? JSONDecoder().decode(PrepareUploadRequest.self, from: body) else {
                    return reply(.status(400, message: "Invalid body"))
                }
                guard FeatureFlags().isEnabled(.shareAnywhere) else { return reply(.status(403)) }
                Task { @MainActor in
                    self.askToAccept(request, host: host) { accepted in
                        guard accepted else { return reply(.status(403, message: "Declined")) }
                        do {
                            let response = try self.sessions.write {
                                try $0.prepare(sender: request.info, host: host, files: request.files)
                            }
                            reply(.json(response))
                        } catch {
                            reply(.status(409, message: "Blocked by another session"))
                        }
                    }
                }
            }

        case LocalSend.Endpoint.upload:
            let check = sessions.write {
                $0.checkUpload(sessionId: head.query["sessionId"], fileId: head.query["fileId"], token: head.query["token"])
            }
            switch check {
            case .invalidParameters: return .respond(.status(400, message: "Missing parameters"))
            case .forbidden: return .respond(.status(403, message: "Invalid token"))
            case .ok(let file):
                let destination = FileNaming.uniqueURL(for: file.fileName, in: Self.receivedDirectory)
                return .stream(to: destination, expectedBytes: file.size, progress: { [weak self] bytes in
                    Task { @MainActor in self?.updateIncomingProgress(fileId: file.id, bytes: bytes) }
                }, completion: { [weak self] ok in
                    guard let self else { return .status(500) }
                    if ok {
                        let finished = self.sessions.write { $0.complete(fileId: file.id) }
                        Task { @MainActor in self.fileReceived(destination, finished: finished) }
                        return .status(200)
                    }
                    Task { @MainActor in self.failIncoming("Transfer interrupted") }
                    return .status(500)
                })
            }

        case LocalSend.Endpoint.cancel:
            sessions.write { $0.cancel(sessionId: head.query["sessionId"]) }
            Task { @MainActor in self.failIncoming("Cancelled by sender") }
            return .respond(.status(200))

        default:
            return .respond(.status(404))
        }
    }

    // MARK: Receiving (main actor)

    private var incomingProgress: [String: Int64] = [:]

    private func askToAccept(_ request: PrepareUploadRequest, host: String, completion: @escaping (Bool) -> Void) {
        let files = Array(request.files.values)
        let begin = { [weak self] in
            guard let self else { return }
            self.incomingProgress = [:]
            let transfer = Transfer(peerName: request.info.alias, direction: .incoming,
                                    fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
            self.transfers.insert(transfer, at: 0)
            self.pendingTransferID = transfer.id
        }
        if autoAccept {
            begin()
            return completion(true)
        }
        var answered = false
        let respond: (Bool) -> Void = { [weak self] accepted in
            guard !answered else { return }
            answered = true
            self?.incoming = nil
            if accepted { begin() }
            completion(accepted)
        }
        incoming = IncomingRequest(sender: request.info, files: files, respond: respond)
        Haptics.warning()
        // Senders give up after a while; decline automatically after 60s.
        Task {
            try? await Task.sleep(for: .seconds(60))
            respond(false)
        }
    }

    private func updateIncomingProgress(fileId: String, bytes: Int64) {
        incomingProgress[fileId] = bytes
        guard let id = pendingTransferID, let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].doneBytes = incomingProgress.values.reduce(0, +)
    }

    private func fileReceived(_ url: URL, finished: Bool) {
        refreshReceived()
        guard finished, let id = pendingTransferID, let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].state = .done
        transfers[i].doneBytes = transfers[i].totalBytes
        pendingTransferID = nil
        sessions.write { $0.finish() }
        Haptics.success()
    }

    private func failIncoming(_ reason: String) {
        incoming?.respond(false)
        guard let id = pendingTransferID, let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].state = .failed(reason)
        pendingTransferID = nil
    }

    func refreshReceived() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.receivedDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        receivedFiles = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    func deleteReceived(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshReceived()
    }

    // MARK: Sending

    func send(_ urls: [URL], to peer: Peer) async {
        guard !urls.isEmpty else { return }
        let sizes = urls.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0 }
        let transfer = Transfer(peerName: peer.info.alias, direction: .outgoing,
                                fileCount: urls.count, totalBytes: Int64(sizes.reduce(0, +)))
        transfers.insert(transfer, at: 0)
        let transferID = transfer.id

        let result = await client.send(files: urls, to: peer) { [weak self] sent, _ in
            Task { @MainActor in
                guard let self, let i = self.transfers.firstIndex(where: { $0.id == transferID }) else { return }
                self.transfers[i].doneBytes = sent
            }
        }

        guard let i = transfers.firstIndex(where: { $0.id == transferID }) else { return }
        switch result {
        case .done:
            transfers[i].state = .done
            transfers[i].doneBytes = transfers[i].totalBytes
            Haptics.success()
        case .declined:
            transfers[i].state = .failed("Declined by \(peer.info.alias)")
        case .busy:
            transfers[i].state = .failed("\(peer.info.alias) is busy")
        case .failed(let reason):
            transfers[i].state = .failed(reason)
        }
    }


    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }
}
