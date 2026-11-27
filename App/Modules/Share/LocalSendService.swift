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
    @ObservationIgnored private lazy var urlSession = URLSession(configuration: .ephemeral, delegate: LocalTrustDelegate(), delegateQueue: nil)

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
        guard !isScanning, let subnet = NetworkInterfaces.localIPv4Subnet() else { return }
        isScanning = true
        defer { isScanning = false }
        let me = myInfo
        let session = urlSession
        await withTaskGroup(of: Peer?.self) { group in
            var launched = 0
            for host in subnet.hosts where host != subnet.ownAddress {
                if launched >= 48 { if let peer = await group.next() ?? nil { addPeer(peer) } }
                group.addTask { await Self.probe(host: host, me: me, session: session) }
                launched += 1
            }
            for await peer in group { if let peer { addPeer(peer) } }
        }
    }

    nonisolated private static func probe(host: String, me: DeviceInfo, session: URLSession) async -> Peer? {
        for scheme in ["https", "http"] {
            guard let url = URL(string: "\(scheme)://\(host):\(LocalSend.defaultPort)\(LocalSend.Endpoint.register)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 1.2)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(me)
            if let result = try? await session.data(for: request),
               (result.1 as? HTTPURLResponse)?.statusCode == 200,
               var info = try? JSONDecoder().decode(DeviceInfo.self, from: result.0),
               info.fingerprint != me.fingerprint {
                info.transport = info.transport ?? scheme
                info.port = info.port ?? Int(LocalSend.defaultPort)
                return Peer(info: info, host: host)
            }
        }
        return nil
    }

    private func register(with peer: Peer) async {
        guard let base = peer.baseURL else { return }
        var request = URLRequest(url: base.appendingPathComponent(LocalSend.Endpoint.register), timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(myInfo)
        _ = try? await urlSession.data(for: request)
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
        guard let base = peer.baseURL, !urls.isEmpty else { return }
        var files: [String: FileMetadata] = [:]
        var paths: [String: URL] = [:]
        for url in urls {
            let id = UUID().uuidString
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            files[id] = FileMetadata(id: id, fileName: url.lastPathComponent, size: size,
                                     fileType: MIMEType.forFileName(url.lastPathComponent))
            paths[id] = url
        }
        let transfer = Transfer(peerName: peer.info.alias, direction: .outgoing,
                                fileCount: files.count, totalBytes: files.values.reduce(0) { $0 + $1.size })
        transfers.insert(transfer, at: 0)
        let transferID = transfer.id

        func update(_ change: (inout Transfer) -> Void) {
            guard let i = transfers.firstIndex(where: { $0.id == transferID }) else { return }
            change(&transfers[i])
        }

        do {
            var request = URLRequest(url: base.appendingPathComponent(LocalSend.Endpoint.prepareUpload), timeoutInterval: 75)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(PrepareUploadRequest(info: myInfo, files: files))
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: break
            case 204: update { $0.state = .done }; return
            case 403: update { $0.state = .failed("Declined by \(peer.info.alias)") }; return
            case 409: update { $0.state = .failed("\(peer.info.alias) is busy") }; return
            default: update { $0.state = .failed("Error \(status)") }; return
            }
            let prepared = try JSONDecoder().decode(PrepareUploadResponse.self, from: data)

            var completedBytes: Int64 = 0
            for (fileId, token) in prepared.files {
                guard let fileURL = paths[fileId], let meta = files[fileId] else { continue }
                var components = URLComponents(url: base.appendingPathComponent(LocalSend.Endpoint.upload),
                                               resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "sessionId", value: prepared.sessionId),
                                         URLQueryItem(name: "fileId", value: fileId),
                                         URLQueryItem(name: "token", value: token)]
                var upload = URLRequest(url: components.url!, timeoutInterval: 600)
                upload.httpMethod = "POST"
                upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let alreadySent = completedBytes
                let progress = UploadProgress { [weak self] sent in
                    Task { @MainActor in
                        guard let self, let i = self.transfers.firstIndex(where: { $0.id == transferID }) else { return }
                        self.transfers[i].doneBytes = alreadySent + sent
                    }
                }
                let (_, uploadResponse) = try await urlSession.upload(for: upload, fromFile: fileURL, delegate: progress)
                guard (uploadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                    update { $0.state = .failed("\(meta.fileName) was rejected") }
                    return
                }
                completedBytes += meta.size
                update { $0.doneBytes = completedBytes }
            }
            update { $0.state = .done; $0.doneBytes = $0.totalBytes }
            Haptics.success()
        } catch {
            update { $0.state = .failed(error.localizedDescription) }
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }
}

/// Accepts the self-signed certificates LocalSend peers use on the local
/// network. Only used for LocalSend traffic to LAN addresses.
private final class LocalTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let onProgress: (Int64) -> Void
    init(_ onProgress: @escaping (Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Finds this device's Wi-Fi IPv4 address so we can scan the local subnet.
enum NetworkInterfaces {
    struct Subnet {
        let ownAddress: String
        let hosts: [String]
    }

    static func localIPv4Subnet() -> Subnet? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = pointer.pointee
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") else { continue }
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buffer)
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            // Always scan the surrounding /24 — large subnets would take too long.
            return Subnet(ownAddress: ip, hosts: (1...254).map { "\(prefix).\($0)" })
        }
        return nil
    }
}
