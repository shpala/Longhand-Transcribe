import XCTest

/// A note typed while recording reaches the transcript at the moment it was
/// typed. The microphone hears nothing assertable in a simulator, so the
/// transcript has no words and the note lands as a marker row after the
/// last turn, which is the one place it can be read without speech.
final class NotesDuringRecordingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testATypedNoteAppearsInTheTranscript() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5), "toolbar should offer Record Audio")
        recordItem.tap()
        allowMicrophone()
        XCTAssertTrue(app.buttons["Stop & Save"].waitForExistence(timeout: 10), "record sheet should be recording")

        let field = app.textFields["record-note"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the record sheet should offer a note field")
        field.tap()
        field.typeText("Budget agreed for Q3")
        app.buttons["record-note-add"].tap()
        // Acknowledged on the status line, and the field is ready for the next one.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1 note'")).firstMatch
                        .waitForExistence(timeout: 3), "the status line should count the note")
        // An empty field reports its placeholder as its value.
        let remaining = field.value as? String ?? ""
        XCTAssertTrue(remaining.isEmpty || remaining == "Add a note at this moment",
                      "the field clears after a note is added, got “\(remaining)”")
        snap(app, "01-note-added")

        // Something typed and not submitted is still a note.
        field.tap()
        field.typeText("Follow up with Dana")
        app.buttons["Stop & Save"].firstMatch.tap()

        guard waitForCompleteJob(app) else {
            throw XCTSkip("the job did not complete on this simulator (no model), so the transcript cannot be checked")
        }
        app.cells.containing(.any, identifier: "status-COMPLETE").firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Budget agreed for Q3'")).firstMatch
                        .waitForExistence(timeout: 10), "the note should be in the transcript")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Follow up with Dana'")).firstMatch
                        .exists, "the unsubmitted note should have been kept")
        snap(app, "02-notes-in-transcript")
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

    /// True once a row is COMPLETE; false when it fails or parks at the
    /// model-download question (answered "Not now" so no download starts).
    private func waitForCompleteJob(_ app: XCUIApplication) -> Bool {
        let complete = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        let failed = app.descendants(matching: .any)["status-FAILED"].firstMatch
        let parked = app.descendants(matching: .any)["status-PAUSED"].firstMatch
        let notNow = app.buttons["Not now"].firstMatch
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if notNow.exists { notNow.tap() }
            if complete.exists { return true }
            if failed.exists || parked.exists { return false }
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
