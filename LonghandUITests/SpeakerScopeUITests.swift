import XCTest

/// The two speaker corrections have very different reach (one passage
/// versus every passage a cluster owns) and until now only the wide one was
/// discoverable, behind the chip. This drives the narrow one end to end.
///
/// The seeded fixture is a single-speaker transcript, which is precisely the
/// case the old UI could not fix at all: reassignment was offered only when
/// the diarizer had already found a second cluster to move the passage to.
/// Runs against the seeded job (no `--uitest-reset`) and puts it back the way
/// it found it, so suite order stays irrelevant.
final class SpeakerScopeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testReattributeOnePassageToSomeoneTheDiarizerNeverFound() throws {
        let app = XCUIApplication()
        // Not a reset: the seeded job has to survive. This only marks the run
        // as a UI test so `UITestSupport.isUITestRun` suppresses onboarding,
        // which would otherwise cover the library on a fresh simulator.
        app.launchArguments = ["--uitest-seeded"]
        app.launch()

        let row = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded job should be listed")
        row.tap()

        let chip = app.buttons["Speaker 1"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "speaker chip should exist")
        chip.tap()

        // The rename item states its blast radius: the fixture has one turn.
        let renameItem = app.descendants(matching: .any)["rename-speaker"].firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5), "speaker menu should open")
        XCTAssertTrue(renameItem.label.contains("1 passage"),
                      "rename should say how many passages it touches, got “\(renameItem.label)”")
        snap(app, "scope-menu")

        let reassignItem = app.descendants(matching: .any)["reassign-passage"].firstMatch
        XCTAssertTrue(reassignItem.exists,
                      "a single-cluster transcript should still offer the per-passage fix")
        reassignItem.tap()

        let someoneElse = app.buttons["Someone else…"].firstMatch
        XCTAssertTrue(someoneElse.waitForExistence(timeout: 5),
                      "with no other cluster to pick, naming a new speaker is the only correction")
        someoneElse.tap()

        let nameField = app.textFields["Speaker name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Guest")
        snap(app, "scope-new-speaker")
        app.buttons["Save"].tap()

        let newChip = app.buttons["Guest"].firstMatch
        XCTAssertTrue(newChip.waitForExistence(timeout: 10),
                      "the passage should now be attributed to the invented speaker")
        XCTAssertTrue(app.descendants(matching: .any)["reassigned"].firstMatch.exists,
                      "a reattributed passage is marked, never silently relabelled")
        snap(app, "scope-reassigned")

        // Put the fixture back: the same menu carries the undo, and removing
        // the last passage forgets the invented speaker entirely.
        newChip.tap()
        let undo = app.descendants(matching: .any)["undo-reassign"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "a reassigned passage offers an undo")
        undo.tap()
        XCTAssertTrue(app.buttons["Speaker 1"].firstMatch.waitForExistence(timeout: 10),
                      "undo should restore the voice detection's own answer")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
