import XCTest

/// Splitting a passage at a word, undoing it from the actions menu, and
/// moving several passages to one speaker at once. Needs `seed-sim`: the
/// fixture has real words to cut at.
final class PassageEditingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSplitUndoAndBatchReassign() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-mute-playback"]
        app.launch()

        let row = app.cells.containing(.any, identifier: "status-COMPLETE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the seeded recording should be listed")
        row.tap()

        // One `turn-N` timestamp per row; pressing it reaches the row's menu.
        let turnStamps = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'turn-'"))
        let firstTurn = turnStamps.firstMatch
        XCTAssertTrue(firstTurn.waitForExistence(timeout: 10), "turns should be on screen")
        let turnsBefore = turnStamps.count
        XCTAssertGreaterThan(turnsBefore, 0)

        // Split the first passage somewhere inside it.
        firstTurn.press(forDuration: 1.0)
        let splitItem = app.buttons["split-passage"].firstMatch
        XCTAssertTrue(splitItem.waitForExistence(timeout: 5), "the first turn should offer Split Passage")
        splitItem.tap()
        let words = app.staticTexts["split-words"].firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 5), "the split sheet should show the words")
        // Tap well inside the text, past the first word.
        words.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        let confirm = app.buttons["split-confirm"].firstMatch
        XCTAssertTrue(app.descendants(matching: .any)["split-preview"].firstMatch.waitForExistence(timeout: 5),
                      "a word tap should preview the two halves")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        snap(app, "01-split")

        let joinable = turnStamps
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, joinable.count <= turnsBefore { usleep(200_000) }
        XCTAssertEqual(joinable.count, turnsBefore + 1, "a split adds one passage")

        // Undo it from the actions menu.
        app.buttons["Actions"].firstMatch.tap()
        let undo = app.buttons["undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the actions menu should offer Undo")
        undo.tap()
        let undoDeadline = Date().addingTimeInterval(5)
        while Date() < undoDeadline, joinable.count != turnsBefore { usleep(200_000) }
        XCTAssertEqual(joinable.count, turnsBefore, "undo restores the passage count")
        snap(app, "02-undone")

        // Select two passages and give them to a new speaker.
        app.buttons["Actions"].firstMatch.tap()
        let select = app.buttons["select-passages"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertTrue(turnStamps.firstMatch.waitForExistence(timeout: 5))
        turnStamps.element(boundBy: 0).tap()
        if turnStamps.count > 1 { turnStamps.element(boundBy: 1).tap() }
        let expected = turnStamps.count > 1 ? "2 selected" : "1 selected"
        XCTAssertTrue(app.staticTexts["selection-count"].firstMatch.label.hasPrefix(expected),
                      "got \(app.staticTexts["selection-count"].firstMatch.label)")
        app.buttons["reassign-selected"].firstMatch.tap()
        let someoneElse = app.buttons["Someone else…"].firstMatch
        XCTAssertTrue(someoneElse.waitForExistence(timeout: 5))
        someoneElse.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Noa")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Noa"].firstMatch.waitForExistence(timeout: 10),
                      "the reassigned passages should show the new speaker's chip")
        XCTAssertFalse(app.buttons["selection-done"].exists, "select mode ends after a reassignment")
        snap(app, "03-reassigned")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Edit mode in the library: pick recordings, see what they cost, delete.
final class LibrarySelectionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectAndDeleteARecording() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-mute-playback"]
        app.launch()

        let row = app.cells.containing(.any, identifier: "status-COMPLETE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.buttons["Add"].firstMatch.tap()
        let select = app.buttons["select-recordings"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertTrue(app.staticTexts["library-selection-count"].firstMatch.waitForExistence(timeout: 5))
        row.tap()
        let count = app.staticTexts["library-selection-count"].firstMatch
        XCTAssertTrue(count.label.hasPrefix("1 selected"), "got \(count.label)")
        snap(app, "01-selected")
        app.buttons["delete-selected"].firstMatch.tap()
        let confirm = app.buttons["confirm-delete-selected"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = Date().addingTimeInterval(10)
        while Date() < gone, row.exists { usleep(200_000) }
        XCTAssertFalse(row.exists, "the recording should be deleted")
        XCTAssertFalse(app.buttons["library-selection-done"].exists, "edit mode ends after deleting")
        snap(app, "02-deleted")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
