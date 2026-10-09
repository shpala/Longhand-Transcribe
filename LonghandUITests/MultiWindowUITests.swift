import UIKit
import XCTest

/// A transcript in a second window on iPad. Needs an iPad simulator
/// (`LONGHAND_SIM_ID`) and `seed-sim`; skips on an iPhone, which has one
/// window.
final class MultiWindowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testATranscriptOpensInASecondWindow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("several windows need an iPad")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-mute-playback"]
        app.launch()

        let row = app.cells.containing(.any, identifier: "status-COMPLETE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the seeded recording should be listed")
        let windowsBefore = app.windows.count
        row.press(forDuration: 1.0)
        let open = app.buttons["open-in-new-window"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "an iPad row should offer Open in New Window")
        open.tap()

        // The new scene lands beside the library; the transcript's chip is
        // the sign it loaded.
        XCTAssertTrue(app.buttons["Speaker 1"].firstMatch.waitForExistence(timeout: 15),
                      "the new window should show the transcript")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.windows.count <= windowsBefore { usleep(250_000) }
        XCTAssertGreaterThan(app.windows.count, windowsBefore, "a second window should exist")
        snap(app, "01-two-windows")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
