import XCTest

/// Covers the UX-improvement pass: Settings surface, delete confirmation,
/// and the record-with-options path. Import-failure alerts and the
/// permission-denied "Open Settings" button are not automatable without new
/// launch hooks (a failing import / a denied mic) and are verified manually.
final class UXImprovementsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Its own test rather than part of the settings one: selecting from the
    /// full list scrolls the sheet, and that test asserts on rows further down.
    @MainActor
    func testFullLanguageListIsSearchable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // Arabic is not inline, which makes it the proof the list reaches the
        // other 88.
        XCTAssertFalse(app.buttons["Arabic"].exists, "Arabic should not be inline")
        app.descendants(matching: .any)["more-languages"].firstMatch.tap()
        let search = app.searchFields["Search languages"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the full list should be searchable")
        search.tap()
        search.typeText("Arab")
        let arabic = app.buttons["Arabic"].firstMatch
        XCTAssertTrue(arabic.waitForExistence(timeout: 5), "search should find Arabic")
        arabic.tap()

        // Chosen from the list it becomes the selection, and joins the inline
        // set, which is what keeps the picker from rendering blank.
        XCTAssertTrue(app.staticTexts["Arabic"].waitForExistence(timeout: 5),
                      "the picker should show the language chosen from the list")
    }

    @MainActor
    func testSettingsSheetShowsDefaultsVoicesAndStorage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                      "gear should open the Settings sheet")
        XCTAssertTrue(app.staticTexts["Language"].exists, "language default picker should be visible")
        // Sections only render once the picker is opened.
        app.descendants(matching: .any)["language-picker"].firstMatch.tap()
        // Headers name the engine, not where the work happens.
        XCTAssertTrue(app.staticTexts["Apple speech recognition"].waitForExistence(timeout: 5),
                      "the built-in engine group should be named")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label BEGINSWITH %@", "Whisper speech model"))
                        .firstMatch.exists,
                      "the model-backed group should be named")
        // Spanish proves the on-device group is read from the framework.
        XCTAssertTrue(app.buttons["Spanish"].exists,
                      "on-device languages should be the full set, not a hardcoded three")
        XCTAssertTrue(app.buttons["Hebrew"].exists, "Hebrew should be offered under the model group")
        // "Mixed" is a mode covering the whole group, so it heads it.
        let mixed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mixed'")).firstMatch
        XCTAssertTrue(mixed.exists, "Mixed should be in the model group")
        XCTAssertLessThan(mixed.frame.minY, app.buttons["Hebrew"].frame.minY,
                          "Mixed should sit above the languages in its group")
        // Close the menu without changing the setting; the rest of this test
        // needs the sheet, not a modal over it.
        app.buttons["Automatic (English)"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Speakers"].exists, "speaker-count default picker should be visible")
        XCTAssertTrue(app.switches["Save location with recordings"].exists,
                      "location toggle should be visible")
        // Everything below here sits under the medium-detent fold; Form rows
        // off-screen don't exist to XCUITest until scrolled into view, and the
        // Language section grew a "More languages…" row.
        //
        // The phone offers the same two builds the Mac does. It briefly offered
        // only the distilled one, and this assertion was the inverse: the
        // choice belongs on the device that records most of the audio.
        let fullModel = app.staticTexts["Maximum accuracy"]
        for _ in 0..<4 where !fullModel.exists {
            app.swipeUp()
        }
        XCTAssertTrue(fullModel.exists, "the full large-v3 build should be offered")
        XCTAssertTrue(app.staticTexts["Fast"].firstMatch.exists,
                      "the distilled default should still be offered")
        XCTAssertTrue(app.staticTexts["whisper-variant-note"].exists
                      || app.descendants(matching: .any)["whisper-variant-note"].exists,
                      "the speed/accuracy tradeoff should be stated beside the choice")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-transcription-model"
        shot.lifetime = .keepAlways
        add(shot)
        let storage = app.staticTexts["Used by recordings"]
        for _ in 0..<4 where !storage.exists {
            app.swipeUp()
        }
        XCTAssertTrue(storage.waitForExistence(timeout: 5),
                      "storage figure should be visible after scrolling")

        // Enrolled Voices opens after Settings dismisses.
        app.buttons["Enrolled Voices"].tap()
        XCTAssertTrue(app.navigationBars["Enrolled Voices"].waitForExistence(timeout: 10),
                      "Enrolled Voices should open from Settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Longhand"].waitForExistence(timeout: 5),
                      "closing Enrolled Voices should return to the library")
    }

    @MainActor
    func testDeleteRequiresConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "he"]
        app.launch()

        // The row appears as soon as the job folder exists (IMPORTED), so the
        // pipeline does not need to finish here.
        let cell = app.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 60), "synth import should produce a job row")

        // The NavigationLink row is exposed as a button; long-press it for
        // the context menu (more deterministic than swipe-to-delete on a row
        // whose progress updates re-render it mid-gesture).
        let rowLink = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'synth-he'")).firstMatch
        XCTAssertTrue(rowLink.waitForExistence(timeout: 10))
        rowLink.press(forDuration: 1.5)
        let menuDelete = app.buttons["Delete"]
        if !menuDelete.waitForExistence(timeout: 5) {
            print(app.debugDescription)
        }
        XCTAssertTrue(menuDelete.waitForExistence(timeout: 5), "context menu should offer Delete")
        menuDelete.tap()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "delete should ask for confirmation")

        // Cancel keeps the recording. The dialog's Cancel button is not
        // exposed to XCUITest on iOS 26 (only the destructive button is), so
        // cancel by tapping the dimmed scrim above the sheet.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "cancel should keep the job row")

        // Confirm deletes it.
        rowLink.press(forDuration: 1.5)
        XCTAssertTrue(menuDelete.waitForExistence(timeout: 5))
        menuDelete.tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let destructive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete '")).firstMatch
        XCTAssertTrue(destructive.waitForExistence(timeout: 5), "dialog should offer the destructive action")
        destructive.tap()
        XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 10),
                      "confirmed delete should empty the library")
    }

    @MainActor
    func testRecordWithOptionsShowsImportSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5))
        recordItem.tap()

        // Permission alerts: microphone, then location (one-shot capture at
        // record start). Loop because both can appear back to back.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            var tapped = false
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 3) {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { break }
        }

        let stop = app.buttons["Stop & Save"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "record sheet should be recording")
        sleep(2)

        // Long-press Stop & Save → the options path; tap remains the fast path.
        stop.press(forDuration: 1.0)
        let withOptions = app.buttons["Save with Options…"]
        XCTAssertTrue(withOptions.waitForExistence(timeout: 5),
                      "long-press should offer Save with Options")
        withOptions.tap()

        XCTAssertTrue(app.navigationBars["Import Recording"].waitForExistence(timeout: 5),
                      "options path should show the import options sheet")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30),
                      "import should produce a job row")
    }
}
