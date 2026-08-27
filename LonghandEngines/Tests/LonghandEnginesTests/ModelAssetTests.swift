import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// One rule for both vendored trees. They lay their components out
/// differently, and the difference is the vendor's to change, so the rule is
/// about what Core ML needs rather than about a directory shape.
@Suite struct ModelAssetTests {

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("model-asset-\(UUID())")
    }

    private func write(_ path: String, under root: URL, bytes: Int = 1) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: bytes).write(to: file)
    }

    /// WhisperKit's layout: the component named in the list is the bundle.
    @Test func aComponentThatIsItselfTheBundleResolves() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        for part in ["coremldata.bin", "model.mil"] {
            try write("AudioEncoder.mlmodelc/\(part)", under: root)
        }
        #expect(ModelAsset.isPresent(in: root, components: ["AudioEncoder.mlmodelc"]))
    }

    /// SpeakerKit's layout: the component is a directory, and the bundle is
    /// nested at whatever depth the release uses.
    @Test func aComponentNestingItsBundleResolves() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        for part in ["coremldata.bin", "model.mil"] {
            try write("speaker_clusterer/pyannote-v4/W32A32/Projector.mlmodelc/\(part)", under: root)
        }
        #expect(ModelAsset.isPresent(in: root, components: ["speaker_clusterer"]))
    }

    @Test func aComponentWithNoBundleAtAllIsAbsent() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("speaker_clusterer"),
                                                withIntermediateDirectories: true)
        #expect(!ModelAsset.isPresent(in: root, components: ["speaker_clusterer"]))
        #expect(!ModelAsset.isPresent(in: root, components: ["AudioEncoder.mlmodelc"]))
    }

    /// The strictness the two engines used to disagree about. SpeakerKit's rule
    /// asked only whether the file existed, so a resumed fetch that left a
    /// zero-length `coremldata.bin` behind read as a healthy install. Both
    /// trees are now held to the size check WhisperKit's rule introduced.
    @Test func aZeroLengthPayloadIsNotLoadable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("speaker_clusterer/Projector.mlmodelc/coremldata.bin", under: root, bytes: 0)
        try write("speaker_clusterer/Projector.mlmodelc/model.mil", under: root)
        #expect(!ModelAsset.isPresent(in: root, components: ["speaker_clusterer"]))
    }

    /// One good bundle does not excuse a broken sibling: an interrupted fetch
    /// is likeliest to leave exactly that.
    @Test func oneBrokenBundleCondemnsTheComponent() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        for part in ["coremldata.bin", "model.mil"] {
            try write("clusterer/Good.mlmodelc/\(part)", under: root)
        }
        try write("clusterer/Bad.mlmodelc/metadata.json", under: root)
        #expect(!ModelAsset.isPresent(in: root, components: ["clusterer"]))
    }

    /// Weights are the payload that goes missing most often, and a resumed
    /// fetch leaves the directory rather than removing it.
    @Test func weightsPresentButEmptyOrZeroLengthAreNotLoadable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        for part in ["coremldata.bin", "model.mil"] {
            try write("Enc.mlmodelc/\(part)", under: root)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Enc.mlmodelc/weights"), withIntermediateDirectories: true)
        #expect(!ModelAsset.isPresent(in: root, components: ["Enc.mlmodelc"]))

        try write("Enc.mlmodelc/weights/weight.bin", under: root, bytes: 0)
        #expect(!ModelAsset.isPresent(in: root, components: ["Enc.mlmodelc"]))

        try write("Enc.mlmodelc/weights/weight.bin", under: root, bytes: 16)
        #expect(ModelAsset.isPresent(in: root, components: ["Enc.mlmodelc"]))
    }

    /// A model that legitimately carries no weights must not be condemned for
    /// it: the rule is present-and-empty, not absent.
    @Test func noWeightsDirectoryIsStillLoadable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        for part in ["coremldata.bin", "model.mil"] {
            try write("Enc.mlmodelc/\(part)", under: root)
        }
        #expect(ModelAsset.isPresent(in: root, components: ["Enc.mlmodelc"]))
    }

    @Test func purgeRemovesTheTreeSoThePresenceCheckTellsTheTruth() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        for part in ["coremldata.bin", "model.mil"] {
            try write("Enc.mlmodelc/\(part)", under: root)
        }
        let asset = ModelAsset(name: "test", root: root, components: ["Enc.mlmodelc"])
        #expect(asset.isPresent)
        #expect(asset.bytesOnDisk > 0)
        asset.purge()
        #expect(!asset.isPresent)
        #expect(asset.bytesOnDisk == 0)
    }

    /// Both engines describe themselves through the same type now.
    @Test func bothEnginesDeclareTheirTreeThroughOneType() {
        let whisper = WhisperKitEngine.asset(for: .turbo)
        #expect(whisper.components == WhisperKitEngine.requiredComponents)
        #expect(whisper.root == WhisperKitEngine.modelFolder(for: .turbo))
        #expect(whisper.components.contains("MelSpectrogram.mlmodelc"))

        let speaker = CommunityOneDiarizer.asset()
        #expect(speaker.components == CommunityOneDiarizer.requiredComponents)
        #expect(speaker.root == CommunityOneDiarizer.modelFolder())
    }
}

/// Core ML compiles a model for the device on first load and caches the result,
/// so the first load costs minutes and every later one costs seconds. Measured
/// at 146 s against 62 s of audio on an iPhone 16 Pro Max. A wait that long
/// under a label saying "Loading" reads as a hang.
/// Parent for every suite that mutates the `whisperModelLoaded.<model>`
/// defaults keys. Serializing a suite only orders the cases inside it, so two
/// sibling suites touching the same global key still race: `ModelDeletionTests`
/// setting the flag for `large` made `theFlagIsPerVariant` read it as already
/// loaded, which looks exactly like a bug in the flag. Nesting both here makes
/// the exclusion actually hold.
@Suite(.serialized) enum WhisperModelDefaults {}

extension WhisperModelDefaults {

@Suite(.serialized) struct FirstModelLoadTests {

    private func withCleanFlag(_ variant: WhisperModelVariant, _ body: () -> Void) {
        let key = WhisperKitEngine.loadedKey(variant)
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    @Test func theFirstLoadIsKnownAndThenRemembered() {
        withCleanFlag(.turbo) {
            #expect(!WhisperKitEngine.hasLoadedBefore(.turbo))
            WhisperKitEngine.markLoaded(.turbo)
            #expect(WhisperKitEngine.hasLoadedBefore(.turbo))
        }
    }

    /// Per variant, because each set of weights is compiled separately: having
    /// loaded turbo says nothing about how long large will take.
    @Test func theFlagIsPerVariant() {
        withCleanFlag(.turbo) {
            withCleanFlag(.large) {
                WhisperKitEngine.markLoaded(.turbo)
                #expect(WhisperKitEngine.hasLoadedBefore(.turbo))
                #expect(!WhisperKitEngine.hasLoadedBefore(.large))
            }
        }
    }

    /// The flag rides on the progress report, so the shells can say "one-time"
    /// truthfully rather than either always or never.
    @Test func theProgressReportCarriesIt() {
        let first = PipelineProgress(stage: .loadingModel, fraction: 0, isFirstModelLoad: true)
        #expect(first.isFirstModelLoad)
        // Nothing else claims it by accident.
        #expect(!PipelineProgress(stage: .loadingModel, fraction: 0).isFirstModelLoad)
        #expect(!PipelineProgress(stage: .transcribing, fraction: 0.5).isFirstModelLoad)
    }
}

/// The vendors stage a fetch beside the models they are writing, and leave a
/// partial payload behind when one is abandoned. No storage figure counted that
/// directory and no code path swept it, so an interrupted 626 MB download could
/// sit there permanently and invisibly.
}

@Suite struct ModelStagingTests {

    private func stagedRoot(_ files: [(String, Int)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID())")
        for (path, bytes) in files {
            let file = ModelStaging.stagingRoot(in: root).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(repeating: 0x78, count: bytes).write(to: file)
        }
        return root
    }

    /// The exact shape found on the owner's phone.
    @Test func anAbandonedPayloadIsFoundAndCounted() throws {
        let root = try stagedRoot([
            ("openai_whisper/AudioEncoder.mlmodelc/weights/weight.bin.e4740fa.incomplete", 4096),
            ("openai_whisper/AudioEncoder.mlmodelc/weights/weight.bin.metadata", 124),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelStaging.abandonedPayloads(in: root).count == 1)
        #expect(ModelStaging.leftoverBytes(in: root) == 4096)
    }

    /// The bookkeeping beside the payload is the vendor's, and deleting it
    /// invites the re-fetch this project has already been bitten by once.
    @Test func onlyPayloadsAreSweptNotTheVendorsBookkeeping() throws {
        let root = try stagedRoot([
            ("m/Enc.mlmodelc/weights/weight.bin.abc.incomplete", 2048),
            ("m/Enc.mlmodelc/weights/weight.bin.metadata", 124),
            ("m/Enc.mlmodelc/coremldata.bin.metadata", 125),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelStaging.sweep(in: root) == 2048)
        #expect(ModelStaging.abandonedPayloads(in: root).isEmpty)
        #expect(ModelStaging.leftoverBytes(in: root) == 0)
        let metadata = ModelStaging.stagingRoot(in: root)
            .appendingPathComponent("m/Enc.mlmodelc/weights/weight.bin.metadata")
        #expect(FileManager.default.fileExists(atPath: metadata.path),
                "the vendor's etag bookkeeping must survive a sweep")
    }

    @Test func aHealthyInstallHasNothingStagedAndSweepsToZero() throws {
        let root = try stagedRoot([("m/Enc.mlmodelc/coremldata.bin.metadata", 125)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelStaging.leftoverBytes(in: root) == 0)
        #expect(ModelStaging.sweep(in: root) == 0)
    }

    @Test func aMissingStagingDirectoryIsNotAnError() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-absent-\(UUID())")
        #expect(ModelStaging.leftoverBytes(in: absent) == 0)
        #expect(ModelStaging.sweep(in: absent) == 0)
        #expect(ModelStaging.abandonedPayloads(in: absent).isEmpty)
    }

    /// The flag goes on a folder that may not exist yet, so the first download
    /// is excluded from its first byte rather than from the next launch.
    @Test func theHubIsExcludedFromBackupBeforeAnythingIsWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-\(UUID())/huggingface")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(ModelStaging.excludeFromBackup(root))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func everyVendorRootSitsUnderTheExcludedHub() {
        for root in ModelStaging.vendorRoots {
            #expect(root.path.hasPrefix(ModelStaging.hubRoot.path + "/"))
        }
    }

    /// `vendorRoots` spells the paths out rather than reading them off the
    /// engines, which live inside `#if canImport` guards. This is what stops
    /// the two spellings drifting apart.
    ///
    /// Compared as paths, not URLs: `appendingPathComponent` adds a trailing
    /// slash only when the folder already exists, so on a machine that has
    /// never downloaded a model the same location compared unequal.
    @Test func theRootsAgreeWithWhereTheEnginesActuallyWrite() {
        let roots = ModelStaging.vendorRoots.map(\.path)
        #expect(roots.contains(WhisperKitEngine.modelFolder(for: .turbo).deletingLastPathComponent().path))
        #expect(roots.contains(CommunityOneDiarizer.modelFolder().path))
    }
}
