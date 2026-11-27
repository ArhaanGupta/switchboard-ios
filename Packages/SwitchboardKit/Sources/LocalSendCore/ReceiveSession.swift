import Foundation

/// Tracks the single active incoming transfer (LocalSend allows one at a time).
/// Not thread-safe: call from one serial queue.
public final class ReceiveSessionManager {
    public struct Session: Equatable {
        public var id: String
        public var sender: DeviceInfo
        public var senderHost: String
        public var files: [String: FileMetadata]
        public var tokens: [String: String]
        public var completed: Set<String> = []
        public var createdAt: Date

        public var isFinished: Bool { completed.count == files.count }
    }

    public enum UploadCheck: Equatable {
        case ok(FileMetadata)
        case invalidParameters
        case forbidden
    }

    public enum PrepareError: Error, Equatable {
        case busy
        case empty
    }

    public private(set) var active: Session?
    private let tokenFactory: () -> String

    public init(tokenFactory: @escaping () -> String = { UUID().uuidString }) {
        self.tokenFactory = tokenFactory
    }

    /// Creates a session for the accepted files. Fails with `.busy` if another
    /// transfer is still running (unless it's from the same sender).
    public func prepare(sender: DeviceInfo, host: String, files: [String: FileMetadata],
                        now: Date = .now) throws -> PrepareUploadResponse {
        guard !files.isEmpty else { throw PrepareError.empty }
        if let active, !active.isFinished, active.sender.fingerprint != sender.fingerprint,
           now.timeIntervalSince(active.createdAt) < 600 {
            throw PrepareError.busy
        }
        var tokens: [String: String] = [:]
        for id in files.keys { tokens[id] = tokenFactory() }
        let session = Session(id: tokenFactory(), sender: sender, senderHost: host,
                              files: files, tokens: tokens, createdAt: now)
        active = session
        return PrepareUploadResponse(sessionId: session.id, files: tokens)
    }

    public func checkUpload(sessionId: String?, fileId: String?, token: String?) -> UploadCheck {
        guard let sessionId, let fileId, let token else { return .invalidParameters }
        guard let active, active.id == sessionId,
              active.tokens[fileId] == token,
              let file = active.files[fileId],
              !active.completed.contains(fileId) else { return .forbidden }
        return .ok(file)
    }

    /// Marks a file as received. Returns true when the whole session is done.
    @discardableResult
    public func complete(fileId: String) -> Bool {
        guard active != nil else { return false }
        active?.completed.insert(fileId)
        if active?.isFinished == true {
            return true
        }
        return false
    }

    public func cancel(sessionId: String?) {
        if sessionId == nil || active?.id == sessionId { active = nil }
    }

    public func finish() { active = nil }
}

/// Makes received file names safe and unique inside a directory.
public enum FileNaming {
    public static func sanitized(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "file" }
        return String(cleaned.prefix(200))
    }

    public static func uniqueURL(for name: String, in directory: URL,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let safe = sanitized(name)
        var url = directory.appendingPathComponent(safe)
        guard exists(url) else { return url }
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            url = directory.appendingPathComponent(candidate)
            n += 1
        } while exists(url)
        return url
    }
}
