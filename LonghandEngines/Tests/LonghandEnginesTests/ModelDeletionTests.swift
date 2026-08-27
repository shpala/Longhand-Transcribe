import Foundation
import Testing
@testable import LonghandEngines

/// Deleting a downloaded model is the one destructive thing this app offers
/// that costs bandwidth rather than data, so the tests are about being exact:
/// the right tree goes, the other one stays, and the number shown to the person
/// deciding is the number they get back.
///
/// Serialized: every case stages the same folder under the same vendor root and
/// touches the same defaults key, so run in parallel they delete each other's
/// fixtures and fail in ways that look like bugs in the code under test.
extension WhisperModelDefaults {

@Suite(.serialized) struct ModelDeletionTests {

    /// Materialises a loadable stand-in so presence checks pass without 626 MB.
    private func stage(_ variant: WhisperModelVariant, bytesPerFile: Int = 4096) throws {
        let folder = WhisperKitEngine.modelFolder(for: variant)
        for component in WhisperKitEngine.requiredComponents {
            let bundle = folder.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            for part in ["coremldata.bin", "model.mil"] {
                try Data(repeating: 0x41, count: bytesPerFile)
                    .write(to: bundle.appendingPathComponent(part))
            }
        }
    }

    private func cleanUp(_ variants: [WhisperModelVariant]) {
        for v in variants {
            try? FileManager.default.removeItem(at: WhisperKitEngine.modelFolder(for: v))
            UserDefaults.standard.removeObject(forKey: WhisperKitEngine.loadedKey(v))
        }
    }

    @Test func deletingRemovesTheTreeAndReportsWhatItFreed() throws {
        // Only meaningful when the real model is absent; a developer machine
        // with turbo downloaded would have this test delete 626 MB of it.
        try #require(!WhisperKitEngine.isDownloaded(.large), "test would delete a real download")
        defer { cleanUp([.large]) }

        try stage(.large)
        #expect(WhisperKitEngine.isDownloaded(.large))
        let expected = WhisperKitEngine.reclaimableBytes(for: .large)
        #expect(expected > 0)

        let freed = WhisperKitEngine.delete(.large)
        #expect(!WhisperKitEngine.isDownloaded(.large), "the tree should be gone")
        #expect(freed >= expected, "the reported figure should not undercount")
        #expect(!FileManager.default.fileExists(
            atPath: WhisperKitEngine.modelFolder(for: .large).path))
    }

    /// The flag is what lets the download sheet say "one-time". A re-downloaded
    /// model is new files that Core ML compiles again, so leaving it set would
    /// understate the wait on the run where it is longest.
    @Test func deletingClearsTheLoadedFlagSoTheNextLoadIsHonest() throws {
        try #require(!WhisperKitEngine.isDownloaded(.large), "test would delete a real download")
        defer { cleanUp([.large]) }

        try stage(.large)
        WhisperKitEngine.markLoaded(.large)
        #expect(WhisperKitEngine.hasLoadedBefore(.large))

        WhisperKitEngine.delete(.large)
        #expect(!WhisperKitEngine.hasLoadedBefore(.large),
                "a re-download compiles again, so the one-time claim must reset")
    }

    /// Deletion is per variant, and the two trees are siblings under one vendor
    /// root, so a delete that reached one directory too far up would take both.
    ///
    /// Turbo is asserted against whatever state it is really in rather than
    /// staged: a machine that has done any transcribing has the real 626 MB
    /// here, and a test is not allowed to delete that to make its own fixture
    /// tidy. Staging it only when it is genuinely absent keeps the case
    /// meaningful on a clean checkout too.
    @Test func deletingOneVariantLeavesTheOtherAlone() throws {
        try #require(!WhisperKitEngine.isDownloaded(.large), "test would delete a real download")
        let turboWasAlreadyThere = WhisperKitEngine.isDownloaded(.turbo)
        defer {
            cleanUp([.large])
            if !turboWasAlreadyThere { cleanUp([.turbo]) }
        }

        if !turboWasAlreadyThere { try stage(.turbo) }
        try stage(.large)
        #expect(WhisperKitEngine.isDownloaded(.turbo))

        WhisperKitEngine.delete(.large)

        #expect(WhisperKitEngine.isDownloaded(.turbo), "the untouched variant should survive")
        #expect(!WhisperKitEngine.isDownloaded(.large))
    }

    /// The button is hidden in this state, but a double tap racing a delete
    /// would land here and must not throw or report phantom bytes.
    @Test func deletingSomethingAbsentIsAQuietNoOp() throws {
        try #require(!WhisperKitEngine.isDownloaded(.large), "test would delete a real download")
        #expect(WhisperKitEngine.reclaimableBytes(for: .large) == 0)
        #expect(WhisperKitEngine.delete(.large) == 0)
    }

    /// An interrupted fetch leaves a partial payload in the vendor's staging
    /// area that no other figure counts. Deleting the model without sweeping it
    /// would leave bytes behind while claiming the space was freed.
    @Test func deletingAlsoSweepsThePartialPayloadBesideIt() throws {
        try #require(!WhisperKitEngine.isDownloaded(.large), "test would delete a real download")
        defer { cleanUp([.large]) }

        try stage(.large)
        let vendorRoot = WhisperKitEngine.modelFolder(for: .large).deletingLastPathComponent()
        let staging = ModelStaging.stagingRoot(in: vendorRoot)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let partial = staging.appendingPathComponent("weight.bin.abc123.incomplete")
        try Data(repeating: 0x42, count: 2048).write(to: partial)
        #expect(ModelStaging.leftoverBytes(in: vendorRoot) == 2048)

        let freed = WhisperKitEngine.delete(.large)
        #expect(!FileManager.default.fileExists(atPath: partial.path),
                "the partial payload should go with the model")
        #expect(freed >= 2048, "the freed figure should include what was staged")
    }
}

}
