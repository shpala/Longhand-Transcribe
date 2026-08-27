import XCTest

/// The owner's report: after one recording, opening the recorder again does
/// nothing and the controls vanish. The distinguishing detail against the
/// existing coverage is that `SpeakerRecognitionUITests` waits for the first
/// job to reach COMPLETE before recording again. This does not, because the
/// person holding the phone does not.
final class SecondRecordingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordingTwiceInARowStillOffersTheControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        try record(app, seconds: 3, take: 1)
        // No wait for COMPLETE: the first job is still transcribing, which is
        // exactly the state the report describes.
        try record(app, seconds: 3, take: 2)

        // Both takes must exist as jobs; a second recording that silently did
        // nothing leaves one.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.cells.count < 2 { sleep(1) }
        XCTAssertGreaterThanOrEqual(app.cells.count, 2,
                                    "both takes should have become jobs")
    }

    @MainActor
    private func record(_ app: XCUIApplication, seconds: UInt32, take: Int) throws {
        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 10), "take \(take): toolbar unreachable")
        recordItem.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }

        // The whole bug in one assertion: on take 2 the sheet is reported to
        // come up with no controls at all.
        let stop = app.buttons["Stop & Save"]
        if !stop.waitForExistence(timeout: 10) {
            snap(app, "take\(take)-no-controls")
            XCTFail("take \(take): the record sheet came up with no Stop control. Status reads “\(statusText(app))”")
            return
        }
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 5),
                      "take \(take): sheet is not recording. Status reads “\(statusText(app))”")
        sleep(seconds)
        snap(app, "take\(take)-recording")
        stop.tap()
    }

    /// The sheet's status line distinguishes the two failure shapes: "Starting…"
    /// means `start()` never took, "Saved" means the recorder was reused after
    /// a finished take.
    @MainActor
    private func statusText(_ app: XCUIApplication) -> String {
        for candidate in ["Starting…", "Saved", "Recording", "Paused", "Interrupted, not recording"] {
            if app.staticTexts[candidate].exists { return candidate }
        }
        return "unknown"
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A start that fails must be a state you can see and act on. Before this the
/// sheet showed "Starting…" over an empty control row for ever, the shape the
/// owner reported from the phone, where the real cause (another audio client
/// holding the input) cannot be reproduced in a simulator.
final class RecordFailureStateUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAFailedStartSaysSoAndOffersARetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-fail-record"]
        app.launch()

        app.buttons["Record Audio"].tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }

        let retry = app.buttons["record-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10),
                      "a failed start must offer a way to try again, not an empty row")
        XCTAssertTrue(app.staticTexts["Couldn't start"].exists,
                      "the status line must stop claiming the recorder is starting")
        XCTAssertFalse(app.staticTexts["Starting…"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "failed-start"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Cancel still works from the failure state; the sheet is not a trap.
        // (Nothing has been captured, so Cancel needs no confirmation here.)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Record Audio"].waitForExistence(timeout: 5))
    }
}
