import Foundation
import Testing
@testable import LonghandEngines

/// The model group's header is state-dependent, and both states matter: naming
/// a 626 MB download to someone who already has it describes a cost they have
/// paid, and hiding it from someone who has not is the opposite mistake.
@Suite @MainActor struct LanguageHeaderTests {

    @Test func namesTheDownloadOnlyWhileItIsStillPending() throws {
        let folder = WhisperKitEngine.modelFolder(for: .turbo)
        let existed = WhisperKitEngine.isDownloaded(.turbo)
        let catalog = TranscriptionLanguages.shared

        if existed {
            #expect(catalog.modelHeader == "Whisper speech model")
        } else {
            #expect(catalog.modelHeader.hasPrefix("Whisper speech model · "))
            #expect(catalog.modelHeader.hasSuffix("download"))

            // Materialise loadable stand-ins for the components the presence
            // check demands, so the other branch is exercised without 626 MB.
            for component in WhisperKitEngine.requiredComponents {
                let bundle = folder.appendingPathComponent(component)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                for part in ["coremldata.bin", "model.mil"] {
                    try Data("x".utf8).write(to: bundle.appendingPathComponent(part))
                }
            }
            defer { try? FileManager.default.removeItem(at: folder) }
            #expect(WhisperKitEngine.isDownloaded(.turbo))
            #expect(catalog.modelHeader == "Whisper speech model",
                    "the size should disappear once the model is present")
        }
    }

    /// §4.2.3(ii) is about disclosing the size of the fetch that is actually
    /// about to happen. This hardcoded turbo's 626 MB, so with Maximum accuracy
    /// selected it named 626 MB and then fetched 947 MB.
    @Test func theDisclosedSizeFollowsTheSelectedVariant() {
        let key = WhisperModelVariant.defaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(WhisperModelVariant.turbo.rawValue, forKey: key)
        let fast = TranscriptionLanguages.modelSizeDescription
        UserDefaults.standard.set(WhisperModelVariant.large.rawValue, forKey: key)
        let accurate = TranscriptionLanguages.modelSizeDescription

        #expect(fast != accurate, "the two builds are 626 MB and 947 MB apart")
        #expect(WhisperModelVariant.large.approximateBytes > WhisperModelVariant.turbo.approximateBytes)
    }

    /// The phone offers the same choice the Mac does (§6.1). It was narrowed to
    /// turbo alone once; narrowing it again should be a deliberate act with a
    /// failing test behind it, not a quiet edit.
    @Test func bothBuildsStayOfferable() {
        #expect(WhisperModelVariant.selectable == [.turbo, .large])
        #expect(WhisperModelVariant.large.displayName == "Maximum accuracy")
        // The distilled default, and the full model, are not the same weights.
        #expect(WhisperModelVariant.large.modelName == "openai_whisper-large-v3_947MB")
        #expect(WhisperModelVariant.turbo.modelName.contains("v20240930"))
    }

    @Test func theOtherHeaderNeverClaimsTheWorkIsElsewhere() {
        // The old wording implied the model group was not on-device, which is
        // the one thing this app promises is never true.
        #expect(TranscriptionLanguages.onDeviceHeader == "Apple speech recognition")
        #expect(!TranscriptionLanguages.onDeviceHeader.localizedCaseInsensitiveContains("device"))
        #expect(TranscriptionLanguages.bothAreLocalNote.contains("entirely on this device"))
    }
}
