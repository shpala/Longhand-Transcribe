import XCTest

/// Playback outside the app: a recording playing in Longhand shows in the
/// system's media controls, and pausing it there pauses the app.
///
/// Device only. The simulator makes Longhand the now-playing app but marks its
/// audio "NOT Now Playing eligible" and never shows the controls; the same
/// build on an iPhone 16 Pro Max showed them and took the Pause (2 Oct 2026).
/// On a phone it plays the newest finished recording, muted, and changes
/// nothing.
final class NowPlayingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSystemMediaControlsDrivePlayback() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("the simulator never shows Now Playing controls; run this on a device")
        #else
        let app = XCUIApplication()
        // A phone has no fixture, so this opens the newest real recording,
        // muted, and changes nothing in it.
        app.launchArguments = ["--uitest-mute-playback"]
        app.launch()
        // A finished recording's row; the day headers are cells too.
        let row = app.buttons.matching(identifier: "status-COMPLETE").firstMatch
        guard row.waitForExistence(timeout: 15) else { throw XCTSkip("no finished recording to play") }
        row.tap()

        let toggle = app.buttons["playback-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        // A short recording ends quickly, so everything up to the system
        // controls has to happen while it is still playing.
        XCTAssertEqual(toggle.label, "Pause", "playback should be running")

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.0))
        let down = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6))
        top.press(forDuration: 0.1, thenDragTo: down)
        snap(springboard, "01-now-playing")

        let pause = springboard.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "the media controls should offer Pause")
        pause.tap()
        sleep(2)
        snap(springboard, "02-paused-from-system")

        app.activate()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Play", "pausing from the system controls should pause the app")
        #endif
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
