import XCTest

/// §15.2 ⟨R-16⟩, the half that only the running app can answer: the list is
/// virtualized, it stays virtualized as you scroll through an hour, and a
/// speaker rename does not throw away where you were.
///
/// The cost of each lookup is measured in `TranscriptScrollPerformanceTests`,
/// where a number means something. Nothing here asserts a frame rate: a
/// simulator's is not the phone's, and a flaky performance gate is worse than
/// none. What it asserts instead is structural, and a regression in it is what
/// would make an hour-long transcript stutter in the first place.
final class TranscriptScrollUITests: XCTestCase {

    /// `TranscriptFixture` at 60 minutes: ~10,000 words in ~500 turns.
    private let expectedTurns = 500

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openLongTranscript() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-transcript", "60"]
        app.launch()

        let row = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded hour should be listed")
        row.tap()
        return app
    }

    @MainActor
    private func builtRows(_ app: XCUIApplication) -> [String] {
        app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-"))
            .allElementsBoundByIndex
            .map { $0.identifier }
    }

    @MainActor
    func testAnHourLongTranscriptBuildsOnlyTheRowsInView() {
        let app = openLongTranscript()

        let opened = Date()
        let firstRow = app.staticTexts["turn-0"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15),
                      "an hour-long transcript should open")
        // Not a benchmark, a ceiling: anything that reads or lays out all
        // 500 turns up front lands far the other side of this.
        XCTAssertLessThan(Date().timeIntervalSince(opened), 10,
                          "the first turn took too long to appear")

        let built = builtRows(app)
        XCTAssertFalse(built.isEmpty, "no turn rows found; the identifier may have moved")
        XCTAssertLessThan(built.count, expectedTurns / 3,
                          "built \(built.count) of ~\(expectedTurns) rows, which is not a lazy list")
    }

    @MainActor
    func testScrollingThroughTheHourDoesNotAccumulateRows() {
        let app = openLongTranscript()
        XCTAssertTrue(app.staticTexts["turn-0"].waitForExistence(timeout: 15))

        let atTop = Set(builtRows(app))
        var highWaterMark = atTop.count
        let list = app.scrollViews.firstMatch

        for _ in 0..<20 {
            list.swipeUp(velocity: .fast)
            highWaterMark = max(highWaterMark, builtRows(app).count)
        }

        let deep = Set(builtRows(app))
        XCTAssertFalse(deep.isEmpty, "the list stopped producing rows while scrolling")
        XCTAssertTrue(deep.isDisjoint(with: atTop), "twenty swipes should leave the opening turns")
        // The failure this is really about: rows that are built and never
        // released. That count climbs with distance scrolled instead of
        // holding near a screenful.
        XCTAssertLessThan(highWaterMark, expectedTurns / 3,
                          "row count reached \(highWaterMark) while scrolling; rows are accumulating")
    }

    /// §15.2 asks for scroll anchoring that survives a speaker rename. A rename
    /// rewrites the whole transcript through the overlay, so the list is rebuilt
    /// under a reader who may be nowhere near the playhead.
    @MainActor
    func testRenamingASpeakerLeavesTheReaderWhereTheyWere() {
        let app = openLongTranscript()
        XCTAssertTrue(app.staticTexts["turn-0"].waitForExistence(timeout: 15))

        let list = app.scrollViews.firstMatch
        for _ in 0..<8 { list.swipeUp(velocity: .fast) }

        let before = builtRows(app)
        guard let anchor = before.first else { return XCTFail("nothing on screen to anchor on") }
        XCTAssertNotEqual(anchor, "turn-0", "the test needs to be scrolled away from the top")

        // Not firstMatch: rows just above the viewport are still built, and
        // their chips are found before any chip a finger could reach.
        guard let chip = app.buttons.matching(identifier: "Speaker 1")
            .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            return XCTFail("no reachable speaker chip after scrolling")
        }
        chip.tap()
        let rename = app.descendants(matching: .any)["rename-speaker"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()

        let field = app.textFields["Speaker name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Read the name back rather than assuming where the caret landed.
        field.typeText("X")
        let renamed = (field.value as? String) ?? ""
        XCTAssertNotEqual(renamed, "Speaker 1", "the name should have changed")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.buttons[renamed].firstMatch.waitForExistence(timeout: 10),
                      "the rename should have applied")
        XCTAssertTrue(builtRows(app).contains(anchor),
                      "the list jumped away from \(anchor) when the speaker was renamed")
    }
}
