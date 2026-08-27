import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// The §4.2.3(ii) consent gate asks before a model download and skips the
/// question once the model is on disk, so a probe that answers "absent" for a
/// complete install turns every job into a download prompt, and one that
/// answers "present" for a half-finished install turns a resumable download
/// into a diarization failure that repeats forever. Both directions matter.
@Suite struct SpeakerKitModelPresenceTests {

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speakerkit-presence-\(UUID())")
    }

    /// Mirrors the real release layout: component → version → quantization →
    /// `Name.mlmodelc`, with the two files Core ML needs to load one.
    private func write(_ components: [String], under root: URL,
                       parts: [String] = ["coremldata.bin", "model.mil", "weights/weight.bin"]) throws {
        for component in components {
            let bundle = root.appendingPathComponent(component)
                .appendingPathComponent("pyannote-v4")
                .appendingPathComponent("W32A32")
                .appendingPathComponent("Projector.mlmodelc")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            for part in parts {
                let file = bundle.appendingPathComponent(part)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("x".utf8).write(to: file)
            }
        }
    }

    @Test func aCompleteInstallNeedsNoDownload() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(CommunityOneDiarizer.requiredComponents, under: root)
        #expect(CommunityOneDiarizer.modelsPresent(in: root))
    }

    @Test func nothingOnDiskReadsAsAbsent() {
        #expect(!CommunityOneDiarizer.modelsPresent(in: temporaryRoot()))
    }

    /// An interrupted fetch leaves the root, and often one component,
    /// behind. Folder-exists would call that a complete install.
    @Test func aPartialDownloadReadsAsAbsent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["speaker_segmenter"], under: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("speaker_embedder"),
                                                withIntermediateDirectories: true)
        #expect(!CommunityOneDiarizer.modelsPresent(in: root))
    }

    /// The failure a real phone hit: the tree is there, the `.mlmodelc`
    /// directory is there, and the bytes Core ML needs are not, so it reports
    /// "Compile the model with Xcode", which reads like a build mistake. It
    /// has to count as absent, or the download is skipped and the failure is
    /// permanent.
    @Test func aTruncatedModelBundleReadsAsAbsent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(CommunityOneDiarizer.requiredComponents, under: root, parts: ["metadata.json"])
        #expect(!CommunityOneDiarizer.modelsPresent(in: root))
    }

    /// One good component and one truncated one is the likeliest shape of an
    /// interrupted fetch, and the shape a whole-tree check would miss.
    @Test func oneBadComponentCondemnsTheWholeInstall() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["speaker_segmenter", "speaker_embedder"], under: root)
        try write(["speaker_clusterer"], under: root, parts: ["metadata.json"])
        #expect(!CommunityOneDiarizer.modelsPresent(in: root))
    }

    @Test func compiledBundlesAreFoundAtWhateverDepthTheVendorNestsThem() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["speaker_clusterer"], under: root)
        let found = ModelAsset.compiledBundles(
            under: root.appendingPathComponent("speaker_clusterer"))
        #expect(found.count == 1)
        #expect(found.first?.lastPathComponent == "Projector.mlmodelc")
        #expect(ModelAsset.isLoadable(found[0]))
    }

    /// The exact shape the owner's phone was in: `coremldata.bin` and
    /// `model.mil` present, `metadata.json` present, the `weights` directory
    /// present, and empty. 1.5 MB of a 2 MB shortfall hid in there, and a
    /// check that stopped at the two top-level files called it healthy.
    @Test func aBundleWhoseWeightsNeverArrivedReadsAsAbsent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(CommunityOneDiarizer.requiredComponents, under: root,
                  parts: ["coremldata.bin", "model.mil"])
        for component in CommunityOneDiarizer.requiredComponents {
            let weights = root.appendingPathComponent(component)
                .appendingPathComponent("pyannote-v4/W32A32/Projector.mlmodelc/weights")
            try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        }
        #expect(!CommunityOneDiarizer.modelsPresent(in: root))
    }

    /// A model that legitimately carries no weights at all must not be
    /// condemned for it: absent is fine, present-and-empty is not.
    @Test func aBundleWithNoWeightsDirectoryIsStillLoadable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(CommunityOneDiarizer.requiredComponents, under: root,
                  parts: ["coremldata.bin", "model.mil"])
        #expect(CommunityOneDiarizer.modelsPresent(in: root))
    }

    /// Argmax caches under Documents, not Application Support. Probing the
    /// wrong root is silent: it just always says "absent".
    @Test func theProbeLooksWhereArgmaxActuallyWrites() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #expect(CommunityOneDiarizer.modelFolder().path.hasPrefix(documents.path))
        #expect(CommunityOneDiarizer.modelFolder().path
            .hasSuffix("huggingface/models/argmaxinc/speakerkit-coreml"))
    }
}

/// The timings exist so "why is Hebrew slow" has an answer that is measured
/// rather than argued. They are only worth having if they are correct across a
/// resume, and if drain-at-every-checkpoint does not double-count.
@Suite struct StageClockTests {

    @Test func timeIsAttributedToTheStageThatWasRunning() async throws {
        let clock = JobPipeline.StageClock()
        clock.enter(.transcribing)
        try await Task.sleep(for: .milliseconds(40))
        clock.enter(.merging)
        let measured = clock.drain()
        let transcribing = try #require(measured[.transcribing])
        #expect(transcribing >= 0.03)
        // Merging had barely started; it must not inherit transcription's time.
        #expect((measured[.merging] ?? 0) < 0.02)
    }

    /// `persist()` drains at every stage boundary, so a stage that spans two
    /// drains must add up rather than restart, and an already-counted stage
    /// must not be counted again.
    ///
    /// Measured against the wall clock rather than the requested sleep: on a
    /// loaded CI runner a 30 ms sleep took 88 ms, and an assertion built on
    /// the sleep length failed a correct clock.
    @Test func drainingTwiceDoesNotDoubleCount() async throws {
        let clock = JobPipeline.StageClock()
        clock.enter(.transcribing)
        try await Task.sleep(for: .milliseconds(30))
        let first = clock.drain()[.transcribing] ?? 0
        let betweenDrains = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(30))
        let second = clock.drain()[.transcribing] ?? 0
        let elapsed = betweenDrains.duration(to: .now)
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(first >= 0.02)
        #expect(second >= 0.02)
        // The second drain reports only the new time, not the total, so it
        // cannot exceed the time that passed between the two drains. Counting
        // twice would add all of `first` on top.
        #expect(second <= wall + 0.005)
    }

    @Test func reenteringTheSameStageDoesNotRestartIt() async throws {
        let clock = JobPipeline.StageClock()
        clock.enter(.transcribing)
        try await Task.sleep(for: .milliseconds(30))
        clock.enter(.transcribing)   // progress updates arrive continuously
        #expect((clock.drain()[.transcribing] ?? 0) >= 0.02)
    }

    /// A resumed job really did spend both runs' time, so the record adds.
    @Test func aResumedRunAddsToWhatThePreviousOneRecorded() {
        var record = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                               state: .prepared, lastCheckpointState: .prepared)
        record.recordStage(.transcribing, seconds: 12)
        record.recordStage(.transcribing, seconds: 8)
        record.recordStage(.loadingModel, seconds: 3)
        #expect(record.stageSeconds?["transcribing"] == 20)
        #expect(record.totalProcessingSeconds == 23)
    }

    @Test func aRecordWithNoTimingsReportsNone() {
        let record = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                               state: .imported, lastCheckpointState: .imported)
        #expect(record.totalProcessingSeconds == nil)
    }
}

/// §17 already required a failure to name its stage. Where the time went is
/// the part that was recorded, displayed, and never once read: a three-minute
/// stage is a different bug from a stage that simply failed, and only the
/// container knew.
@Suite struct FailureMessageTests {

    /// The real one, from the job record the phone wrote.
    @Test func theDominantStageIsNamedAlongsideTheFailure() {
        let message = JobPipeline.failureMessage(
            stage: .transcribing,
            detail: "Required model asset is not installed: WhisperKit openai_whisper-large-v3",
            thisRun: [.preparing: 0.739, .loadingModel: 179.474])
        #expect(message.hasPrefix("Transcription failed: Required model asset is not installed"))
        #expect(message.contains("2:59"), "the measurement that was the diagnosis")
        #expect(message.contains("loading model"), "and where it went")
    }

    /// A run whose time was spread across its stages has nothing to single out.
    @Test func anEvenlySpreadFailureGainsNothing() {
        let message = JobPipeline.failureMessage(
            stage: .transcribing, detail: "Decode failed.",
            thisRun: [.preparing: 20, .loadingModel: 22, .transcribing: 25])
        #expect(message == "Transcription failed: Decode failed.")
    }

    /// A failure that took no time at all is just a failure.
    @Test func aFastFailureGainsNothing() {
        let message = JobPipeline.failureMessage(
            stage: .preparing, detail: "Original recording is missing.",
            thisRun: [.preparing: 0.2])
        #expect(message == "Audio preparation failed: Original recording is missing.")
    }

    /// The measurement is this run's, not the record's running total: a resumed
    /// job would otherwise report time nobody spent in one sitting.
    @Test func theMeasurementIsThisRunNotTheAccumulatedTotal() {
        // The phone's own record after two runs read 325.919 s cumulative,
        // of which the failing run was 179.474 s.
        let message = JobPipeline.failureMessage(
            stage: .transcribing, detail: "Boom.",
            thisRun: [.loadingModel: 179.474])
        #expect(message.contains("2:59"))
        #expect(!message.contains("5:25"), "the accumulated total belongs to no single run")
    }
}
