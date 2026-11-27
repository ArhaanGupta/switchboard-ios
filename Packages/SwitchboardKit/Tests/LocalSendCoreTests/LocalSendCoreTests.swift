import XCTest
@testable import LocalSendCore

final class HTTPParserTests: XCTestCase {
    func testParsesRequestHead() {
        let raw = "POST /api/localsend/v2/upload?sessionId=abc&fileId=f%201&token=t HTTP/1.1\r\n" +
                  "Host: 192.168.1.5:53317\r\nContent-Length: 42\r\nX-Thing:  spaced \r\n\r\nBODY"
        guard case let .complete(head, length) = HTTPParser.parseHead(Array(raw.utf8)) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/api/localsend/v2/upload")
        XCTAssertEqual(head.query["fileId"], "f 1")
        XCTAssertEqual(head.contentLength, 42)
        XCTAssertEqual(head.headers["x-thing"], "spaced")
        XCTAssertEqual(length, raw.utf8.count - 4)
    }

    func testIncompleteAndMalformed() {
        XCTAssertEqual(HTTPParser.parseHead(Array("GET / HTTP/1.1\r\nHost: x".utf8)), .incomplete)
        XCTAssertEqual(HTTPParser.parseHead(Array("NONSENSE\r\n\r\n".utf8)), .malformed)
    }

    func testResponseSerialization() {
        let text = String(decoding: HTTPResponse.status(204).serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 0"))
    }
}

final class ModelTests: XCTestCase {
    func testDeviceInfoUsesProtocolKey() throws {
        let json = #"{"alias":"Desk","version":"2.1","deviceModel":"Windows","deviceType":"desktop","fingerprint":"abc","port":53317,"protocol":"https","download":false,"announce":true}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.transport, "https")
        XCTAssertEqual(info.deviceType, .desktop)
        let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""protocol":"https""#))
    }

    func testUnknownDeviceTypeDecodes() throws {
        let json = #"{"alias":"X","version":"2.0","deviceType":"toaster","fingerprint":"f"}"#
        XCTAssertEqual(try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8)).deviceType, .desktop)
    }

    func testPeerURL() {
        let peer = Peer(info: DeviceInfo(alias: "a", fingerprint: "f", port: 1234, transport: "https"), host: "10.0.0.7")
        XCTAssertEqual(peer.baseURL?.absoluteString, "https://10.0.0.7:1234")
    }
}

final class ReceiveSessionTests: XCTestCase {
    var counter = 0
    lazy var manager = ReceiveSessionManager { [unowned self] in
        self.counter += 1
        return "t\(self.counter)"
    }
    let sender = DeviceInfo(alias: "Phone", fingerprint: "sender")
    let file = FileMetadata(id: "f1", fileName: "a.jpg", size: 10, fileType: "image/jpeg")

    func testHappyPath() throws {
        let response = try manager.prepare(sender: sender, host: "1.2.3.4", files: ["f1": file])
        XCTAssertEqual(manager.checkUpload(sessionId: response.sessionId, fileId: "f1", token: response.files["f1"]), .ok(file))
        XCTAssertTrue(manager.complete(fileId: "f1"))
        XCTAssertEqual(manager.checkUpload(sessionId: response.sessionId, fileId: "f1", token: response.files["f1"]), .forbidden,
                       "a file can't be uploaded twice")
    }

    func testRejectsBadTokenAndBusy() throws {
        let response = try manager.prepare(sender: sender, host: "h", files: ["f1": file])
        XCTAssertEqual(manager.checkUpload(sessionId: response.sessionId, fileId: "f1", token: "nope"), .forbidden)
        XCTAssertEqual(manager.checkUpload(sessionId: nil, fileId: "f1", token: "x"), .invalidParameters)
        let other = DeviceInfo(alias: "Other", fingerprint: "other")
        XCTAssertThrowsError(try manager.prepare(sender: other, host: "h2", files: ["f1": file]))
        manager.cancel(sessionId: response.sessionId)
        XCTAssertNoThrow(try manager.prepare(sender: other, host: "h2", files: ["f1": file]))
    }

    func testFileNaming() {
        XCTAssertEqual(FileNaming.sanitized("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileNaming.sanitized(".."), "file")
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.jpg", "/tmp/x/a 2.jpg"]
        XCTAssertEqual(FileNaming.uniqueURL(for: "a.jpg", in: dir, exists: { taken.contains($0.path) }).lastPathComponent, "a 3.jpg")
    }
}

final class NetworkInterfaceTests: XCTestCase {
    func testSubnetAroundAddress() throws {
        let subnet = try XCTUnwrap(NetworkInterfaces.subnet(around: "192.168.4.27"))
        XCTAssertEqual(subnet.hosts.count, 254)
        XCTAssertEqual(subnet.hosts.first, "192.168.4.1")
        XCTAssertEqual(subnet.hosts.last, "192.168.4.254")
        XCTAssertNil(NetworkInterfaces.subnet(around: "not.an.ip.addr"))
        XCTAssertNil(NetworkInterfaces.subnet(around: "300.1.1.1"))
    }

    func testClientKeepsDeviceInfo() {
        let me = DeviceInfo(alias: "Test", fingerprint: "abc")
        XCTAssertEqual(LocalSendClient(me: me).me, me)
    }
}
