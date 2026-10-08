import XCTest

/// A take outlives the process that recorded it. The recorder writes a
/// fragmented file into a folder the system never purges, and the library
/// imports what a kill left behind on the next launch; a take an import
/// refused stays listed until saved or deleted.
final class TakeRecoveryUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Record for a while, kill the app without stopping, relaunch: the take
    /// is in the library, not lost and not left unsaved.
    @MainActor
    func testKilledTakeIsRecoveredOnNextLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5), "toolbar should offer Record Audio")
        recordItem.tap()
        allowMicrophone()

        XCTAssertTrue(app.buttons["Stop & Save"].waitForExistence(timeout: 10), "record sheet should be recording")
        // Past one fragment interval with room to spare, so the kill cannot
        // land before anything readable has reached the file.
        let elapsed = app.staticTexts["record-elapsed"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, elapsed.label < "00:09" { sleep(1) }
        XCTAssertGreaterThanOrEqual(elapsed.label, "00:09", "the take should have run for nine seconds")
        app.buttons["record-mark"].tap()
        snap(app, "01-recording-before-kill")

        // No Stop & Save: the process goes with the take still open.
        app.terminate()

        app.launchArguments = ["--uitest-relaunch"]
        app.launch()
        snap(app, "02-library-after-relaunch")

        XCTAssertTrue(waitForRestingJob(app), "the recovered take should become a recording in the library")
        XCTAssertFalse(app.descendants(matching: .any)["unsaved-take"].firstMatch.exists,
                       "a recovered take must not also be listed as unsaved")
        snap(app, "03-recovered")
    }

    /// A take whose import was refused is listed, and Save puts it through.
    @MainActor
    func testRefusedTakeIsListedAndSavable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-unsaved-take"]
        app.launch()

        let row = app.descendants(matching: .any)["unsaved-take"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the staged take should be listed as unsaved")
        snap(app, "01-unsaved-take")

        app.buttons["unsaved-take-save"].firstMatch.tap()
        XCTAssertTrue(waitForRestingJob(app), "saving should import the take and run the pipeline")
        XCTAssertFalse(row.exists, "a saved take leaves the unsaved list")
        snap(app, "02-saved")
    }

    // MARK: - Helpers

    private func allowMicrophone() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }
    }

    /// The same resting states `RecordingFlowUITests` accepts: complete,
    /// failed, or parked at the model-download question, answered "Not now"
    /// so the test never depends on the network.
    private func waitForRestingJob(_ app: XCUIApplication) -> Bool {
        let complete = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        let failed = app.descendants(matching: .any)["status-FAILED"].firstMatch
        let parked = app.descendants(matching: .any)["status-PAUSED"].firstMatch
        let notNow = app.buttons["Not now"].firstMatch
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if notNow.exists { notNow.tap() }
            if complete.exists || failed.exists || parked.exists { return true }
            sleep(3)
        }
        return false
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
