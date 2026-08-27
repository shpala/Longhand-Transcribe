import XCTest

/// §11.1 / Phase 5: a job claimed by a continued-processing task must finish
/// while the app is backgrounded. Device-only, since simulators don't support
/// BGTaskScheduler, where the designed behavior is the inline fallback
/// (job pauses with the app; covered by the other suites).
final class BackgroundExecutionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testJobCompletesWhileBackgrounded() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("continued-processing tasks are unavailable in simulators; fallback path covered elsewhere")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "he"]
        app.launch()

        // Wait until the job exists and processing has visibly started.
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "synth job should appear")
        snap(app, "bg-01-processing")

        // Background the app while the pipeline is mid-flight.
        XCUIDevice.shared.press(.home)
        sleep(75)   // ample for ~9 s of Hebrew: ASR + diarization + identify + export

        app.activate()
        let complete = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 15),
                      "job should have COMPLETED while backgrounded. INTERRUPTED or still-processing means continued execution did not run")
        snap(app, "bg-02-completed-in-background")
        #endif
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
