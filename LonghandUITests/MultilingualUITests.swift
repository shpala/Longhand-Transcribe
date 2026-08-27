import XCTest

/// §4.2 routing check for non-Apple-engine languages, on the product's
/// primary ingest path (import): the app synthesizes known Hebrew and Russian
/// speech to files (`--uitest-synth-import`), imports them with the language
/// declared, and both must transcribe via WhisperKit into the right script.
/// This is deliberately NOT mic-based: a speaker→mic acoustic loop is too
/// lossy to assert ASR output deterministically; the mic path is covered by
/// the recording-flow tests.
final class MultilingualUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHebrewAndRussianImportTranscription() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "he,ru"]
        app.launch()

        // Both jobs run sequentially; first WhisperKit use may still need the
        // one-time model download.
        let deadline = Date().addingTimeInterval(600)
        var completed = false
        while Date() < deadline {
            // Count CELLS containing the identifier, since a single row exposes it
            // on several nested elements, so raw descendant counts overcount.
            if app.cells.containing(.any, identifier: "status-COMPLETE").count >= 2 {
                completed = true
                break
            }
            if app.descendants(matching: .any)["status-FAILED"].firstMatch.exists {
                snap(app, "ml-failed")
                XCTFail("a synth-import job failed; see ml-failed attachment")
                return
            }
            sleep(5)
        }
        snap(app, "ml-library")
        XCTAssertTrue(completed, "both language jobs should complete")

        try assertTranscript(app, jobTitle: "synth-he",
                             scriptRegex: ".*[\\u05D0-\\u05EA].*",
                             snapName: "ml-hebrew")
        try assertTranscript(app, jobTitle: "synth-ru",
                             scriptRegex: ".*[\\u0410-\\u044F].*",
                             snapName: "ml-russian")
    }

    @MainActor
    func testMixedLanguageAutoDetect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "auto"]
        app.launch()

        // ~45 s of audio (Hebrew, silence, Russian) in one job; Whisper
        // re-detects the language per 30 s window.
        let deadline = Date().addingTimeInterval(600)
        var completed = false
        while Date() < deadline {
            if app.descendants(matching: .any)["status-COMPLETE"].firstMatch.exists { completed = true; break }
            if app.descendants(matching: .any)["status-FAILED"].firstMatch.exists {
                snap(app, "mixed-failed")
                XCTFail("mixed-language job failed; see mixed-failed attachment")
                return
            }
            sleep(5)
        }
        XCTAssertTrue(completed, "mixed job should complete")

        app.staticTexts["synth-auto"].firstMatch.tap()
        let hebrew = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", ".*[\\u05D0-\\u05EA].*")).firstMatch
        let cyrillic = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", ".*[\\u0410-\\u044F].*")).firstMatch
        XCTAssertTrue(hebrew.waitForExistence(timeout: 10), "mixed transcript should contain Hebrew")
        XCTAssertTrue(cyrillic.waitForExistence(timeout: 10), "mixed transcript should contain Russian")
        snap(app, "mixed-transcript")
    }

    @MainActor
    private func assertTranscript(_ app: XCUIApplication, jobTitle: String,
                                  scriptRegex: String, snapName: String) throws {
        let row = app.staticTexts[jobTitle].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(jobTitle) row should exist")
        row.tap()
        let scriptText = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", scriptRegex)).firstMatch
        XCTAssertTrue(scriptText.waitForExistence(timeout: 10),
                      "\(jobTitle) transcript should contain the expected script")
        snap(app, snapName)
        for label in ["Longhand", "Back"] {
            let button = app.navigationBars.buttons[label]
            if button.exists { button.tap(); return }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
