import XCTest

/// A recording in the device's own search. The app indexes the library when
/// it lists it, and the test then looks for the seeded recording in
/// Spotlight. Device only: the simulator's Core Spotlight index refuses
/// every item (`CSIndexErrorDomain -1000`, index unavailable) while still
/// reporting indexing as available, so there the search finds nothing and
/// the test would read as a regression that is not one. On a device it
/// searches for the newest finished recording, whatever it is called.
final class SpotlightUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testASeededRecordingIsFoundInSpotlight() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("the simulator's Core Spotlight index refuses items (CSIndexErrorDomain -1000)")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-mute-playback"]
        app.launch()
        let row = app.cells.containing(.any, identifier: "status-COMPLETE").firstMatch
        // An empty phone library gets a short take of its own, deleted at
        // the end: what is searched for has to exist, and the test must not
        // depend on what the owner has recorded.
        if !row.waitForExistence(timeout: 5) {
            recordAShortTake(app)
            XCTAssertTrue(row.waitForExistence(timeout: 600), "the take should transcribe to a finished recording")
        }
        // Also a take a failed earlier run left behind: only a row stamped
        // within the last few minutes is ever touched.
        defer { deleteNewestTake(app) }
        // On a phone the library is the owner's, so the search is for
        // whatever the newest finished recording is called; the title is the
        // row's first text.
        let title = row.staticTexts.firstMatch.label
        XCTAssertFalse(title.isEmpty, "the row should show a title")
        // The index write is asynchronous; a moment for it to land.
        sleep(2)

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        sleep(1)
        // The Search pill above the Dock, or failing that the swipe down on
        // the Home Screen that opens the same search.
        let pill = springboard.buttons["Search"].firstMatch
        if pill.waitForExistence(timeout: 3) {
            pill.tap()
        } else {
            springboard.swipeDown()
        }
        // The field and the results are Spotlight's own process, not
        // SpringBoard's, so querying the Home Screen for them finds nothing.
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        let field = spotlight.searchFields.firstMatch.waitForExistence(timeout: 3)
            ? spotlight.searchFields.firstMatch : spotlight.textFields.firstMatch
        if !field.waitForExistence(timeout: 5) { snap(springboard, "00-no-search-field") }
        XCTAssertTrue(field.exists, "the Home Screen's search should open")
        field.typeText(title)

        // The app's own result, not a web suggestion with the same words: the
        // Top Hit reads "title, 0:08", the suggestion is the title alone.
        let result = spotlight.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS ', '", title)).firstMatch
        if !result.waitForExistence(timeout: 10) { snap(spotlight, "00-no-longhand-result") }
        XCTAssertTrue(result.exists, "Spotlight should list the recording with its duration")
        snap(spotlight, "01-spotlight-result")
        result.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "tapping the result should open Longhand")
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10)
                      || app.staticTexts[title].waitForExistence(timeout: 5),
                      "the result should open that recording's transcript")
        snap(app, "02-opened-from-spotlight")
    }

    /// Six seconds of whatever the room sounds like, saved with the defaults.
    private func recordAShortTake(_ app: XCUIApplication) {
        app.buttons["Record Audio"].firstMatch.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }
        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the record sheet should be recording")
        sleep(6)
        stop.tap()
    }

    /// Only this test's take: the newest row, titled with the time it was
    /// made within the last few minutes.
    private func deleteNewestTake(_ app: XCUIApplication) {
        app.activate()
        let row = app.cells.firstMatch
        guard row.waitForExistence(timeout: 5) else { return }
        let recent = (0...9).contains { minutesAgo in
            let stamp = Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
                .formatted(date: .abbreviated, time: .shortened)
            return row.label.contains(stamp)
        }
        guard recent else { return }
        row.press(forDuration: 1.0)
        let delete = app.buttons["Delete"]
        guard delete.waitForExistence(timeout: 3) else { return }
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete “'")).firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
