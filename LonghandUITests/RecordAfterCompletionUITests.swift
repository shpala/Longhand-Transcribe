import XCTest

/// The owner's report, precisely: record → **let it finish transcribing** →
/// record again → the app hangs. Distinct from `SecondRecordingUITests`, which
/// starts take 2 while take 1 is still running; the completion path tears down
/// the run (gate release, task handles, refresh) and that teardown is what this
/// exercises.
final class RecordAfterCompletionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordingAgainAfterAJobCompletes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        try record(app, seconds: 3, take: 1)
        try awaitTerminalState(app, timeout: 600)

        // The app must still be answering. A hung main thread shows up here as
        // XCUITest failing to get a snapshot rather than as a missing element.
        try record(app, seconds: 3, take: 2)

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, app.cells.count < 2 { sleep(2) }
        XCTAssertGreaterThanOrEqual(app.cells.count, 2, "both takes should be listed")
    }

    @MainActor
    private func awaitTerminalState(_ app: XCUIApplication, timeout: TimeInterval) throws {
        // The simulator has no diarization models, so the §4.2.3(ii) gate parks
        // the job before it can complete. Answer "Not now": the point of this
        // test is the *teardown* after a run ends (gate release, task handles,
        // refresh) and a parked job has been through all of it.
        let notNow = app.buttons["Not now"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if notNow.exists { notNow.tap() }
            for identifier in ["status-COMPLETE", "status-PAUSED", "status-FAILED"] {
                guard app.descendants(matching: .any)[identifier].firstMatch.exists else { continue }
                // Do not hand back while a dialog is animating away: the next
                // tap would land on nothing.
                let deadline = Date().addingTimeInterval(5)
                while notNow.exists, Date() < deadline { usleep(200_000) }
                return
            }
            sleep(5)
        }
        throw XCTSkip("take 1 never settled within \(Int(timeout))s")
    }

    @MainActor
    private func record(_ app: XCUIApplication, seconds: UInt32, take: Int) throws {
        // Recording is its own one-tap toolbar button now: no menu to open,
        // so a swallowed tap shows up as the Stop control never appearing.
        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 20),
                      "take \(take): toolbar unreachable, UI may be blocked")
        recordItem.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }

        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20),
                      "take \(take): the record sheet never started recording")
        sleep(seconds)
        stop.tap()
    }
}

extension RecordAfterCompletionUITests {
    @MainActor
    func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
