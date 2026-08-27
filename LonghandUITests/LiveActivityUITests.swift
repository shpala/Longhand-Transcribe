import XCTest

/// A take in progress shows as a Live Activity, and its buttons reach the
/// recorder: Mark and Pause pressed on the activity, outside the app, show up
/// in the record sheet when the app comes back.
final class LiveActivityUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveActivityButtonsDriveTheRecorder() throws {
        let app = XCUIApplication()
        // Never on a phone: the reset deletes the library and every enrolled
        // voice, and the owner's phone holds real recordings.
        #if targetEnvironment(simulator)
        app.launchArguments = ["--uitest-reset"]
        #endif
        app.launch()

        let recordItem = app.buttons["Record Audio"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 5))
        recordItem.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                break
            }
        }
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 10))
        sleep(2)

        XCUIDevice.shared.press(.home)
        sleep(2)
        snap(springboard, "01-home-dynamic-island")

        // Notification Center lists Live Activities above the notifications.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.0))
        let down = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6))
        top.press(forDuration: 0.1, thenDragTo: down)
        sleep(2)
        snap(springboard, "02-live-activity")

        // The first interactive Live Activity from an app comes with the
        // system's one-time question, and its buttons do nothing until it is
        // answered. People see the same prompt.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            sleep(1)
        }

        let mark = springboard.buttons["Mark"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "the Live Activity should offer Mark")
        mark.tap()
        sleep(1)
        let pause = springboard.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "the Live Activity should offer Pause")
        pause.tap()
        sleep(2)
        snap(springboard, "03-live-activity-paused")
        XCTAssertTrue(springboard.buttons["Resume"].waitForExistence(timeout: 10),
                      "the activity should switch to Resume once the take is paused")

        app.activate()
        XCTAssertTrue(app.staticTexts["Paused · 1 marked"].waitForExistence(timeout: 10),
                      "the sheet should show the pause and the mark made from the Lock Screen")
        snap(app, "04-app-paused")

        #if !targetEnvironment(simulator)
        // On a phone, Stop would save a test take into a real library and start
        // processing it. Discard instead; the simulator covers Stop.
        app.buttons["Cancel"].tap()
        let discard = app.buttons["Discard Recording"]
        if discard.waitForExistence(timeout: 5) { discard.tap() }
        return
        #endif

        // Stop from outside the app saves the take, the same as Stop & Save.
        XCUIDevice.shared.press(.home)
        sleep(1)
        top.press(forDuration: 0.1, thenDragTo: down)
        let stop = springboard.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the Live Activity should offer Stop")
        stop.tap()
        sleep(2)
        XCTAssertFalse(springboard.buttons["Stop"].exists,
                       "a saved take should take its Live Activity with it")

        app.activate()
        XCTAssertFalse(app.buttons["Stop & Save"].waitForExistence(timeout: 3),
                       "the record sheet should be gone")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10),
                      "the stopped take should be in the library")
        snap(app, "05-app-saved")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
