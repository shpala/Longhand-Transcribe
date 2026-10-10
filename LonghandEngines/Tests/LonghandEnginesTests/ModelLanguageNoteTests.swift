import Foundation
import Testing
@testable import LonghandEngines

/// The picker's note about what a model language costs. The group header
/// already prices the download; this is the rest of the bill, and it must
/// be empty for Apple's languages, which is where most people live.
@Suite @MainActor struct ModelLanguageNoteTests {

    private let catalog = TranscriptionLanguages.shared

    private func note(_ stored: String, downloaded: Bool = true,
                      summarizable: Bool = false) -> String? {
        catalog.limitations(for: stored, modelDownloaded: downloaded) { _ in summarizable }
    }

    @Test func appleLanguagesCarryNoNote() async {
        await catalog.load()
        #expect(note("en") == nil)
        #expect(note("es") == nil)
        #expect(catalog.usesModel("en") == false)
    }

    @Test func aModelLanguageNamesTheFourCosts() {
        let text = try! #require(note("he", downloaded: false))
        #expect(text.hasPrefix("Hebrew uses the Whisper speech model, a one-time "))
        #expect(text.contains("download"))
        #expect(text.contains("No words while recording, and no summary or title."))
        #expect(text.contains("The model loads before transcription"))
        #expect(catalog.modelLanguage(for: "he")?.code == "he")
    }

    @Test func theDownloadDisappearsOnceTheModelIsPresent() {
        let before = note("ru", downloaded: false)!
        let after = note("ru", downloaded: true)!
        #expect(before.contains("download"))
        #expect(!after.contains("download"))
        #expect(after.hasPrefix("Russian uses the Whisper speech model."))
    }

    /// Dutch is Whisper's to transcribe and Apple's model's to summarize,
    /// so the summary clause must follow the summarizer, not the engine.
    @Test func theSummaryClauseFollowsTheSummarizer() {
        #expect(note("nl", summarizable: true)!.contains("No words while recording."))
        #expect(!note("nl", summarizable: true)!.contains("no summary"))
        #expect(note("nl", summarizable: false)!.contains("no summary or title"))
    }

    @Test func mixedIsAModeNotALanguage() {
        let text = note(TranscriptionLanguages.mixedSentinel, downloaded: false)!
        #expect(text.hasPrefix("Mixed uses the Whisper speech model, a one-time "))
        #expect(text.contains("a summary depends on the languages found"))
        #expect(catalog.usesModel(TranscriptionLanguages.mixedSentinel))
        #expect(catalog.modelLanguage(for: TranscriptionLanguages.mixedSentinel) == nil)
    }

    /// The note follows the device: Automatic on a machine set to one of
    /// Apple's languages says nothing, on one set to Russian it has to.
    @Test func automaticFollowsTheDeviceLanguage() async {
        await catalog.load()
        let auto = note(TranscriptionLanguages.systemSentinel, downloaded: false)
        if catalog.deviceLanguageIsOnDevice {
            #expect(auto == nil)
        } else {
            #expect(auto!.hasPrefix("Automatic means \(catalog.deviceLanguage.name) on this device"))
        }
    }

    @Test func lowResourceLanguagesSayToExpectErrors() {
        #expect(note("am")!.contains("Whisper saw little Amharic in training"))
        #expect(!note("he")!.contains("saw little"))
        // Every code in the set is one WhisperKit actually offers.
        let offered = Set(catalog.needsModel.map(\.code))
        for code in TranscriptionLanguages.lowResource {
            #expect(offered.contains(code), "\(code) is not a Whisper language")
        }
    }

    /// The inline group starts empty and fills by use, so nobody is shown a
    /// language they never asked for, and the one chosen stays reachable.
    @Test func recentsStartEmptyAndFillByUse() {
        let key = TranscriptionLanguages.recentKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(catalog.recentModelLanguages.isEmpty)
        catalog.remember("he")
        catalog.remember("en")   // Apple's; never recorded
        #expect(catalog.recentModelLanguages.map(\.code) == ["he"])
        catalog.remember("ru")
        #expect(catalog.recentModelLanguages.map(\.code) == ["ru", "he"])
    }
}
