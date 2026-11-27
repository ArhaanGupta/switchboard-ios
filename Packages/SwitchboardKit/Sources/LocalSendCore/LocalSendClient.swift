import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sending side of LocalSend: discovers peers by probing the local subnet and
/// uploads files. Has no UI dependencies, so the app and the share extension
/// both use it.
public final class LocalSendClient: NSObject, @unchecked Sendable {
    public enum SendResult: Equatable, Sendable {
        case done
        case declined
        case busy
        case failed(String)
    }

    public let me: DeviceInfo
    private var session: URLSession!

    public init(me: DeviceInfo) {
        self.me = me
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Discovery

    /// Asks one host whether it runs LocalSend (tries HTTPS first, then HTTP).
    public func probe(host: String, timeout: TimeInterval = 1.2) async -> Peer? {
        for scheme in ["https", "http"] {
            guard let url = URL(string: "\(scheme)://\(host):\(LocalSend.defaultPort)\(LocalSend.Endpoint.register)") else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(me)
            guard let result = try? await session.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  var info = try? JSONDecoder().decode(DeviceInfo.self, from: result.0),
                  info.fingerprint != me.fingerprint else { continue }
            info.transport = info.transport ?? scheme
            info.port = info.port ?? Int(LocalSend.defaultPort)
            return Peer(info: info, host: host)
        }
        return nil
    }

    /// Probes every address in the local /24, at most `concurrency` at a time.
    public func scanSubnet(concurrency: Int = 48, onPeer: @escaping @Sendable (Peer) -> Void) async {
        guard let subnet = NetworkInterfaces.localIPv4Subnet() else { return }
        await withTaskGroup(of: Peer?.self) { group in
            var launched = 0
            for host in subnet.hosts where host != subnet.ownAddress {
                if launched >= concurrency, let finished = await group.next(), let peer = finished {
                    onPeer(peer)
                }
                group.addTask { [self] in await self.probe(host: host) }
                launched += 1
            }
            for await peer in group {
                if let peer { onPeer(peer) }
            }
        }
    }

    /// Tells a peer we exist (the reply to a multicast announcement).
    public func register(with peer: Peer) async {
        guard let base = peer.baseURL else { return }
        var request = URLRequest(url: base.appendingPathComponent(LocalSend.Endpoint.register), timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(me)
        _ = try? await session.data(for: request)
    }

    // MARK: Sending

    /// Sends files to a peer. `progress` reports (bytesSent, totalBytes).
    public func send(files urls: [URL], to peer: Peer,
                     progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async -> SendResult {
        guard let base = peer.baseURL, !urls.isEmpty else { return .failed("Nothing to send") }
        var files: [String: FileMetadata] = [:]
        var paths: [String: URL] = [:]
        for url in urls {
            let id = UUID().uuidString
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            files[id] = FileMetadata(id: id, fileName: url.lastPathComponent, size: size,
                                     fileType: MIMEType.forFileName(url.lastPathComponent))
            paths[id] = url
        }
        let total = files.values.reduce(0) { $0 + $1.size }

        do {
            var request = URLRequest(url: base.appendingPathComponent(LocalSend.Endpoint.prepareUpload), timeoutInterval: 75)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(PrepareUploadRequest(info: me, files: files))
            let (data, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 204: return .done
            case 403: return .declined
            case 409: return .busy
            case let status: return .failed("Error \(status)")
            }
            let prepared = try JSONDecoder().decode(PrepareUploadResponse.self, from: data)

            var completed: Int64 = 0
            for (fileId, token) in prepared.files {
                guard let fileURL = paths[fileId], let meta = files[fileId],
                      var components = URLComponents(url: base.appendingPathComponent(LocalSend.Endpoint.upload),
                                                     resolvingAgainstBaseURL: false) else { continue }
                components.queryItems = [URLQueryItem(name: "sessionId", value: prepared.sessionId),
                                         URLQueryItem(name: "fileId", value: fileId),
                                         URLQueryItem(name: "token", value: token)]
                guard let uploadURL = components.url else { continue }
                var upload = URLRequest(url: uploadURL, timeoutInterval: 600)
                upload.httpMethod = "POST"
                upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let alreadySent = completed
                let delegate = UploadProgressDelegate { sent in progress(alreadySent + sent, total) }
                let (_, uploadResponse) = try await session.upload(for: upload, fromFile: fileURL, delegate: delegate)
                guard (uploadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                    return .failed("\(meta.fileName) was rejected")
                }
                completed += meta.size
                progress(completed, total)
            }
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension LocalSendClient: URLSessionDelegate {
    /// LocalSend peers use self-signed certificates on the local network.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (Int64) -> Void
    init(_ onProgress: @escaping (Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}

/// Finds this device's Wi-Fi IPv4 address so the local subnet can be scanned.
public enum NetworkInterfaces {
    public struct Subnet: Sendable {
        public let ownAddress: String
        public let hosts: [String]
    }

    public static func localIPv4Subnet() -> Subnet? {
        #if canImport(Darwin)
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
            if let subnet = subnet(around: ip) { return subnet }
        }
        #endif
        return nil
    }

    /// The /24 around an IPv4 address (large subnets would take too long to scan).
    public static func subnet(around ip: String) -> Subnet? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        let prefix = parts.prefix(3).joined(separator: ".")
        return Subnet(ownAddress: ip, hosts: (1...254).map { "\(prefix).\($0)" })
    }
}
