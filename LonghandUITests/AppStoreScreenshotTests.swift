import XCTest

/// Produces the App Store screenshot set by driving the shipping UI, so the
/// pictures on the listing can be regenerated after a redesign instead of
/// being retaken by hand.
///
/// The assertions are here to make a wrong screen fail the run rather than
/// attach a photograph of itself; nothing about behaviour is being tested.
/// `--uitest-reset` is deliberately absent, because the demo library
/// `driver.sh seed-store-demo` puts in the container is the whole point.
/// Attachments come out with `driver.sh attachments`.
final class AppStoreScreenshotTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-seeded"]
        app.launch()

        let library = app.staticTexts["Longhand"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15), "library should appear")
        snap(app, "01-library")

        let review = app.staticTexts["Design review"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5), "demo job should be listed")
        review.tap()
        // Waiting on a chip rather than on the title: the title is in place
        // before the turns are, and a screenshot taken then is a blank page.
        let chip = app.buttons["Dana"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "speaker chips should render")
        snap(app, "02-transcript")

        chip.tap()
        let rename = app.descendants(matching: .any)["rename-speaker"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "chip should open the speaker menu")
        snap(app, "03-speaker-menu")
        dismissMenu(app)
        back(app)

        let hebrew = app.staticTexts["פגישת צוות"].firstMatch
        XCTAssertTrue(hebrew.waitForExistence(timeout: 5), "Hebrew job should be listed")
        hebrew.tap()
        XCTAssertTrue(app.buttons["Me"].firstMatch.waitForExistence(timeout: 10),
                      "Hebrew transcript should render")
        snap(app, "04-hebrew")
        back(app)

        // Settings opens at the medium detent, which is half a form. Dragging
        // the navigation bar up takes it to `.large`; the swipe after that is
        // past Language, Speakers and Location to the model section, which is
        // the part worth photographing.
        app.buttons["Settings"].firstMatch.tap()
        let settingsBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 5), "settings should open")
        settingsBar.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        snap(app, "05-settings")

        // How far down Enrolled Voices sits depends on whether an interrupted
        // download left a Storage row behind, so scroll until it is there
        // rather than assuming a fixed number of swipes.
        let voices = app.buttons["Enrolled Voices"].firstMatch
        for _ in 0..<4 where !voices.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(voices.exists, "Enrolled Voices should be reachable in Settings")
        voices.tap()
        XCTAssertTrue(app.navigationBars["Enrolled Voices"].waitForExistence(timeout: 5),
                      "voices should open")
        snap(app, "06-voices")
        app.navigationBars["Enrolled Voices"].buttons.element(boundBy: 0).tap()
        sleep(1)

        let record = app.buttons["Record Audio"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5), "record button should be back")
        record.tap()
        // Long enough for the level meter to have drawn something and the
        // timer to be off zero.
        sleep(3)
        snap(app, "07-record")
    }

    /// The library is a NavigationStack on iPhone and a split view on iPad, so
    /// going back is a button on one and nothing at all on the other.
    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists, button.isHittable { button.tap() }
        sleep(1)
    }

    /// Tapping the transcript to close the menu would seek the player, so the
    /// tap goes to the navigation bar instead.
    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        sleep(1)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
