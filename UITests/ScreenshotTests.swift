import XCTest

/// Launches the app with demo data, visits every module and attaches a
/// screenshot of each. CI exports these into docs/screenshots for the README.
final class ScreenshotTests: XCTestCase {
    private let modules: [(id: String, name: String)] = [
        ("clipboard", "02-Clipboard"),
        ("stickyNotes", "03-StickyNotes"),
        ("shield", "04-Shield"),
        ("shareAnywhere", "05-ShareAnywhere"),
        ("floatingWindow", "06-FloatingWindow"),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAppLaunchesAndEveryModuleOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-demoData"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Switchboard"].waitForExistence(timeout: 10), "Home screen did not appear")
        snapshot("01-Home")

        for module in modules {
            let card = app.descendants(matching: .any)["module.\(module.id)"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), "Missing card for \(module.id)")
            if !card.isHittable { app.swipeUp() }
            card.tap()

            // Let animations and async loads settle.
            _ = app.navigationBars.element.waitForExistence(timeout: 5)
            Thread.sleep(forTimeInterval: 1.5)
            snapshot(module.name)

            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Switchboard"].waitForExistence(timeout: 5))
            if module.id == "shield" { app.swipeDown() }
        }
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
