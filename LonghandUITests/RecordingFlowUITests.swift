import XCTest

/// Drives the in-app recording flow end to end: record → pause/resume →
/// stop & save → import options → job appears in the library.
final class RecordingFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordSaveAndImportFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()
        snap(app, "01-library")

        // Recording has its own one-tap toolbar button; no menu to open.
        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5), "toolbar should offer Record Audio")
        recordItem.tap()

        // Mic permission alert (if simctl pre-grant didn't cover it).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }

        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "record sheet should be recording")
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 5))
        sleep(4)
        snap(app, "02-recording")

        app.buttons["Pause"].tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5))
        snap(app, "03-paused")
        app.buttons["Resume"].tap()
        sleep(2)

        stop.tap()
        // Streamlined flow: no options interrogation after Stop & Save,
        // processing starts immediately with saved defaults.
        snap(app, "04-processing-started")

        // The job row should appear and eventually settle in a terminal state.
        // Simulator transcription may legitimately fail (OS-managed speech
        // assets are not always downloadable in simulators); the flow under
        // test is recording → import → pipeline reaching a *visible* terminal
        // state, never a hang or a silent disappearance.
        let complete = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        let failed = app.descendants(matching: .any)["status-FAILED"].firstMatch
        // A simulator has no Community-1 models and the §4.2.3(ii) gate stops
        // to ask before fetching them, which parks the job. That is a resting
        // state the user can see and act on, so it settles this test. It is
        // not the pipeline hanging. Answering "Not now" is the deterministic
        // choice; tapping Download would make this test depend on the network.
        let notNow = app.buttons["Not now"].firstMatch
        let parked = app.descendants(matching: .any)["status-PAUSED"].firstMatch
        // Generous: a first-ever run may download OS speech assets, the
        // Community-1 diarization models, or (in simulators, where Apple's
        // engine has no locales and routing falls through to WhisperKit)
        // the 626 MB Whisper model before inference can start.
        let deadline = Date().addingTimeInterval(900)
        var settled = false
        while Date() < deadline {
            if notNow.exists { notNow.tap() }
            if complete.exists || failed.exists || parked.exists { settled = true; break }
            sleep(3)
        }
        snap(app, "05-library-after")
        XCTAssertTrue(settled, "job should reach a visible resting state")

        // If it completed, open the transcript screen.
        if complete.exists {
            app.cells.firstMatch.tap()
            sleep(2)
            snap(app, "06-transcript")
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
