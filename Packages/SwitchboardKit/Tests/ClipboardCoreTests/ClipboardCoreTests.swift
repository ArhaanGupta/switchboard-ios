import XCTest
import SwitchboardCore
@testable import ClipboardCore

final class ClipboardStoreTests: XCTestCase {
    var store: ClipboardStore!
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID()).json")
        store = ClipboardStore(file: JSONFile(url: url))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testAddIgnoresEmptyAndDeduplicates() {
        XCTAssertNil(store.add(text: "   \n"))
        let first = store.add(text: "hello", at: Date(timeIntervalSince1970: 1))
        store.add(text: "world", at: Date(timeIntervalSince1970: 2))
        let again = store.add(text: "hello", at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(first?.id, again?.id)
        XCTAssertEqual(store.items().map(\.text), ["hello", "world"])
    }

    func testPinnedItemsSortFirstAndSurvivePruning() {
        store.updateSettings { $0.maxItems = 2 }
        let pinned = store.add(text: "keep me", at: Date(timeIntervalSince1970: 0))!
        store.togglePin(pinned.id)
        for i in 1...5 { store.add(text: "item \(i)", at: Date(timeIntervalSince1970: Double(i))) }
        XCTAssertEqual(store.items().map(\.text), ["keep me", "item 5", "item 4"])
        store.clearUnpinned()
        XCTAssertEqual(store.items().map(\.text), ["keep me"])
    }

    func testSnippetsReorder() {
        let db = store.database()
        XCTAssertEqual(db.snippets.count, 3)
        store.moveSnippets(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.snippets().last?.title, db.snippets.first?.title)
    }

    func testKindDetection() {
        XCTAssertEqual(ClipItem.detectKind("https://apple.com/iphone"), .link)
        XCTAssertEqual(ClipItem.detectKind("someone@example.com"), .email)
        XCTAssertEqual(ClipItem.detectKind("+1 (555) 123-4567"), .text, "contains spaces")
        XCTAssertEqual(ClipItem.detectKind("+15551234567"), .phone)
        XCTAssertEqual(ClipItem.detectKind("just some words"), .text)
    }

    func testPreviewCollapsesWhitespace() {
        XCTAssertEqual(ClipItem(text: "a\n\n  b\tc").preview, "a b c")
    }
}

final class TemplateRendererTests: XCTestCase {
    func testTokens() {
        let r = TemplateRenderer(now: Date(timeIntervalSince1970: 1_795_000_000),
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 timeZone: TimeZone(identifier: "UTC")!,
                                 clipboard: "CLIP")
        XCTAssertEqual(r.render("{isodate}"), "2026-11-18")
        XCTAssertEqual(r.render("Paste: {clipboard}!"), "Paste: CLIP!")
        XCTAssertEqual(r.render("no tokens"), "no tokens")
        XCTAssertFalse(r.render("{date}").contains("{"))
    }
}
