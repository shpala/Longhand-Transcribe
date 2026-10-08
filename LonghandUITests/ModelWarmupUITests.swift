import XCTest

/// Not a test of anything: a fresh simulator container has no speech or
/// speaker models, so every job parks at the §4.2.3(ii) download question and
/// the suites that need a finished transcript cannot get one. This answers
/// "Download" at each gate and waits for the Hebrew synth import to complete,
/// which pulls the Whisper and Community-1 models into the container once.
/// Run it after anything that gave the app a new container; the models
/// survive `--uitest-reset`, which wipes only the library.
final class ModelWarmupUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDownloadModelsForThisSimulator() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-synth-import", "he"]
        app.launch()

        let complete = app.descendants(matching: .any)["status-COMPLETE"].firstMatch
        let failed = app.descendants(matching: .any)["status-FAILED"].firstMatch
        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch
        let deadline = Date().addingTimeInterval(1500)
        while Date() < deadline {
            if download.exists { download.tap() }
            if complete.exists { return }
            if failed.exists { XCTFail("the warmup job failed; see the row") ; return }
            sleep(5)
        }
        XCTFail("the models did not finish downloading in 25 minutes")
    }
}
