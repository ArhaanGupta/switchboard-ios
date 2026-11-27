import Foundation
import Network

/// Forwards allowed DNS queries to the upstream resolver over one UDP socket.
/// Query IDs are rewritten so answers can be matched back to callers even
/// when two apps happen to use the same ID. Not thread-safe: use from `queue`.
final class DNSForwarder {
    let server: String
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var pending: [UInt16: Pending] = [:]
    private var nextID = UInt16.random(in: 1...UInt16.max)

    private struct Pending {
        let originalID: (UInt8, UInt8)
        let completion: ([UInt8]?) -> Void
        let timeout: DispatchWorkItem
    }

    init(server: String, queue: DispatchQueue) {
        self.server = server
        self.queue = queue
    }

    func stop() {
        connection?.cancel()
        connection = nil
        for (_, p) in pending {
            p.timeout.cancel()
            p.completion(nil)
        }
        pending.removeAll()
    }

    func resolve(_ query: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        guard query.count >= 12 else { return completion(nil) }
        let connection = ensureConnection()

        var id = nextID
        while pending[id] != nil { id &+= 1 }
        nextID = id &+ 1

        var rewritten = query
        rewritten[0] = UInt8(id >> 8)
        rewritten[1] = UInt8(id & 0xFF)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pending.removeValue(forKey: id) else { return }
            p.completion(nil)
        }
        pending[id] = Pending(originalID: (query[0], query[1]), completion: completion, timeout: timeout)
        queue.asyncAfter(deadline: .now() + 4, execute: timeout)

        connection.send(content: Data(rewritten), completion: .contentProcessed { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async {
                if let p = self.pending.removeValue(forKey: id) {
                    p.timeout.cancel()
                    p.completion(nil)
                }
                self.resetConnection()
            }
        })
    }

    private func ensureConnection() -> NWConnection {
        if let connection { return connection }
        let params = NWParameters.udp
        params.prohibitedInterfaceTypes = [.other] // never loop back into our own tunnel
        let conn = NWConnection(host: NWEndpoint.Host(server), port: 53, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.queue.async { self?.resetConnection() } }
        }
        conn.start(queue: queue)
        connection = conn
        receive(on: conn)
        return conn
    }

    private func resetConnection() {
        connection?.cancel()
        connection = nil
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= 12 {
                var bytes = [UInt8](data)
                let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                if let p = self.pending.removeValue(forKey: id) {
                    p.timeout.cancel()
                    bytes[0] = p.originalID.0
                    bytes[1] = p.originalID.1
                    p.completion(bytes)
                }
            }
            if error == nil, self.connection === conn {
                self.receive(on: conn)
            }
        }
    }
}
