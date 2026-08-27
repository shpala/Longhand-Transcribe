import Foundation
import Testing
@testable import LonghandEngines

/// The models ship with the app now, so the question a test can answer is
/// whether the shipped copy is a *usable* set: the same three components the
/// presence check demands, laid out where SpeakerKit reads them.
@Suite struct BundledSpeakerModelsTests {

    @Test func theBundleCarriesAllThreeComponents() throws {
        let root = try #require(CommunityOneDiarizer.bundledModelsRoot(),
                                "SpeakerModels missing from the package bundle")
        for component in CommunityOneDiarizer.requiredComponents {
            let compiled = ModelAsset.compiledBundles(
                under: root.appendingPathComponent(component))
            #expect(!compiled.isEmpty, "\(component) has no .mlmodelc")
            // Every bundle has to be one Core ML would accept, which is the
            // check that a truncated download fails.
            for bundle in compiled {
                #expect(ModelAsset.isLoadable(bundle),
                        "\(bundle.lastPathComponent) is not loadable")
            }
        }
    }

    @Test func seedingProducesASetThePresenceCheckAccepts() throws {
        let root = try #require(CommunityOneDiarizer.bundledModelsRoot())
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let destination = scratch.appendingPathComponent("speakerkit-coreml")
        try FileManager.default.copyItem(at: root, to: destination)
        #expect(CommunityOneDiarizer.modelsPresent(in: destination),
                "a fresh copy of the shipped models must read as present")
    }
}

/// §4.2.3(ii) exists to disclose a download before it happens. It must not fire
/// for models the app is already carrying: asking permission to fetch 11 MB out
/// of the app bundle is a prompt with no download behind it, and it stood in
/// front of every first diarization on a fresh install.
@Suite struct SpeakerConsentGateTests {

    @Test func theGateDoesNotAskForWhatTheAppAlreadyShips() {
        // isDownloaded seeds from the bundle, so by the time the gate is asked
        // the models are there and there is nothing to disclose.
        #expect(CommunityOneDiarizer.isDownloaded())
        #expect(CommunityOneDiarizer().pendingDownloadBytes == nil)
    }

    /// The size stays, because the gate still has to name it if the seed ever
    /// fails and a real fetch becomes necessary.
    @Test func theSizeIsStillKnownForTheCaseThatNeedsIt() {
        #expect(CommunityOneDiarizer.approximateBytes == 11 * 1_000_000)
    }
}
