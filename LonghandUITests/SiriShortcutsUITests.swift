import XCTest

/// The App Shortcuts phrases, spoken to Siri as text: "Start recording with
/// Longhand" opens the record sheet with the microphone running, and "Stop
/// recording with Longhand" saves the take without touching the app.
final class SiriShortcutsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSiriStartsAndStopsARecording() throws {
        let app = XCUIApplication()
        // Never on a phone: the reset deletes the library and every enrolled
        // voice, and the owner's phone holds real recordings.
        #if targetEnvironment(simulator)
        app.launchArguments = ["--uitest-reset"]
        #endif
        app.launch()
        XCTAssertTrue(app.buttons["Record Audio"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(1)

        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Start recording with Longhand")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A fresh simulator says "Siri Not Available: Data for using Siri is
        // downloading" for a long while. That is the environment, not the app.
        if springboard.staticTexts["Siri Not Available"].waitForExistence(timeout: 4) {
            throw XCTSkip("Siri is not available on this device yet")
        }
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Siri should open Longhand")
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 15),
                      "the record sheet should open already recording")
        snap(app, "01-siri-started")
        sleep(3)

        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Stop recording with Longhand")
        sleep(4)
        snap(springboard, "02-siri-stopped")
        app.activate()
        XCTAssertFalse(app.buttons["Stop & Save"].waitForExistence(timeout: 3),
                       "the record sheet should be gone once Siri saved the take")
        let newest = app.cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10) && isTestTake(newest),
                      "the saved take should be the newest row in the library")
        snap(app, "03-saved")

        #if !targetEnvironment(simulator)
        deleteTestTake(app)
        #endif
    }

    /// The app's half without Siri: a request made before the library exists,
    /// as on a cold launch from a shortcut, opens the record sheet recording.
    @MainActor
    func testARecordRequestAtLaunchOpensTheRecorder() throws {
        let app = XCUIApplication()
        #if targetEnvironment(simulator)
        app.launchArguments = ["--uitest-reset", "--uitest-request-record"]
        #else
        app.launchArguments = ["--uitest-request-record"]
        #endif
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 15),
                      "the request should open the record sheet, already recording")
        app.buttons["Cancel"].tap()
        let discard = app.buttons["Discard Recording"]
        if discard.waitForExistence(timeout: 5) { discard.tap() }
    }

    /// A phone keeps what it records, and this take is not the owner's. The
    /// newest row is deleted only if its title is the timestamp of a take made
    /// in the last few minutes, which on a phone in use for this test can only
    /// be the test's own. Anything else is left exactly where it is.
    private func deleteTestTake(_ app: XCUIApplication) {
        let row = app.cells.firstMatch
        guard row.waitForExistence(timeout: 5) else { return }
        guard isTestTake(row) else {
            XCTFail("newest row is not this test's take (\(row.label)); left in place")
            return
        }
        row.press(forDuration: 1.0)
        let delete = app.buttons["Delete"]
        guard delete.waitForExistence(timeout: 3) else { return }
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete “'")).firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
    }

    /// A take is titled with the time it was made, so a title stamped within
    /// the last few minutes is this test's.
    private func isTestTake(_ row: XCUIElement) -> Bool {
        (0...4).contains { minutesAgo in
            let stamp = Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
                .formatted(date: .abbreviated, time: .shortened)
            return row.label.contains(stamp)
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
