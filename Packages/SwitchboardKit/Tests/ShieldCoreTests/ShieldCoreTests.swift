import XCTest
@testable import ShieldCore

final class DNSTests: XCTestCase {
    /// Query for ads.example.com, type A, with RD set.
    func makeQuery(_ name: String = "ads.example.com", type: UInt16 = 1, id: UInt16 = 0xBEEF) -> [UInt8] {
        var b: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            b.append(UInt8(label.utf8.count))
            b += Array(label.utf8)
        }
        b += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return b
    }

    func testParsesQuery() throws {
        let q = try XCTUnwrap(DNSParser.parseQuery(makeQuery("Ads.Example.COM")))
        XCTAssertEqual(q.id, 0xBEEF)
        XCTAssertEqual(q.questions.first?.name, "ads.example.com")
        XCTAssertEqual(q.questions.first?.type, 1)
        XCTAssertEqual(q.firstQuestionBytes.count, 17 + 4)
    }

    func testRejectsResponsesAndGarbage() {
        var response = makeQuery()
        response[2] |= 0x80
        XCTAssertNil(DNSParser.parseQuery(response))
        XCTAssertNil(DNSParser.parseQuery([1, 2, 3]))
        XCTAssertNil(DNSParser.parseQuery(Array(makeQuery().prefix(15))))
    }

    func testCompressionPointerLoopIsRejected() {
        // Name at offset 12 is a pointer to itself.
        let b: [UInt8] = [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]
        XCTAssertNil(DNSParser.parseQuery(b))
    }

    func testBlockedResponseNullIP() throws {
        let q = try XCTUnwrap(DNSParser.parseQuery(makeQuery()))
        let r = DNSResponder.blockedResponse(for: q, mode: .nullIP)
        XCTAssertEqual(Array(r[0..<2]), [0xBE, 0xEF])
        XCTAssertEqual(r[2] & 0x80, 0x80, "QR bit")
        XCTAssertEqual(r[3] & 0x0F, 0, "NOERROR")
        XCTAssertEqual(Array(r[6..<8]), [0, 1], "one answer")
        XCTAssertEqual(Array(r.suffix(4)), [0, 0, 0, 0], "0.0.0.0")
    }

    func testBlockedResponseNXDomain() throws {
        let q = try XCTUnwrap(DNSParser.parseQuery(makeQuery()))
        let r = DNSResponder.blockedResponse(for: q, mode: .nxdomain)
        XCTAssertEqual(r[3] & 0x0F, 3)
        XCTAssertEqual(Array(r[6..<8]), [0, 0])
        XCTAssertEqual(r.count, 12 + q.firstQuestionBytes.count)
    }

    func testAAAAGetsZeroAddress() throws {
        let q = try XCTUnwrap(DNSParser.parseQuery(makeQuery(type: 28)))
        let r = DNSResponder.blockedResponse(for: q)
        XCTAssertEqual(Array(r.suffix(16)), [UInt8](repeating: 0, count: 16))
    }
}

final class PacketTests: XCTestCase {
    func testRoundTrip() throws {
        let p = UDPPacket(sourceAddress: [10, 111, 0, 2], destinationAddress: [10, 111, 0, 1],
                          sourcePort: 51000, destinationPort: 53, payload: [1, 2, 3, 4, 5])
        let bytes = IPv4UDP.build(p)
        XCTAssertEqual(bytes.count, 20 + 8 + 5)
        XCTAssertEqual(IPv4UDP.checksum(bytes[0..<20]), 0, "valid IP header checksum")
        XCTAssertEqual(try XCTUnwrap(IPv4UDP.parse(bytes)), p)
    }

    func testReplySwapsEndpoints() {
        let p = UDPPacket(sourceAddress: [1, 1, 1, 1], destinationAddress: [2, 2, 2, 2],
                          sourcePort: 1, destinationPort: 2, payload: [])
        let r = p.reply(with: [9])
        XCTAssertEqual(r.sourceAddress, [2, 2, 2, 2])
        XCTAssertEqual(r.destinationPort, 1)
        XCTAssertEqual(r.payload, [9])
    }

    func testRejectsTCPAndFragments() {
        var bytes = IPv4UDP.build(UDPPacket(sourceAddress: [1, 1, 1, 1], destinationAddress: [2, 2, 2, 2],
                                            sourcePort: 1, destinationPort: 53, payload: [0]))
        var tcp = bytes
        tcp[9] = 6
        XCTAssertNil(IPv4UDP.parse(tcp))
        bytes[6] = 0x20 // more fragments
        XCTAssertNil(IPv4UDP.parse(bytes))
    }
}

final class BlocklistTests: XCTestCase {
    func testParsesFormats() {
        let text = """
        # comment
        0.0.0.0 ads.example.com
        127.0.0.1 localhost
        tracker.example.org   # trailing comment
        ||pixel.example.net^
        ||cosmetic.example.net^$third-party
        example.com##.banner
        *.wild.example.io
        ! adblock comment
        @@||allowed.example.com^
        1.2.3.4
        """
        XCTAssertEqual(BlocklistParser.domains(from: text),
                       ["ads.example.com", "tracker.example.org", "pixel.example.net", "wild.example.io"])
    }

    func testSubdomainMatchingAndAllowlist() {
        let rules = ShieldRules(blocked: DomainSet(["doubleclick.net", "example.com"]),
                                allowed: DomainSet(["good.example.com"]))
        XCTAssertEqual(rules.decision(for: "doubleclick.net"), .block)
        XCTAssertEqual(rules.decision(for: "ad.g.DOUBLECLICK.net."), .block)
        XCTAssertEqual(rules.decision(for: "notdoubleclick.net"), .allow)
        XCTAssertEqual(rules.decision(for: "good.example.com"), .allow)
        XCTAssertEqual(rules.decision(for: "api.good.example.com"), .allow)
        XCTAssertEqual(rules.decision(for: "bad.example.com"), .block)
    }

    func testStatsRingBuffer() {
        var stats = ShieldStats()
        for i in 0..<(ShieldStats.recentLimit + 10) {
            stats.record(domain: "d\(i).com", blocked: i.isMultiple(of: 2))
        }
        XCTAssertEqual(stats.recent.count, ShieldStats.recentLimit)
        XCTAssertEqual(stats.totalQueries, ShieldStats.recentLimit + 10)
        XCTAssertEqual(stats.recent.first?.domain, "d\(ShieldStats.recentLimit + 9).com")
    }
}
