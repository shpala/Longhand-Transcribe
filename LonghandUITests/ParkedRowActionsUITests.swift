import XCTest

/// The row affordances for a stalled job. A `NavigationLink` row makes the
/// entire cell the link's tap target, so a Resume/Retry button placed on the
/// row, whether inside the link's label or beside it, silently navigates
/// instead of acting. This pins the behaviour: the control is hittable, it
/// resumes, and it does *not* push the transcript.
///
/// Runs against the seeded job, parked by a launch hook (no `--uitest-reset`).
final class ParkedRowActionsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testResumeOnAParkedRowResumesInsteadOfNavigating() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-park-jobs"]
        app.launch()

        let parked = app.descendants(matching: .any)["status-PAUSED"].firstMatch
        XCTAssertTrue(parked.waitForExistence(timeout: 10), "seeded job should be listed as paused")

        let resume = app.buttons["row-resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "a parked row should offer Resume")
        XCTAssertTrue(resume.isHittable, "Resume must own its own tap target")
        resume.tap()

        // The transcript screen is the wrong outcome; that is the bug.
        let findField = app.searchFields["Find in transcript"].firstMatch
        XCTAssertFalse(findField.waitForExistence(timeout: 3),
                       "tapping Resume must not push the transcript")
        // And the row must leave the parked state, which only resume() does.
        let stillParked = NSPredicate(format: "exists == false")
        expectation(for: stillParked, evaluatedWith: parked)
        waitForExpectations(timeout: 15)
    }
}
