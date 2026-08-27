import XCTest

/// Tier 1 of the UX package: recordings you can name, and jobs you can stop.
final class TitleAndPauseUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRenameARecordingFromTheContextMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "he"]
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-he'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "synth import should produce a job row")

        row.press(forDuration: 1.5)
        let rename = app.buttons["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10), "context menu should offer Rename")
        rename.tap()

        // The rename sheet's field is pre-filled with the current title and
        // already focused; appending is enough to prove the write round-trips.
        let field = app.textFields["rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the rename sheet should offer a text field")
        field.typeText(" standup")
        app.buttons["Save"].tap()

        let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-he standup'")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "the library should show the new name")
    }

    /// A paused job must stay paused: today's auto-resume would otherwise
    /// restart it the moment the library reappeared.
    @MainActor
    func testPausingAJobStopsItAndItStaysStopped() throws {
        let app = XCUIApplication()
        // "auto" renders Hebrew + 24 s of silence + Russian, so the job is
        // long enough to catch mid-pipeline.
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "auto"]
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-auto'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "synth import should produce a job row")

        row.press(forDuration: 1.5)
        let pause = app.buttons["Pause"]
        guard pause.waitForExistence(timeout: 10) else {
            // The job already finished (a fast machine, a cached model), so
            // nothing to pause, and nothing this test can assert.
            throw XCTSkip("job completed before it could be paused")
        }
        pause.tap()

        // Stopping is not instantaneous (the pipeline finishes its current
        // stage first) and the row says so rather than pretending. "Paused"
        // is a tappable button now, not a static text, so match any element.
        let stopping = app.staticTexts["Stopping…"]
        let paused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Paused'")).firstMatch
        let complete = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch

        // Three outcomes are legitimate, and which one happens depends on where
        // the pipeline was when the tap landed: it acknowledges the stop, it
        // comes to rest paused, or it had already finished: cancellation is
        // only observed at stage boundaries. Poll for whichever arrives.
        var sawStopping = false
        var settled = false
        for _ in 0..<60 {
            if stopping.exists { sawStopping = true }
            if paused.exists || complete.exists { settled = true; break }
            usleep(1_000_000)
        }
        XCTAssertTrue(settled, "the row never settled: still \(sawStopping ? "Stopping…" : "in progress")")

        if complete.exists {
            // A finished job must not be left claiming to be stopping, and must
            // not carry a paused flag that would confuse a later resume.
            XCTAssertFalse(stopping.exists, "a finished job is stuck on Stopping…")
            throw XCTSkip("job finished before the pause could take effect")
        }

        // Leave and come back: the resume sweep runs on appear and must leave a
        // user-paused job alone.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(paused.waitForExistence(timeout: 15), "a paused job must not auto-resume")
    }
}

/// Search, at the level a person uses it: type a Hebrew word without vowel
/// points and find the recording that says it.
final class SearchUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchingTheLibraryFindsAHebrewTranscript() throws {
        let app = XCUIApplication()
        // The seeded fixture is a real completed Hebrew job.
        app.launch()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the library should offer a search field")
        guard app.cells.firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("seeded fixture missing; run `driver.sh seed-sim` first")
        }
        field.tap()
        field.typeText("בדיקת")

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'synth-he'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Hebrew fixture should match")

        // A word that appears nowhere should empty the list.
        field.buttons.firstMatch.tap()   // clear
        field.typeText("kangaroo")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No Results'"))
                        .firstMatch.waitForExistence(timeout: 10)
                      || !row.exists,
                      "a query that matches nothing should show no rows")
    }

    @MainActor
    func testFindingInsideATranscriptCountsMatches() throws {
        let app = XCUIApplication()
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-he'")).firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("seeded fixture missing; run `driver.sh seed-sim` first")
        }
        row.tap()

        let find = app.buttons["find-in-transcript"]
        XCTAssertTrue(find.waitForExistence(timeout: 10), "the transcript should offer Find")
        find.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "tapping Find should reveal the field")
        field.tap()
        field.typeText("בדיקת")

        let count = app.staticTexts["find-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the find bar should report a match count")
        XCTAssertFalse(count.label.contains("No matches"), "the fixture contains this word")
    }
}

/// Tier 3: correcting the machine, and getting the machine's words back.
final class TranscriptEditingUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testEditingATurnPersistsAndCanBeReverted() throws {
        let app = XCUIApplication()
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-he'")).firstMatch
        guard row.waitForExistence(timeout: 15) else {
            // A sibling suite launched with --uitest-reset wipes the library,
            // so a whole-bundle run can reach here with no fixture. Skipping
            // says that; failing would blame the feature.
            throw XCTSkip("seeded fixture missing; run `driver.sh seed-sim` first")
        }
        row.tap()

        // The transcript body is the only long static text on the screen.
        let turn = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'בדיקת'")).firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout: 10), "the fixture's turn should render")
        turn.press(forDuration: 1.5)

        let edit = app.buttons["Edit Text…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "a turn should offer Edit Text")
        edit.tap()

        let field = app.textViews["edit-turn-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the editor should open on the turn's text")
        field.tap()
        field.typeText(" EDITED")
        app.buttons["Save"].tap()

        let edited = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'EDITED'")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10), "the correction should show in the transcript")
        XCTAssertTrue(app.staticTexts["edited"].exists, "an edited turn should say so")

        // Reverting restores the machine's words, possible only because the
        // transcript is derived and the original was never overwritten.
        edited.press(forDuration: 1.5)
        let revert = app.buttons["Revert to Original"]
        XCTAssertTrue(revert.waitForExistence(timeout: 10), "an edited turn should offer a revert")
        revert.tap()

        let original = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'בדיקת'")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertFalse(original.label.contains("EDITED"), "the original text should be back")
    }
}

/// Per-word tap-to-seek. The claim is specific: tapping a word plays from
/// *that word*, not from the start of the turn, which is what tapping
/// anywhere in the turn already did.
final class WordSeekUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private static func seconds(_ label: String) -> Int {
        let parts = label.split(separator: ":")
        let minutes = Int(parts.first ?? "0") ?? 0
        return minutes * 60 + (Int(parts.last ?? "0") ?? 0)
    }

    @MainActor
    func testTappingALateWordSeeksPastTheStartOfTheTurn() throws {
        let app = XCUIApplication()
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-he'")).firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("seeded fixture missing; run `driver.sh seed-sim` first")
        }
        row.tap()

        // Words render only for the turn being played, so start playback,
        // then stop it again, so the clock is frozen and any movement after
        // the tap is the seek, not the passage of time.
        let play = app.buttons["playback-toggle"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        usleep(400_000)
        play.tap()

        let elapsed = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9][0-9]:[0-9][0-9]'")).firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5), "the playback bar should show a time")
        let baseline = Self.seconds(elapsed.label)
        XCTAssertLessThan(baseline, 3, "the paused playhead should still be near the start")

        let turn = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'בדיקת'")).firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout: 10))

        // The fixture is Hebrew, so the line reads right-to-left: a point near
        // the left edge is late in the sentence.
        turn.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()

        var jumped = baseline
        for _ in 0..<10 {
            jumped = Self.seconds(elapsed.label)
            if jumped >= baseline + 2 { break }
            usleep(200_000)
        }
        XCTAssertGreaterThanOrEqual(jumped, baseline + 2,
                                    "tapping a late word should seek to that word, not to the turn's start")
    }
}
