import XCTest
import AVFoundation

/// The live preview on the record sheet needs Apple's recognizer, which a
/// simulator does not have (no locales), so this runs on a device only. It
/// checks that a take in the default language starts listening and says so,
/// then throws the take away. What the recognizer hears is not asserted:
/// mic-captured audio never is.
final class LivePreviewUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPreviewStartsListeningOnADevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Apple's recognizer reports no locales on a simulator; the preview cannot start")
        #endif
        // The app holds the preview back under the same conditions it holds
        // the pipeline, and the runner sees the same device state.
        let info = ProcessInfo.processInfo
        try XCTSkipIf(info.isLowPowerModeEnabled, "Low Power Mode is on; the preview is held by design")
        try XCTSkipIf(info.thermalState == .serious || info.thermalState == .critical,
                      "the device is hot; the preview is held by design")
        let app = XCUIApplication()
        // Never --uitest-reset on a device: the library is the owner's. The
        // owner's default language may be one with no preview, so this
        // launch asks for English without touching the setting.
        app.launchArguments = ["--uitest-live-language", "en"]
        app.launch()

        let record = app.buttons["Record Audio"]
        XCTAssertTrue(record.waitForExistence(timeout: 5), "toolbar should offer Record Audio")
        record.tap()

        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "record sheet should be recording")
        let early = XCTAttachment(screenshot: app.screenshot())
        early.name = "sheet-at-start"
        early.lifetime = .keepAlways
        add(early)

        // Generous: a first run installs the recognizer's assets for the
        // language before it can listen.
        let caption = app.staticTexts["record-live-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 15), "the sheet should show the live preview caption")
        let listening = expectation(for: NSPredicate(format: "label BEGINSWITH 'Live preview ·'"),
                                    evaluatedWith: caption)
        let outcome = XCTWaiter().wait(for: [listening], timeout: 90)
        XCTAssertEqual(outcome, .completed, "the preview should start listening; caption was: \(caption.label)")

        // Say something through the speaker, from this process, so the
        // microphone has words to hear. Which words come back is not
        // asserted (a speaker-to-mic loop is never assertable), only that
        // the preview filled with something.
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "We said we would come back to the onboarding screen once the copy was settled, so let us start there.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
        let preview = app.descendants(matching: .any)["record-live-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "the preview should fill with words while speech plays")
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-preview"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Cancel"].tap()
        let discard = app.buttons["Discard Recording"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(record.waitForExistence(timeout: 10), "library should be back after discarding")
    }
}
