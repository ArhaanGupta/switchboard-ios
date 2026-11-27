import XCTest
@testable import SwitchboardCore

final class FeatureFlagTests: XCTestCase {
    func testDefaultsAndOverrides() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let flags = FeatureFlags(defaults: defaults)
        XCTAssertTrue(flags.isEnabled(.clipboard))
        XCTAssertFalse(flags.isEnabled(.shield))
        flags.setEnabled(true, for: .shield)
        flags.setEnabled(false, for: .clipboard)
        XCTAssertTrue(flags.isEnabled(.shield))
        XCTAssertFalse(flags.isEnabled(.clipboard))
    }
}

final class StickyNoteStoreTests: XCTestCase {
    func testToggleAndWidgetNote() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sticky-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StickyNoteStore(file: JSONFile(url: url))
        let item = ChecklistItem(text: "Milk")
        let note = StickyNote(title: "Groceries", items: [item])
        store.upsert(note)
        store.setWidgetNote(id: note.id)
        XCTAssertEqual(store.widgetNote()?.title, "Groceries")
        XCTAssertEqual(store.toggleItem(item.id, inNote: note.id)?.completedCount, 1)
        store.delete(id: note.id)
        XCTAssertNil(store.widgetNote())
        XCTAssertTrue(store.notes().isEmpty)
    }

    func testDisplayTitleFallsBackToBody() {
        XCTAssertEqual(StickyNote(body: "First line\nSecond").displayTitle, "First line")
        XCTAssertEqual(StickyNote().displayTitle, "Untitled note")
    }
}
