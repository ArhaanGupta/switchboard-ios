import XCTest
@testable import QRCore

final class QRPayloadTests: XCTestCase {
    func testWiFiRoundTripWithEscaping() {
        let network = QRPayload.WiFiNetwork(ssid: "Café;Guest", password: #"p@ss:wo,rd\"#, security: .wpa, hidden: true)
        let encoded = QRPayload.wifi(network).encoded
        XCTAssertEqual(encoded, #"WIFI:T:WPA;S:Café\;Guest;P:p@ss\:wo\,rd\\;H:true;;"#)
        XCTAssertEqual(QRPayload.parse(encoded), .wifi(network))
    }

    func testOpenWiFiOmitsPassword() {
        let encoded = QRPayload.wifi(.init(ssid: "Library", security: .open)).encoded
        XCTAssertEqual(encoded, "WIFI:T:nopass;S:Library;;")
        guard case let .wifi(parsed) = QRPayload.parse(encoded) else { return XCTFail() }
        XCTAssertEqual(parsed.security, .open)
    }

    func testFieldOrderDoesNotMatter() {
        guard case let .wifi(w) = QRPayload.parse("WIFI:S:Home;P:secret;T:WPA;;") else { return XCTFail() }
        XCTAssertEqual(w.ssid, "Home")
        XCTAssertEqual(w.password, "secret")
    }

    func testContactRoundTrip() {
        let contact = QRPayload.Contact(name: "Ada Lovelace", phone: "+44 20 7946 0000",
                                        email: "ada@example.com", organization: "Analytical, Ltd")
        XCTAssertEqual(QRPayload.parse(QRPayload.contact(contact).encoded), .contact(contact))
    }

    func testVCardStructuredName() {
        let raw = "BEGIN:VCARD\nVERSION:3.0\nN:Hopper;Grace;;;\nTEL;TYPE=CELL:555-0100\nEND:VCARD"
        guard case let .contact(c) = QRPayload.parse(raw) else { return XCTFail() }
        XCTAssertEqual(c.name, "Grace Hopper")
        XCTAssertEqual(c.phone, "555-0100")
    }

    func testClassification() {
        XCTAssertEqual(QRPayload.parse("https://apple.com/iphone"), .url(URL(string: "https://apple.com/iphone")!))
        XCTAssertEqual(QRPayload.parse("mailto:hi@example.com?subject=Hey"), .email("hi@example.com"))
        XCTAssertEqual(QRPayload.parse("tel:+15550100"), .phone("+15550100"))
        XCTAssertEqual(QRPayload.parse("just words"), .text("just words"))
        XCTAssertEqual(QRPayload.parse("WIFI:T:WPA;;"), .text("WIFI:T:WPA;;"), "no SSID → plain text")
    }

    func testPhoneEncodingStripsFormatting() {
        XCTAssertEqual(QRPayload.phone("+1 (555) 010-0000").encoded, "tel:+15550100000")
    }
}

final class QRHistoryTests: XCTestCase {
    func testDedupKeepsFavoriteAndMovesToTop() {
        var history = QRHistory()
        history.record("a", source: .scanned)
        history.record("b", source: .scanned)
        history.items[1].isFavorite = true // "a"
        history.record("a", source: .created)
        XCTAssertEqual(history.items.map(\.raw), ["a", "b"])
        XCTAssertTrue(history.items[0].isFavorite)
        XCTAssertEqual(history.items[0].source, .created)
    }

    func testLimitKeepsFavorites() {
        var history = QRHistory()
        history.record("fav", source: .scanned)
        history.items[0].isFavorite = true
        for i in 0..<(QRHistory.limit + 5) { history.record("item \(i)", source: .scanned) }
        XCTAssertEqual(history.items.count, QRHistory.limit)
        XCTAssertTrue(history.items.contains { $0.raw == "fav" })
        XCTAssertEqual(history.items.first?.raw, "item \(QRHistory.limit + 4)")
    }
}
