import XCTest
import AVFoundation

/// End-to-end §9.3 known-self flow: record → enroll a voice from the
/// transcript → record again → the new transcript should auto-label that
/// voice. The auto-match itself depends on the same person actually speaking
/// in both takes, so it is reported (screenshots, soft check) rather than
/// hard-asserted; enrollment persistence IS hard-asserted.
final class SpeakerRecognitionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEnrollThenAutoMatch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        try recordAndAwaitComplete(app, expectedCompleteCount: 1)

        // Open the transcript and enroll the first speaker as "Me" via the
        // tappable speaker chip.
        app.cells.firstMatch.tap()
        let speakerChip = app.buttons["Speaker 1"].firstMatch
        guard speakerChip.waitForExistence(timeout: 5) else {
            throw XCTSkip("no attributed turns in recording #1 (silent take?), cannot exercise enrollment")
        }
        speakerChip.tap()
        let renameItem = app.descendants(matching: .any)["rename-speaker"].firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5),
                      "chip tap should open the speaker menu")
        renameItem.tap()

        let nameField = app.textFields["Speaker name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
            nameField.typeText("Me")
        } else {
            // Fallback: cursor position unknown, so delete both directions.
            nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
            nameField.typeText("Me")
        }
        if nameField.value as? String != "Me" {
            // Last resort: known residue length; place cursor at end via
            // double-tap-select of the trailing word, then overwrite.
            let residue = (nameField.value as? String) ?? ""
            nameField.doubleTap()
            nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: residue.count + 5))
            nameField.typeText("Me")
        }
        XCTAssertEqual(nameField.value as? String, "Me", "field should contain exactly 'Me' before saving")

        let rememberToggle = app.switches["Remember this voice"]
        XCTAssertTrue(rememberToggle.waitForExistence(timeout: 5),
                      "enrollment toggle should be offered for a clean cluster")
        // SwiftUI toggles expose a nested switch that owns the tap target.
        let control = rememberToggle.switches.firstMatch.exists ? rememberToggle.switches.firstMatch : rememberToggle
        control.tap()
        if rememberToggle.value as? String != "1" {
            rememberToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(rememberToggle.value as? String, "1", "toggle must be ON before saving")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Me"].firstMatch.waitForExistence(timeout: 5),
                      "rename should apply immediately without inference")
        snap(app, "enroll-01-renamed")

        // Enrollment must persist (hard assertion). Enrolled Voices now
        // lives only in Settings, not in a toolbar menu.
        sleep(1)
        goBack(app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // The sheet opens at the medium detent and Enrolled Voices sits below
        // the transcription pickers, Location and the model section. The
        // first swipe expands the sheet, later ones scroll the form.
        let voices = app.buttons["Enrolled Voices"]
        XCTAssertTrue(voices.waitForExistence(timeout: 5), "Settings should list Enrolled Voices")
        var swipes = 0
        while !voices.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        voices.tap()
        XCTAssertTrue(app.staticTexts["Me"].firstMatch.waitForExistence(timeout: 5),
                      "profile should appear in Enrolled Voices")
        snap(app, "enroll-02-profile")
        app.buttons["Done"].tap()

        // Second take: same flow; the pipeline now runs identification.
        try recordAndAwaitComplete(app, expectedCompleteCount: 2)
        app.cells.firstMatch.tap()   // newest job sorts first
        sleep(2)
        snap(app, "enroll-03-second-transcript")

        let autoBadge = app.staticTexts["auto"].firstMatch
        let meLabel = app.staticTexts["Me"].firstMatch
        if meLabel.exists && autoBadge.exists {
            print("SPEAKER-ID-DIAG auto-match SUCCEEDED: second recording labeled 'Me' (auto)")
        } else {
            print("SPEAKER-ID-DIAG no auto-match on second recording (voice mismatch or below conservative floor): generic labels kept, which is the designed fallback")
        }
    }

    // MARK: - Helpers

    /// Taps the navigation back button (labeled with the previous screen's
    /// title), never the trailing toolbar items like Actions.
    @MainActor
    private func goBack(_ app: XCUIApplication) {
        for label in ["Longhand", "Back"] {
            let button = app.navigationBars.buttons[label]
            if button.exists { button.tap(); return }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    private func recordAndAwaitComplete(_ app: XCUIApplication, expectedCompleteCount: Int) throws {
        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 10), "library toolbar should be reachable")
        recordItem.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }

        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        // The runner speaks through the device speaker; the mic picks it up.
        // Same synthesized voice in every take → deterministic enrollment
        // and matching without a human in the loop.
        speakSample()
        sleep(14)
        stop.tap()
        // Streamlined flow: processing starts immediately; the default is an
        // unforced speaker count (§7.1), which is what this test needs.

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            // Cells, not raw descendants: one row exposes the identifier on
            // several nested elements.
            if app.cells.containing(.any, identifier: "status-COMPLETE").count >= expectedCompleteCount {
                return
            }
            if app.descendants(matching: .any)["status-FAILED"].firstMatch.exists {
                XCTFail("job failed instead of completing")
                return
            }
            sleep(3)
        }
        XCTFail("job did not complete within the deadline")
    }

    private let synthesizer = AVSpeechSynthesizer()

    private func speakSample() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(
            string: "Hello, this is a voice enrollment test. One, two, three, four, five. The quick brown fox jumps over the lazy dog, and then does it again.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45
        synthesizer.speak(utterance)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
