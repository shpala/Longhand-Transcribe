import XCTest
import AVFoundation

/// A take in a Whisper language loads the speech model while it records, so
/// the job that follows skips the load. Device only: it needs the weights
/// on the phone and a saved default that routes to Whisper (the owner's is
/// Russian). The evidence is the job's own timing card: with the model warm,
/// the "Loading model" row is absent, since a stage under 50 ms is not
/// listed, where a cold load would show tens of seconds.
final class WarmModelUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testATakeWarmsTheModelForItsOwnTranscription() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs the phone: a simulator routes everything to Whisper and has no weights")
        #endif
        let info = ProcessInfo.processInfo
        try XCTSkipIf(info.isLowPowerModeEnabled, "Low Power Mode is on; the prewarm is held by design")
        try XCTSkipIf(info.thermalState == .serious || info.thermalState == .critical,
                      "the device is hot; the prewarm is held by design")

        let app = XCUIApplication()
        // Never --uitest-reset on a device: the library is the owner's. The
        // default language is Russian for this launch, so the take routes to
        // Whisper and the prewarm has something to do; the app puts the
        // owner's own default back on its next launch.
        app.launchArguments = ["--uitest-default-language", "ru"]
        app.launch()

        let record = app.buttons["Record Audio"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "record sheet should be recording")

        // Something to transcribe, so the job ends on the transcript screen
        // rather than the no-speech one. The words are not asserted.
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "The copy is settled. What is not settled is whether the permission prompt comes before or after the first recording. Before, if someone taps record and then gets asked for the microphone, the first take is already half lost.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
        // Long enough for the model to load beside the take: a cold load on
        // the owner's phone has measured between 18 and 103 seconds.
        for _ in 0..<5 {
            sleep(30)
            // A touch now and then keeps the phone from locking, which ends
            // the test's authority over the screen.
            app.navigationBars.firstMatch.tap()
        }
        stop.tap()

        // This take's row: titled with today's date stamp. The first cell of
        // the list is the day header, and older rows are complete already,
        // so neither may satisfy the wait.
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        let newest = app.cells.containing(NSPredicate(format: "label CONTAINS %@", today)).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 20), "the take should be listed under today")
        let complete = newest.descendants(matching: .any)["status-COMPLETE"].firstMatch
        let failed = newest.descendants(matching: .any)["status-FAILED"].firstMatch
        let deadline = Date().addingTimeInterval(600)
        var ticks = 0
        while Date() < deadline, !complete.exists, !failed.exists {
            sleep(3)
            ticks += 1
            if ticks % 10 == 0 { app.navigationBars.firstMatch.tap() }
        }
        snap(app, "library")
        XCTAssertTrue(complete.exists, "the take should transcribe to COMPLETE")
        defer { deleteNewestTake(app) }

        newest.tap()
        sleep(2)
        snap(app, "screen")
        let timings = app.descendants(matching: .any)["processing-timings"].firstMatch
        XCTAssertTrue(timings.waitForExistence(timeout: 10), "the transcript screen lists its processing timings")
        timings.tap()
        sleep(1)
        snap(app, "timings")
        XCTAssertTrue(app.staticTexts["Transcription"].waitForExistence(timeout: 5), "the stage rows are expanded")
        XCTAssertFalse(app.staticTexts["Loading model"].exists,
                       "the model was warm from the take, so no load stage should be listed")
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Removes every take this suite left behind: rows still titled with
    /// today's date stamp. The owner's recordings are named, or older. Run
    /// on its own to clean up after a failed run.
    @MainActor
    func testDeleteStampedTakesFromToday() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device only")
        #endif
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Record Audio"].waitForExistence(timeout: 5))
        for _ in 0..<6 {
            guard deleteNewestTake(app, withinMinutes: 24 * 60) else { break }
            sleep(1)
        }
    }

    private func deleteNewestTake(_ app: XCUIApplication) {
        _ = deleteNewestTake(app, withinMinutes: 14)
    }

    /// Only a take of this suite's: the newest row, titled with a date stamp
    /// from the last `minutes`. A summary cannot have renamed it: the model
    /// does not write Russian. Returns whether a row was deleted.
    @discardableResult
    private func deleteNewestTake(_ app: XCUIApplication, withinMinutes minutes: Int) -> Bool {
        app.activate()
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS %@", today)).firstMatch
        guard row.waitForExistence(timeout: 5) else { return false }
        let stamps = stride(from: 0, through: minutes, by: 1).map { minutesAgo in
            Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
                .formatted(date: .abbreviated, time: .shortened)
        }
        // Read once: a row that was just deleted has no label to read, and
        // asking for it fails the test instead of ending the loop.
        guard row.exists else { return false }
        let label = row.label
        guard stamps.contains(where: { label.contains($0) }) else { return false }
        row.press(forDuration: 1.0)
        let delete = app.buttons["Delete"]
        guard delete.waitForExistence(timeout: 3) else { return false }
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete'")).firstMatch
        guard confirm.waitForExistence(timeout: 3) else { return false }
        confirm.tap()
        return true
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
