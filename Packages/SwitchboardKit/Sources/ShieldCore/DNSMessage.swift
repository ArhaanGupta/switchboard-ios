import Foundation

public enum DNSRecordType {
    public static let a: UInt16 = 1
    public static let aaaa: UInt16 = 28
    public static let https: UInt16 = 65
}

public struct DNSQuestion: Equatable, Sendable {
    public var name: String
    public var type: UInt16
    public var qclass: UInt16
}

public struct DNSQuery: Equatable, Sendable {
    public var id: UInt16
    public var flags: UInt16
    public var questions: [DNSQuestion]
    /// Raw bytes of the first question section (name + type + class).
    public var firstQuestionBytes: [UInt8]
}

public enum DNSParser {
    /// Parses a DNS query message. Returns nil for responses or malformed data.
    public static func parseQuery(_ bytes: [UInt8]) -> DNSQuery? {
        guard bytes.count >= 12 else { return nil }
        let id = readUInt16(bytes, 0)
        let flags = readUInt16(bytes, 2)
        guard flags & 0x8000 == 0 else { return nil } // QR bit set = response
        let qdcount = Int(readUInt16(bytes, 4))
        guard qdcount >= 1, qdcount <= 8 else { return nil }

        var offset = 12
        var questions: [DNSQuestion] = []
        var firstQuestionBytes: [UInt8] = []
        for index in 0..<qdcount {
            let start = offset
            guard let (name, next) = readName(bytes, offset), next + 4 <= bytes.count else { return nil }
            let type = readUInt16(bytes, next)
            let qclass = readUInt16(bytes, next + 2)
            offset = next + 4
            questions.append(DNSQuestion(name: name, type: type, qclass: qclass))
            if index == 0 { firstQuestionBytes = Array(bytes[start..<offset]) }
        }
        return DNSQuery(id: id, flags: flags, questions: questions, firstQuestionBytes: firstQuestionBytes)
    }

    /// Reads a (possibly compressed) domain name. Returns the lowercase name
    /// without a trailing dot and the offset just after the name in the
    /// original position.
    public static func readName(_ bytes: [UInt8], _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var endOffset: Int?
        var jumps = 0
        var totalLength = 0

        while true {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset])
            if length == 0 {
                offset += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < bytes.count else { return nil }
                let pointer = ((length & 0x3F) << 8) | Int(bytes[offset + 1])
                if endOffset == nil { endOffset = offset + 2 }
                jumps += 1
                guard jumps < 16, pointer < bytes.count else { return nil }
                offset = pointer
                continue
            }
            guard length <= 63, offset + 1 + length <= bytes.count else { return nil }
            totalLength += length + 1
            guard totalLength <= 255 else { return nil }
            let labelBytes = bytes[(offset + 1)..<(offset + 1 + length)]
            labels.append(String(decoding: labelBytes, as: UTF8.self).lowercased())
            offset += 1 + length
        }
        return (labels.joined(separator: "."), endOffset ?? offset)
    }

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}

public enum BlockMode: String, Codable, CaseIterable, Sendable {
    /// Answer A/AAAA with 0.0.0.0 / :: (fast failure in most apps).
    case nullIP
    /// Answer "no such domain".
    case nxdomain
}

public enum DNSResponder {
    /// Builds the response for a blocked query.
    public static func blockedResponse(for query: DNSQuery, mode: BlockMode = .nullIP) -> [UInt8] {
        let qtype = query.questions.first?.type ?? 0
        let rd = query.flags & 0x0100
        let opcode = query.flags & 0x7800
        // QR=1, RA=1, keep opcode & RD.
        var flags: UInt16 = 0x8000 | opcode | rd | 0x0080

        var answer: [UInt8] = []
        switch mode {
        case .nxdomain:
            flags |= 3
        case .nullIP:
            if qtype == DNSRecordType.a {
                answer = answerRecord(type: DNSRecordType.a, rdata: [0, 0, 0, 0])
            } else if qtype == DNSRecordType.aaaa {
                answer = answerRecord(type: DNSRecordType.aaaa, rdata: [UInt8](repeating: 0, count: 16))
            }
            // Other types (HTTPS, TXT, ...) get NOERROR with no answers.
        }

        var out: [UInt8] = []
        out.reserveCapacity(12 + query.firstQuestionBytes.count + answer.count)
        append(query.id, to: &out)
        append(flags, to: &out)
        append(1, to: &out)                                   // QDCOUNT
        append(answer.isEmpty ? 0 : 1, to: &out)              // ANCOUNT
        append(0, to: &out)                                   // NSCOUNT
        append(0, to: &out)                                   // ARCOUNT
        out += query.firstQuestionBytes
        out += answer
        return out
    }

    /// SERVFAIL — used when the upstream resolver can't be reached.
    public static func serverFailure(for query: DNSQuery) -> [UInt8] {
        var out: [UInt8] = []
        append(query.id, to: &out)
        append(0x8000 | (query.flags & 0x7900) | 0x0080 | 2, to: &out)
        append(1, to: &out); append(0, to: &out); append(0, to: &out); append(0, to: &out)
        out += query.firstQuestionBytes
        return out
    }

    private static func answerRecord(type: UInt16, rdata: [UInt8]) -> [UInt8] {
        var r: [UInt8] = [0xC0, 0x0C] // pointer to the question name
        append(type, to: &r)
        append(1, to: &r)             // IN
        r += [0, 0, 0, 60]            // TTL 60s
        append(UInt16(rdata.count), to: &r)
        r += rdata
        return r
    }

    static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }
}
