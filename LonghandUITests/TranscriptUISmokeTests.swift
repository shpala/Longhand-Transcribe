import XCTest

/// Simulator-friendly smoke of the transcript-screen UX: speaker chips,
/// playback bar, seek-on-tap. Requires a seeded COMPLETE job in the app
/// container (the harness copies one in before running); deliberately does
/// NOT pass --uitest-reset.
final class TranscriptUISmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTranscriptChipsAndPlayback() throws {
        let app = XCUIApplication()
        // Not a reset: the seeded job has to survive. This only marks the run
        // as a UI test so `UITestSupport.isUITestRun` suppresses onboarding,
        // which would otherwise cover the library on a fresh simulator.
        app.launchArguments = ["--uitest-seeded"]
        app.launch()

        // The library groups jobs by day, so cells.firstMatch can be a
        // section header, so target the seeded row by its status identifier.
        let row = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded job should be listed")
        row.tap()

        // Speaker chip is a visible, tappable affordance now.
        let chip = app.buttons["Speaker 1"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "speaker chip should exist")
        snap(app, "smoke-transcript")

        // Playback bar with a Play control.
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "playback bar should exist")
        play.tap()
        sleep(2)
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.exists, "player should be playing after tap")
        snap(app, "smoke-playing")

        // Chip tap opens the speaker menu: two corrections with very
        // different reach, each labelled with the reach it has.
        chip.tap()
        let renameItem = app.descendants(matching: .any)["rename-speaker"].firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5),
                      "chip tap should open the speaker menu")
        snap(app, "smoke-speaker-menu")
        renameItem.tap()
        XCTAssertTrue(app.textFields["Speaker name"].waitForExistence(timeout: 5),
                      "the rename item should open the rename sheet")
        snap(app, "smoke-rename")
        app.buttons["Cancel"].tap()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
