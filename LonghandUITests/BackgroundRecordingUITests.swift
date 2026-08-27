import XCTest

/// A take keeps recording while the app is in the background. Without the
/// `audio` background mode iOS suspends the recorder with the app, the clock
/// stops at the moment Home is pressed, and a meeting recorded with the screen
/// locked comes back a few seconds long.
///
/// Device only in effect: the simulator does not suspend the recorder, so it
/// passes there with or without the key. On an iPhone, removing the key fails
/// it the way the bug did, with 3 s recorded out of 10 (checked 2 Oct 2026).
final class BackgroundRecordingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordingContinuesInBackground() throws {
        let app = XCUIApplication()
        // Never on a phone: the reset deletes the library and every enrolled
        // voice, and the owner's phone holds real recordings.
        #if targetEnvironment(simulator)
        app.launchArguments = ["--uitest-reset"]
        #endif
        app.launch()

        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5), "toolbar should offer Record Audio")
        recordItem.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }

        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 10),
                      "record sheet should be recording")
        let elapsed = app.staticTexts["record-elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        sleep(2)
        let before = seconds(elapsed.label)

        XCUIDevice.shared.press(.home)
        sleep(10)
        app.activate()

        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 10),
                      "the take should still be recording after returning")
        let after = seconds(elapsed.label)
        XCTAssertGreaterThanOrEqual(after - before, 9,
                                    "the clock should have kept running in the background "
                                    + "(\(elapsed.label), was \(before) s)")

        app.buttons["Cancel"].tap()
        let discard = app.buttons["Discard Recording"]
        if discard.waitForExistence(timeout: 5) { discard.tap() }
    }

    /// "mm:ss" or "h:mm:ss".
    private func seconds(_ label: String) -> Int {
        label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }
}
