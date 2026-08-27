import XCTest
import Speech

/// Diagnostic: reports what SpeechTranscriber offers in this environment.
/// Simulators frequently expose no locales/assets; this test documents the
/// fact rather than asserting on it.
final class SpeechDiagnosticsTests: XCTestCase {

    func testReportSpeechTranscriberAvailability() async throws {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        print("SPEECH-DIAG supportedLocales: \(supported.map { $0.identifier(.bcp47) })")
        print("SPEECH-DIAG installedLocales: \(installed.map { $0.identifier(.bcp47) })")
    }
}
