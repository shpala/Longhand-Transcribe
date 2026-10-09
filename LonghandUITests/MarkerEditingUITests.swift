import XCTest

/// Markers and notes can be managed after the fact from the transcript: the
/// sheet lists them, adds one at the playhead, relabels and deletes. Needs
/// `seed-sim` first: the fixture is a COMPLETE job with real turns.
final class MarkerEditingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddRelabelAndDeleteANoteFromTheSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-mute-playback"]
        app.launch()

        let row = app.cells.containing(.any, identifier: "status-COMPLETE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the seeded recording should be listed")
        row.tap()

        app.buttons["Actions"].firstMatch.tap()
        let markersItem = app.buttons["markers-sheet"].firstMatch
        XCTAssertTrue(markersItem.waitForExistence(timeout: 5), "the actions menu should offer Markers & Notes")
        markersItem.tap()

        // Add at the playhead (0:00 on a fresh open).
        XCTAssertTrue(app.buttons["markers-add"].waitForExistence(timeout: 5))
        app.buttons["markers-add"].tap()
        let addField = app.textFields.firstMatch
        XCTAssertTrue(addField.waitForExistence(timeout: 5), "the add alert should have a text field")
        addField.typeText("Opening remarks")
        app.buttons["Add"].firstMatch.tap()
        let noteRow = app.descendants(matching: .any)["markers-row"].firstMatch
        XCTAssertTrue(noteRow.waitForExistence(timeout: 5), "the new note should be listed")
        XCTAssertTrue(noteRow.label.contains("Opening remarks"))
        snap(app, "01-note-added")

        // Relabel through the context menu.
        noteRow.press(forDuration: 1.0)
        let editItem = app.buttons["markers-edit"].firstMatch
        XCTAssertTrue(editItem.waitForExistence(timeout: 5))
        editItem.tap()
        let editField = app.textFields.firstMatch
        XCTAssertTrue(editField.waitForExistence(timeout: 5))
        editField.tap()
        editField.typeText(" revised")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["markers-row"].firstMatch
                        .label.contains("Opening remarks revised"))

        // Delete through the context menu. The fixture may carry markers of
        // its own, so the assertion is about this note, not an empty sheet.
        let revised = app.descendants(matching: .any).matching(identifier: "markers-row")
            .containing(NSPredicate(format: "label CONTAINS 'Opening remarks revised'")).firstMatch
        XCTAssertTrue(revised.waitForExistence(timeout: 5))
        revised.press(forDuration: 1.0)
        let deleteItem = app.buttons["markers-delete"].firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        snap(app, "02-delete-menu")
        deleteItem.tap()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, revised.exists { usleep(200_000) }
        snap(app, "03-after-delete")
        XCTAssertFalse(revised.exists, "the deleted note should leave the list")
        app.buttons["Done"].firstMatch.tap()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The record sheet and a transcript at the largest accessibility text size,
/// where a row of three labelled buttons no longer fits. Screenshots are the
/// assertion a reader makes; the test asserts only that every control is
/// still there and hittable.
final class LargeTypeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordSheetControlsSurviveTheLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-mute-playback",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5))
        recordItem.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
            break
        }
        let stop = app.buttons["Stop & Save"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Pause"].firstMatch.isHittable, "Pause should still be on screen")
        XCTAssertTrue(app.buttons["record-mark"].firstMatch.isHittable, "Mark should still be on screen")
        XCTAssertTrue(stop.isHittable, "Stop & Save should still be on screen")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "record-sheet-accessibility-xxxl"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].firstMatch.tap()
        let discard = app.buttons["Discard Recording"].firstMatch
        if discard.waitForExistence(timeout: 3) { discard.tap() }
    }
}
