import Foundation

/// Implementation of the open LocalSend protocol (v2), so Switchboard can
/// exchange files with the LocalSend apps on Windows, macOS, Linux and Android.
/// Spec: https://github.com/localsend/protocol
public enum LocalSend {
    public static let defaultPort: UInt16 = 53317
    public static let multicastGroup = "224.0.0.167"
    public static let protocolVersion = "2.1"
    public static let apiBase = "/api/localsend/v2"

    public enum Endpoint {
        public static let register = "\(apiBase)/register"
        public static let prepareUpload = "\(apiBase)/prepare-upload"
        public static let upload = "\(apiBase)/upload"
        public static let cancel = "\(apiBase)/cancel"
        public static let info = "\(apiBase)/info"
    }
}

public enum DeviceType: String, Codable, Sendable, Hashable {
    case mobile, desktop, web, headless, server

    // Unknown types from future clients decode as `.desktop`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceType(rawValue: raw) ?? .desktop
    }
}

public struct DeviceInfo: Codable, Hashable, Sendable {
    public var alias: String
    public var version: String
    public var deviceModel: String?
    public var deviceType: DeviceType?
    public var fingerprint: String
    public var port: Int?
    /// "http" or "https"
    public var transport: String?
    public var download: Bool?
    public var announce: Bool?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case transport = "protocol"
    }

    public init(alias: String, version: String = LocalSend.protocolVersion, deviceModel: String? = nil,
                deviceType: DeviceType? = .mobile, fingerprint: String, port: Int? = Int(LocalSend.defaultPort),
                transport: String? = "http", download: Bool? = false, announce: Bool? = nil) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.transport = transport
        self.download = download
        self.announce = announce
    }

    public func announcing(_ flag: Bool) -> DeviceInfo {
        var copy = self
        copy.announce = flag
        return copy
    }
}

public struct FileMetadata: Codable, Hashable, Sendable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var fileType: String
    public var sha256: String?
    public var preview: String?

    public init(id: String, fileName: String, size: Int64, fileType: String,
                sha256: String? = nil, preview: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.fileType = fileType
        self.sha256 = sha256
        self.preview = preview
    }
}

public struct PrepareUploadRequest: Codable, Sendable {
    public var info: DeviceInfo
    public var files: [String: FileMetadata]

    public init(info: DeviceInfo, files: [String: FileMetadata]) {
        self.info = info
        self.files = files
    }
}

public struct PrepareUploadResponse: Codable, Sendable, Equatable {
    public var sessionId: String
    /// fileId → token
    public var files: [String: String]

    public init(sessionId: String, files: [String: String]) {
        self.sessionId = sessionId
        self.files = files
    }
}

/// A peer we discovered on the local network.
public struct Peer: Hashable, Identifiable, Sendable {
    public var info: DeviceInfo
    public var host: String

    public var id: String { info.fingerprint }

    public init(info: DeviceInfo, host: String) {
        self.info = info
        self.host = host
    }

    public var baseURL: URL? {
        let scheme = info.transport ?? "https"
        let port = info.port ?? Int(LocalSend.defaultPort)
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(hostPart):\(port)")
    }
}

/// Friendly random device names, LocalSend style ("Swift Mango").
public enum AliasGenerator {
    static let adjectives = ["Swift", "Brave", "Calm", "Clever", "Cosmic", "Fuzzy", "Lucky",
                             "Mellow", "Nimble", "Quiet", "Sunny", "Witty", "Bold", "Bright"]
    static let nouns = ["Mango", "Otter", "Falcon", "Maple", "Comet", "Panda", "Kiwi",
                        "Lynx", "Pebble", "Harbor", "Willow", "Ember", "Fjord", "Koala"]

    public static func make() -> String {
        "\(adjectives.randomElement()!) \(nouns.randomElement()!)"
    }
}

/// MIME type guess from file extension (what LocalSend puts in `fileType`).
public enum MIMEType {
    public static func forFileName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return table[ext] ?? "application/octet-stream"
    }

    static let table: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
        "heic": "image/heic", "webp": "image/webp", "mp4": "video/mp4", "mov": "video/quicktime",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "pdf": "application/pdf",
        "txt": "text/plain", "zip": "application/zip", "json": "application/json",
        "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "apk": "application/vnd.android.package-archive",
    ]
}
