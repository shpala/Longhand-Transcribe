import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// Engines that refuse to run. Every test here seeds `10_asr.json` and
/// `20_diarization.json`, so the pipeline must skip inference entirely. If one
/// of these is ever called, checkpoint gating regressed and the test says so
/// instead of quietly downloading a 626 MB model.
struct RefusingTranscriber: SpeechTranscribing {
    static let engineID = "test/refusing"
    let modelIdentifier = "test/refusing"
    func supports(language: Locale.Language) -> Bool { true }
    var supportsLanguageAutoDetection: Bool { true }
    func transcribe(_ input: AudioAsset, language: Locale.Language?,
                    progress: @escaping ProgressSink) async throws -> ASRResult {
        Issue.record("ASR ran despite a TRANSCRIBED checkpoint")
        throw LonghandError.cancelled
    }
}

struct RefusingDiarizer: SpeakerDiarizer {
    static let engineID = "test/refusing"
    let modelIdentifier = "test/refusing"
    func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult {
        Issue.record("diarization ran despite a DIARIZED checkpoint")
        throw LonghandError.cancelled
    }
}

/// Stands in for diarization being unavailable (§17), which is a degradation
/// the pipeline is meant to survive. Unlike RefusingDiarizer, running it is
/// not a test failure.
struct UnavailableDiarizer: SpeakerDiarizer {
    static let engineID = "test/unavailable"
    let modelIdentifier = "test/unavailable"
    func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult {
        throw LonghandError.modelAssetMissing(asset: "diarizer (test)")
    }
}

func enginesWithUnavailableDiarizer() -> JobPipeline.Engines {
    JobPipeline.Engines(transcribers: [RefusingTranscriber()], diarizer: UnavailableDiarizer())
}

func stubEngines() -> JobPipeline.Engines {
    JobPipeline.Engines(transcribers: [RefusingTranscriber()], diarizer: RefusingDiarizer())
}

/// A job folder that is already DIARIZED: original audio present (never read),
/// ASR and diarization checkpoints written, record staged accordingly.
func seededJob(words: [(String, TimeInterval, TimeInterval, String)] = [
    ("We", 0.0, 0.4, "SPEAKER_00"),
    ("need", 0.4, 0.8, "SPEAKER_00"),
    ("Wednesday", 0.8, 1.6, "SPEAKER_00"),
    ("Fine", 4.0, 4.6, "SPEAKER_01"),
    ("with", 4.6, 5.0, "SPEAKER_01"),
    ("me", 5.0, 5.4, "SPEAKER_01"),
],
                suppressed: [SuppressedSpan] = []) throws -> JobFiles {
    let jobID = UUID()
    let files = JobFiles(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("longhand-engines-tests-\(jobID)"))
    try files.createDirectory()
    try Data("not really audio".utf8).write(to: files.original(fileExtension: "wav"))

    let clusters = Set(words.map(\.3)).sorted()
    let segments = clusters.enumerated().map { index, cluster -> ASRSegment in
        let mine = words.filter { $0.3 == cluster }
        return ASRSegment(id: index, start: mine.first!.1, end: mine.last!.2,
                          text: mine.map(\.0).joined(separator: " "),
                          words: mine.map { ASRWord(text: $0.0, start: $0.1, end: $0.2) })
    }
    try AtomicFile.writeJSON(
        ASRResult(language: "en", engine: "test", modelIdentifier: "test/model", segments: segments,
                  suppressedSpans: suppressed),
        to: files.asr)

    let intervals = clusters.map { cluster -> SpeakerInterval in
        let mine = words.filter { $0.3 == cluster }
        return SpeakerInterval(speaker: cluster, start: mine.first!.1, end: mine.last!.2)
    }.sorted { $0.start < $1.start }
    try AtomicFile.writeJSON(
        DiarizationResult(engine: "test", modelIdentifier: "test/diar", intervals: intervals),
        to: files.diarization)

    try AtomicFile.writeJSON(
        ImportMetadata(importedAt: Date(), sourceHash: "H", sourceFileSize: 1,
                       sourceExtension: "wav", sourceFormat: "riffWave",
                       declaredLanguage: "en", durationSeconds: 6),
        to: files.metadata)
    try AtomicFile.writeJSON(
        JobRecord(id: jobID, title: "seeded", createdAt: Date(), state: .diarized,
                  lastCheckpointState: .diarized, duration: 6, language: "en"),
        to: files.job)
    return files
}

func transcript(_ files: JobFiles) throws -> Transcript {
    try #require(try AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE"))
}

@Suite struct PipelineRerunTests {

    @Test func aSeededJobCompletesWithoutRunningInference() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }

        let record = try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        #expect(record.state == .complete)

        let result = try transcript(files)
        #expect(result.turns.count == 2)
        #expect(result.turns[0].text == "We need Wednesday")
        #expect(result.speakers.count == 2)
    }

    /// The one that matters: the merge stage rebuilds turns and the speakers
    /// table from scratch on every run (§10 COMPLETE→MERGED), so a rename has
    /// to live somewhere that survives it.
    @Test func aRenameSurvivesAReMerge() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        try JobPipeline.relabelSpeaker(files: files, cluster: "SPEAKER_00", newName: "Emilia")
        #expect(try transcript(files).speakers["SPEAKER_00"]?.displayName == "Emilia")

        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        let after = try transcript(files)
        #expect(after.speakers["SPEAKER_00"]?.displayName == "Emilia")
        #expect(after.speakers["SPEAKER_00"]?.confirmedByUser == true)
        #expect(after.turns[0].speaker == "Emilia", "exports read turn.speaker, so it must agree")
        // The other speaker is still generic; nothing invented.
        #expect(after.speakers["SPEAKER_01"]?.displayName == "Speaker 2")
    }

    @Test func aTextEditSurvivesAReMergeAndReachesTheExports() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        let target = try transcript(files).turns[0]
        try JobPipeline.editTurnText(files: files, turn: target, newText: "We need Thursday")
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        let after = try transcript(files)
        #expect(after.turns[0].text == "We need Thursday")
        #expect(after.turns[0].edited == true)
        let markdown = try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)
        #expect(markdown.contains("We need Thursday"))
    }

    /// Undo only works because the transcript is derived: the machine's own
    /// words are still in `30_merged_words.json`, never overwritten.
    @Test func clearingAnEditRestoresTheMachinesWords() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        let target = try transcript(files).turns[0]
        try JobPipeline.editTurnText(files: files, turn: target, newText: "something else entirely")
        #expect(try transcript(files).turns[0].text == "something else entirely")

        try JobPipeline.clearTurnEdit(files: files, turn: target)
        let restored = try transcript(files)
        #expect(restored.turns[0].text == "We need Wednesday")
        #expect(restored.turns[0].edited == nil)
    }

    @Test func aReassignedTurnKeepsTheDiarizersOwnClaim() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        let target = try transcript(files).turns[1]
        try JobPipeline.assignTurn(files: files, turn: target, toCluster: "SPEAKER_00")
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        let after = try transcript(files)
        #expect(after.turns[1].assignedCluster == "SPEAKER_00")
        #expect(after.turns[1].cluster == "SPEAKER_01", "the machine's attribution is untouched")
        #expect(after.turns[1].speaker == after.speakers["SPEAKER_00"]?.displayName)
    }

    @Test func markersSurviveAReMerge() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        try JobPipeline.addMarker(files: files, at: 4.2, label: "agreed here")
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        #expect(try transcript(files).markers?.first?.label == "agreed here")
    }

    @Test func confirmingAnAutoMatchOutlivesAReMerge() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        try JobPipeline.confirmSpeaker(files: files, cluster: "SPEAKER_01")
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        #expect(try transcript(files).speakers["SPEAKER_01"]?.confirmedByUser == true)
    }

    @Test func runningTwiceWithNoUserChangesProducesTheSameTranscript() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        let first = try transcript(files)
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        #expect(try transcript(files) == first)
    }
}

/// §17 states: a degraded or empty result is named, never silent.
@Suite struct EmptyTranscriptTests {

    @Test func aRecordingWithNoSpeechSaysSoRatherThanCompletingBlank() async throws {
        // An ASR result with no words at all: the pipeline still completes,
        // but "Complete" over an empty page is not a report.
        let files = try seededJob(words: [])
        defer { try? FileManager.default.removeItem(at: files.root) }

        let record = try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        #expect(record.state == .complete)
        #expect(record.degradations.contains(kind: .noSpeechDetected))
    }
}

/// Markers are flagged while recording, before a transcript exists, so they
/// arrive through import rather than through an edit.
@Suite struct MarkerImportTests {

    @Test func markersFromARecordingReachTheTranscriptAndSurviveAReMerge() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }

        // What ImportService writes when a take arrives with flags on it.
        var overlay = UserOverlay()
        overlay.addMarker(at: 4.5)
        overlay.addMarker(at: 1.0)
        try AtomicFile.writeJSON(overlay, to: files.overlay)

        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        let first = try transcript(files)
        #expect(first.markers?.map(\.time) == [1.0, 4.5], "markers are ordered by time")

        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        #expect(try transcript(files).markers?.count == 2, "a re-merge keeps them")

        // Markdown carries them; subtitle formats deliberately do not.
        let markdown = try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)
        #expect(markdown.contains("marker"))
        let text = try String(contentsOf: files.transcriptText, encoding: .utf8)
        #expect(!text.contains("marker"))
    }
}

/// What Settings says about a model has to be true. The layout here matches a
/// real on-device download: compiled components at the top of the variant's
/// folder, next to config.json.
@Suite struct ModelPresenceTests {

    private func stageFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-model-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Mirrors a real download: each component is a compiled bundle carrying
    /// the files Core ML needs to open it.
    private func write(_ components: [String], under root: URL,
                       parts: [String] = ["coremldata.bin", "model.mil", "weights/weight.bin"]) throws {
        for component in components {
            let bundle = root.appendingPathComponent(component)
            for part in parts {
                let file = bundle.appendingPathComponent(part)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("x".utf8).write(to: file)
            }
        }
    }

    @Test func aCompleteInstallNeedsNoDownload() throws {
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(WhisperKitEngine.requiredComponents, under: root)
        #expect(WhisperKitEngine.modelsPresent(in: root))
    }

    @Test func anEmptyOrMissingFolderIsNotDownloaded() throws {
        let empty = try stageFolder()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!WhisperKitEngine.modelsPresent(in: empty))
        #expect(!WhisperKitEngine.modelsPresent(in: empty.appendingPathComponent("gone")))
    }

    /// Every component is loaded at inference time, so leaving one out of the
    /// check calls an install complete that WhisperKit then rejects.
    @Test func theMelSpectrogramCounts() throws {
        #expect(WhisperKitEngine.requiredComponents.contains("MelSpectrogram.mlmodelc"))
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"], under: root)
        #expect(!WhisperKitEngine.modelsPresent(in: root))
    }

    /// A download in progress: the encoder has landed, the decoder has not.
    @Test func requiresEveryComponent() throws {
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"], under: root)
        #expect(!WhisperKitEngine.modelsPresent(in: root),
                "a half-finished download must not report itself complete")
    }

    /// The shape that cost a real phone three minutes: every directory in
    /// place, the bytes Core ML needs missing. A name check calls this healthy,
    /// skips the download, and the failure repeats on every run.
    @Test func directoriesWithoutPayloadReadAsAbsent() throws {
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for component in WhisperKitEngine.requiredComponents {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(component),
                                                    withIntermediateDirectories: true)
        }
        #expect(!WhisperKitEngine.modelsPresent(in: root))
    }

    /// A resumed fetch leaves the file in place at zero length rather than
    /// removing it, so existence alone is not the question.
    @Test func aZeroLengthPayloadReadsAsAbsent() throws {
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(WhisperKitEngine.requiredComponents, under: root)
        let truncated = root.appendingPathComponent("AudioEncoder.mlmodelc/model.mil")
        try Data().write(to: truncated)
        #expect(!WhisperKitEngine.modelsPresent(in: root))
    }

    /// The other half of the same failure: the bundle opens, the weights that
    /// make it useful never finished arriving.
    @Test func emptyOrZeroLengthWeightsReadAsAbsent() throws {
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(WhisperKitEngine.requiredComponents, under: root,
                  parts: ["coremldata.bin", "model.mil"])
        for component in WhisperKitEngine.requiredComponents {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(component).appendingPathComponent("weights"),
                withIntermediateDirectories: true)
        }
        #expect(!WhisperKitEngine.modelsPresent(in: root), "an empty weights directory is a partial fetch")

        try Data().write(to: root.appendingPathComponent(
            "AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(!WhisperKitEngine.modelsPresent(in: root), "a zero-length weight file is the same fetch")
    }

    /// Absent weights are legitimate for a model that carries none, so the
    /// rule is present-and-empty, not merely absent.
    @Test func aBundleWithNoWeightsDirectoryIsStillLoadable() throws {
        let root = try stageFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(WhisperKitEngine.requiredComponents, under: root,
                  parts: ["coremldata.bin", "model.mil"])
        #expect(WhisperKitEngine.modelsPresent(in: root))
    }

    /// Argmax caches under Documents, not Application Support. Probing the
    /// wrong root is silent: it just always says "absent".
    @Test func theProbeLooksWhereArgmaxActuallyWrites() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = WhisperKitEngine.modelFolder(for: .turbo)
        #expect(folder.path.hasPrefix(documents.path))
        #expect(folder.path.hasSuffix("huggingface/models/argmaxinc/whisperkit-coreml/\(WhisperModelVariant.turbo.modelName)"))
    }
}

/// Resuming after a kill. The record on disk can lag the checkpoints (a
/// process dies between writing a stage's file and writing job.json), and the
/// pipeline has to catch up rather than skip work or wedge on an illegal
/// transition.
@Suite struct ResumeAfterKillTests {

    /// The one that failed permanently: killed after identification, the record
    /// says IDENTIFIED, and re-entering identification tried an illegal
    /// IDENTIFIED → IDENTIFIED edge, marking the job FAILED forever.
    @Test func aJobKilledAtIdentifiedCompletesOnResume() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }

        // Diarization with centroids + an enrolled profile means the identify
        // stage really runs on the resume.
        let diarization = try #require(try AtomicFile.readJSON(DiarizationResult.self,
                                                               from: files.diarization, stage: "DIARIZED"))
        try AtomicFile.writeJSON(DiarizationResult(engine: diarization.engine,
                                                   modelIdentifier: diarization.modelIdentifier,
                                                   intervals: diarization.intervals,
                                                   centroids: ["SPEAKER_00": [1, 0, 0],
                                                               "SPEAKER_01": [0, 1, 0]]),
                                 to: files.diarization)
        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .identified
        record.lastCheckpointState = .identified
        try AtomicFile.writeJSON(record, to: files.job)

        let profile = SpeakerProfile(displayName: "Emilia", modelIdentifier: "test/diar",
                                     embeddings: [[1, 0, 0]], createdAt: Date(), updatedAt: Date())
        let finished = try await JobPipeline.run(files: files, engines: stubEngines(),
                                                 profiles: [profile], progress: { _ in })
        #expect(finished.state == .complete)
        #expect(finished.errorDescription == nil)
    }

    /// Killed between writing 10_asr.json and writing job.json: the record
    /// still says PREPARED. Diarization used to be skipped because it was
    /// gated on the record's state, yielding a speakerless transcript.
    @Test func aRecordLaggingItsASRCheckpointStillGetsSpeakers() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        // The prepared audio a resume would find on disk.
        try Data("pcm".utf8).write(to: files.normalizedPCM)
        try FileManager.default.removeItem(at: files.diarization)

        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .prepared
        record.lastCheckpointState = .prepared
        try AtomicFile.writeJSON(record, to: files.job)

        // The stub diarizer refuses, so this asserts the *attempt* is made:
        // the degradation note only exists if diarization was tried.
        let finished = try await JobPipeline.run(files: files, engines: enginesWithUnavailableDiarizer(),
                                                 progress: { _ in })
        #expect(finished.state == .complete)
        #expect(finished.degradations.contains(kind: .diarizationUnavailable),
                "diarization must be attempted from the checkpoint, not skipped on a stale state")
        // §17 is not satisfied by naming the loss alone: the cause exists only
        // inside that catch, and without it the note cannot tell a failed
        // model fetch from a device that simply can't run the model.
        #expect(finished.degradations.contains { $0.message.contains("diarizer (test)") },
                "the degradation must carry why diarization failed, not just that it did")
    }

    @Test func aRecordLaggingItsMergeCheckpointStillCompletes() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .imported
        record.lastCheckpointState = .imported
        try AtomicFile.writeJSON(record, to: files.job)

        let finished = try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        #expect(finished.state == .complete)
    }
}

/// §14.1: the location setting governs whether a location is *stored*, by any
/// route: a live fix or one read out of a file's own metadata.
/// Serialized: these mutate the real preference key, and swift-testing runs
/// cases in parallel by default, and the "off unless asked for" case was seeing a
/// sibling's `true`.
@Suite(.serialized) struct LocationSettingTests {

    private func withSetting(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let key = LocationCapture.settingsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    @Test func theSettingIsOffUnlessTheUserTurnsItOn() {
        let key = LocationCapture.settingsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(LocationCapture.isEnabled == false, "location must be opt-in")
        if let previous { UserDefaults.standard.set(previous, forKey: key) }
    }

    @Test func theSettingIsHonouredInBothDirections() throws {
        try withSetting(true) { #expect(LocationCapture.isEnabled) }
        try withSetting(false) { #expect(!LocationCapture.isEnabled) }
    }
}

/// An import that fails part-way must not leave a folder full of audio that no
/// screen can show and nothing collects.
@Suite struct FailedImportCleanupTests {

    @Test func aFailedImportLeavesNothingBehind() async throws {
        let root = ImportService.recordingsRoot
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])

        // A source that cannot be copied: the path does not exist.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-missing-\(UUID()).m4a")
        await #expect(throws: (any Error).self) {
            try await ImportService.importRecording(from: missing, securityScoped: false,
                                                    declaredLanguage: nil, expectedSpeakerCount: nil)
        }

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        #expect(after.subtracting(before).isEmpty, "a failed import left a job folder behind")
    }
}

/// The raw-PCM path is the §5.5 escape hatch for headerless recorder files.
/// It streams now, so the round-trip needs pinning.
@Suite struct RawPCMDecoderTests {

    @Test func wrapsHeaderlessPCMInAPlayableWAV() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-rawpcm-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // One second of 16 kHz mono s16le, plus a stray odd byte.
        let samples = 16_000
        var pcm = Data(count: samples * 2)
        for i in stride(from: 0, to: samples * 2, by: 2) { pcm[i] = UInt8(i % 251) }
        pcm.append(0x7F)
        let source = directory.appendingPathComponent("take.hda")
        try pcm.write(to: source)

        let destination = directory.appendingPathComponent("out.wav")
        let asset = try RawPCMDecoder.decode(url: source, destinationURL: destination)

        #expect(abs(asset.duration - 1.0) < 0.01)
        let written = try Data(contentsOf: destination)
        #expect(written.count == 44 + samples * 2, "header plus an even number of sample bytes")
        #expect(written.prefix(4) == Data("RIFF".utf8))
        #expect(written[8..<12] == Data("WAVE".utf8))
        // The audio itself must survive the streaming copy byte for byte.
        #expect(written[44...] == pcm.prefix(samples * 2))
    }

    @Test func rejectsSomethingTooShortToBeAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-rawpcm-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tiny.hda")
        try Data(count: 100).write(to: source)
        #expect(throws: LonghandError.self) {
            try RawPCMDecoder.decode(url: source, destinationURL: directory.appendingPathComponent("o.wav"))
        }
    }
}

/// §13.2 explicit re-run. Nothing covered this before, and the fix pass changed
/// its semantics (exports survive until replaced), so both halves are pinned.
@Suite struct RetranscribeTests {

    @Test func rejectingAnActiveJobChangesNothingOnDisk() throws {
        let files = try seededJob()          // seeded at .diarized, an active state
        defer { try? FileManager.default.removeItem(at: files.root) }

        let metadataBefore = try #require(try AtomicFile.readJSON(ImportMetadata.self,
                                                                  from: files.metadata, stage: "IMPORTED"))
        #expect(throws: LonghandError.self) {
            try JobPipeline.retranscribe(files: files, newLanguage: "he")
        }

        // Validation runs first: the language must not have been written, and
        // the checkpoints must still be there.
        let metadataAfter = try #require(try AtomicFile.readJSON(ImportMetadata.self,
                                                                 from: files.metadata, stage: "IMPORTED"))
        #expect(metadataAfter.declaredLanguage == metadataBefore.declaredLanguage)
        #expect(FileManager.default.fileExists(atPath: files.asr.path))
        #expect(FileManager.default.fileExists(atPath: files.diarization.path))
    }

    @Test func fromCompleteItKeepsTheOldTranscriptUntilTheRerunReplacesIt() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        let before = try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)

        try JobPipeline.retranscribe(files: files, newLanguage: "he")

        // Inference checkpoints gone, readable transcript still there.
        #expect(!FileManager.default.fileExists(atPath: files.asr.path))
        #expect(!FileManager.default.fileExists(atPath: files.mergedWords.path))
        #expect(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8) == before)

        let record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        #expect(record.state == .prepared)
        #expect(record.language == "he")
    }

    @Test func fromFailedItReentersAtImportedAndClearsTheError() throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .failed
        record.errorDescription = "Transcription failed: something"
        record.degradations = [Degradation(kind: .diarizationUnavailable,
                                           message: "Diarization unavailable: the transcript has timestamps but no speaker labels.")]
        try AtomicFile.writeJSON(record, to: files.job)

        try JobPipeline.retranscribe(files: files, newLanguage: nil)

        let after = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        #expect(after.state == .imported)
        #expect(after.errorDescription == nil)
        #expect(after.degradations.isEmpty)
    }
}

/// Stopping a job is not the same as the machine failing at it. The two used
/// to be indistinguishable once the work reached the diarizer.
struct CancellingDiarizer: SpeakerDiarizer {
    static let engineID = "test/cancelling"
    let modelIdentifier = "test/cancelling"
    func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult {
        // What `Task.checkCancellation()` inside the sample-loading loop
        // throws once the user pauses.
        throw CancellationError()
    }
}

@Suite struct CancellationHonestyTests {

    /// The diarization stage catches everything and degrades, which is right
    /// for a missing model and wrong for a stopped job: the run would carry on
    /// and finish COMPLETE, unlabelled, blaming the diarizer for the user's
    /// own pause. It must interrupt instead.
    @Test func pausingDuringDiarizationInterruptsRatherThanDegrading() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try Data("pcm".utf8).write(to: files.normalizedPCM)
        try FileManager.default.removeItem(at: files.diarization)

        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .prepared
        record.lastCheckpointState = .prepared
        try AtomicFile.writeJSON(record, to: files.job)

        let engines = JobPipeline.Engines(transcribers: [RefusingTranscriber()],
                                          diarizer: CancellingDiarizer())
        await #expect(throws: LonghandError.cancelled) {
            _ = try await JobPipeline.run(files: files, engines: engines, progress: { _ in })
        }

        let stopped = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        #expect(stopped.state == .interrupted, "a stopped job is resumable, not complete")
        #expect(!stopped.degradations.contains(kind: .diarizationUnavailable),
                "a user's pause must not be recorded as the diarizer failing")
        #expect(!FileManager.default.fileExists(atPath: files.transcriptJSON.path),
                "nothing should have been exported")
    }
}

/// A diarizer that still needs its weights. App Store guideline 4.2.3(ii)
/// requires the size to be disclosed and consent taken before the fetch.
struct UndownloadedDiarizer: SpeakerDiarizer {
    static let engineID = "test/undownloaded"
    let modelIdentifier = "test/undownloaded"
    var pendingDownloadBytes: Int64? { 33_000_000 }
    func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult {
        Issue.record("the diarizer downloaded without asking")
        throw LonghandError.cancelled
    }
}

@Suite struct ModelDownloadConsentTests {

    /// The diarizer's fetch is small but unconditional on first use, so it is
    /// the one that silently spends a data plan. It must stop and ask.
    @Test func anUndownloadedModelStopsAndAsksBeforeFetching() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try Data("pcm".utf8).write(to: files.normalizedPCM)
        try FileManager.default.removeItem(at: files.diarization)

        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .prepared
        record.lastCheckpointState = .prepared
        try AtomicFile.writeJSON(record, to: files.job)

        let engines = JobPipeline.Engines(transcribers: [RefusingTranscriber()],
                                          diarizer: UndownloadedDiarizer())
        await #expect(throws: LonghandError.modelDownloadRequired(asset: "Speaker identification",
                                                                  bytes: 33_000_000)) {
            _ = try await JobPipeline.run(files: files, engines: engines, progress: { _ in })
        }

        let stopped = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        #expect(!stopped.degradations.contains(kind: .diarizationUnavailable),
                "a consent prompt is not the diarizer failing")
        #expect(!FileManager.default.fileExists(atPath: files.transcriptJSON.path),
                "nothing should be exported while the user has not answered")
        // The bug this pins: the generic catch marked the job FAILED and wrote
        // the consent text in as an error, so a phone showed "Couldn't
        // transcribe. Speaker identification needs a one-time 11 MB download"
        // over a job whose checkpoints were all intact.
        #expect(stopped.state != .failed, "a question must not fail the job")
        #expect(stopped.state == .interrupted,
                "stopped, checkpointed and resumable is what this is")
        #expect(stopped.errorDescription == nil,
                "an unanswered question is not an error to display")
    }

    /// The raw-PCM prompt (§5.5) is the same shape (an answer only a person
    /// can give) and used to fail the job identically.
    @Test func theRawPCMQuestionAlsoLeavesTheJobResumable() {
        #expect(LonghandError.unsupportedMedia(detected: "unknown", rawPCMCandidate: true).isAwaitingAnswer)
        #expect(LonghandError.modelDownloadRequired(asset: "x", bytes: 1).isAwaitingAnswer)
        // A genuine dead end still fails.
        #expect(!LonghandError.unsupportedMedia(detected: "unknown", rawPCMCandidate: false).isAwaitingAnswer)
        #expect(!LonghandError.checkpointCorrupt(stage: "MERGED").isAwaitingAnswer)
    }

    /// And once the user says yes, the same run proceeds.
    @Test func consentLetsTheRunContinue() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try Data("pcm".utf8).write(to: files.normalizedPCM)

        // Diarization checkpoint left in place, so consent is the only gate
        // between PREPARED and a finished transcript.
        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        record.state = .prepared
        record.lastCheckpointState = .prepared
        try AtomicFile.writeJSON(record, to: files.job)

        let engines = JobPipeline.Engines(transcribers: [RefusingTranscriber()],
                                          diarizer: UndownloadedDiarizer())
        let finished = try await JobPipeline.run(files: files, engines: engines,
                                                 userConfirmedModelDownload: true,
                                                 progress: { _ in })
        #expect(finished.state == .complete)
    }
}

/// A resumed or re-run job accumulates its stage times, which is right for what
/// the job cost and wrong for what any stage takes. Both numbers have to come
/// out of a real pipeline run, not just out of the record type.
@Suite struct PerRunTimingTests {

    @Test func oneRunRecordsItselfAsOneRun() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let record = try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        #expect(record.processingRuns == 1)
        #expect(!record.wasResumed)
        let perRun = try #require(record.lastRunStageSeconds)
        #expect(!perRun.isEmpty, "a run that did work must record what it cost")
    }

    /// The shape the phone was in: two runs over one job, and a total that
    /// belongs to no single sitting.
    @Test func aSecondRunIsCountedAndMeasuredSeparately() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        // The §10 COMPLETE→MERGED re-entry edge: a second run over the same
        // checkpoints, which is what a resume looks like from here and needs no
        // audio the stub engines cannot supply.
        var record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        try record.transition(to: .merged)
        try AtomicFile.writeJSON(record, to: files.job)

        let second = try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        #expect(second.processingRuns == 2)
        #expect(second.wasResumed)

        let total = try #require(second.stageSeconds)
        let perRun = try #require(second.lastRunStageSeconds)
        // The merge runs in both, so the total has to exceed the last run's own
        // figure for it. This is the double-count the breakdown now labels.
        let mergeTotal = try #require(total[JobStage.merging.rawValue])
        let mergeThisRun = try #require(perRun[JobStage.merging.rawValue])
        #expect(mergeTotal >= mergeThisRun)
        #expect(second.comparableStageSeconds?[JobStage.merging.rawValue] == mergeThisRun)
    }

    /// The budget reads one run, so an interrupted job is not called slow for
    /// having been interrupted.
    @Test func theBudgetJudgesTheLastRunOnly() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var record = try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })

        // A total no single sitting spent, against a healthy last run.
        record.stageSeconds = [JobStage.exporting.rawValue: 600]
        record.lastRunStageSeconds = [JobStage.exporting.rawValue: 0.4]
        record.processingRuns = 5
        #expect(StageBudget.implausibleStages(in: record).isEmpty)

        record.lastRunStageSeconds = [JobStage.exporting.rawValue: 600]
        #expect(StageBudget.implausibleStages(in: record) == [.exporting])
    }
}
