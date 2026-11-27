import Foundation
import LocalSendCore
import Network

/// What a route wants to do with the request body.
enum RouteAction {
    /// Respond immediately (body ignored).
    case respond(HTTPResponse)
    /// Buffer the whole body (small JSON) then produce a response, possibly asynchronously.
    case buffer(maxBytes: Int, handler: (Data, @escaping (HTTPResponse) -> Void) -> Void)
    /// Stream the body into a file, then produce a response.
    case stream(to: URL, expectedBytes: Int64, progress: (Int64) -> Void, completion: (Bool) -> HTTPResponse)
}

/// Tiny HTTP/1.1 server on Network.framework — just enough for LocalSend.
final class HTTPServer {
    typealias Router = (_ head: HTTPRequestHead, _ remoteHost: String) -> RouteAction

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "share.http")
    private var listener: NWListener?
    private let router: Router
    var onStateChange: ((NWListener.State) -> Void)?

    init(port: UInt16, router: @escaping Router) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.router = router
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        let listener = try NWListener(using: params, on: port)
        listener.stateUpdateHandler = { [weak self] state in self?.onStateChange?(state) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let handler = ConnectionHandler(connection: connection, queue: self.queue, router: self.router)
            handler.start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Handles one request on one connection (LocalSend uses Connection: close semantics).
private final class ConnectionHandler {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let router: HTTPServer.Router
    private var buffer: [UInt8] = []
    private var selfRetain: ConnectionHandler?

    init(connection: NWConnection, queue: DispatchQueue, router: @escaping HTTPServer.Router) {
        self.connection = connection
        self.queue = queue
        self.router = router
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.selfRetain = nil
            default: break
            }
        }
        connection.start(queue: queue)
        readHead()
    }

    private var remoteHost: String {
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
            case .name(let n, _): return n
            @unknown default: return "\(host)"
            }
        }
        return ""
    }

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer += data }
            switch HTTPParser.parseHead(self.buffer) {
            case .incomplete:
                if isComplete || error != nil { self.close() } else { self.readHead() }
            case .malformed:
                self.send(.status(400))
            case let .complete(head, headerLength):
                let leftover = Array(self.buffer[headerLength...])
                self.buffer = []
                self.dispatch(head, leftover: leftover)
            }
        }
    }

    private func dispatch(_ head: HTTPRequestHead, leftover: [UInt8]) {
        switch router(head, remoteHost) {
        case .respond(let response):
            send(response)

        case let .buffer(maxBytes, handler):
            let length = head.contentLength
            guard length <= maxBytes else { return send(.status(413)) }
            readBody(length: length, collected: leftover) { [weak self] body in
                guard let self else { return }
                guard let body else { return self.close() }
                handler(Data(body)) { response in
                    self.queue.async { self.send(response) }
                }
            }

        case let .stream(url, expected, progress, completion):
            let length = Int64(head.contentLength)
            guard length == expected || expected <= 0 else { return send(.status(400)) }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return send(.status(500)) }
            var received: Int64 = 0
            if !leftover.isEmpty {
                handle.write(Data(leftover))
                received += Int64(leftover.count)
                progress(received)
            }
            streamBody(handle: handle, remaining: length - received, received: received, progress: progress) { [weak self] ok in
                try? handle.close()
                if !ok { try? FileManager.default.removeItem(at: url) }
                self?.send(completion(ok))
            }
        }
    }

    private func readBody(length: Int, collected: [UInt8], done: @escaping ([UInt8]?) -> Void) {
        if collected.count >= length { return done(Array(collected.prefix(length))) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let next = collected + (data.map { [UInt8]($0) } ?? [])
            if next.count >= length { return done(Array(next.prefix(length))) }
            if isComplete || error != nil { return done(nil) }
            self.readBody(length: length, collected: next, done: done)
        }
    }

    private func streamBody(handle: FileHandle, remaining: Int64, received: Int64,
                            progress: @escaping (Int64) -> Void, done: @escaping (Bool) -> Void) {
        if remaining <= 0 { return done(true) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var remaining = remaining
            var received = received
            if let data, !data.isEmpty {
                let chunk = data.count > remaining ? data.prefix(Int(remaining)) : data
                handle.write(chunk)
                remaining -= Int64(chunk.count)
                received += Int64(chunk.count)
                progress(received)
            }
            if remaining <= 0 { return done(true) }
            if isComplete || error != nil { return done(false) }
            self.streamBody(handle: handle, remaining: remaining, received: received, progress: progress, done: done)
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: Data(response.serialized()), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        connection.cancel()
        selfRetain = nil
    }
}
