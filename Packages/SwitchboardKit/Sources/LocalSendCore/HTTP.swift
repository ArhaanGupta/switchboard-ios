import Foundation

/// The parts of HTTP/1.1 the LocalSend server needs: request heads with a
/// Content-Length body, and simple responses.
public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]

    public var contentLength: Int {
        headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    }
}

public enum HTTPParseResult: Equatable, Sendable {
    case incomplete
    case malformed
    /// `headerLength` includes the terminating blank line.
    case complete(HTTPRequestHead, headerLength: Int)
}

public enum HTTPParser {
    public static let maxHeaderSize = 16 * 1024

    public static func parseHead(_ bytes: [UInt8]) -> HTTPParseResult {
        guard let end = findHeaderEnd(bytes) else {
            return bytes.count > maxHeaderSize ? .malformed : .incomplete
        }
        let headerText = String(decoding: bytes[0..<end], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .malformed }

        let target = String(requestLine[1])
        let (path, query) = splitTarget(target)
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let head = HTTPRequestHead(method: String(requestLine[0]).uppercased(),
                                   path: path, query: query, headers: headers)
        return .complete(head, headerLength: end + 4)
    }

    static func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else {
            return (target.removingPercentEncoding ?? target, [:])
        }
        let path = String(target[..<q])
        var query: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).replacingOccurrences(of: "+", with: " ")
            let value = kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
            query[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
        }
        return (path.removingPercentEncoding ?? path, query)
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: [UInt8]
    public var contentType: String

    public init(status: Int, body: [UInt8] = [], contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(status: status, body: [UInt8](data))
    }

    public static func status(_ code: Int, message: String? = nil) -> HTTPResponse {
        guard let message else { return HTTPResponse(status: code) }
        return .json(["message": message], status: code)
    }

    public func serialized() -> [UInt8] {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return [UInt8](head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        default: return status >= 500 ? "Internal Server Error" : "Unknown"
        }
    }
}
