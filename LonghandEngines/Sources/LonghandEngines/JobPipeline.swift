import Foundation
import LonghandKit

/// Sequential stage runner (§7.3): ASR, then diarization, then merge, never
/// concurrent inference. Every expensive stage writes a durable checkpoint
/// before the state machine advances (§10), so a relaunch resumes.
public nonisolated enum JobPipeline {

    public struct Engines: Sendable {
        var transcribers: [any SpeechTranscribing]
        var diarizer: any SpeakerDiarizer
    }

    public static func makeDefaultEngines(
        whisperVariant: WhisperModelVariant = .turbo
    ) async -> Engines {
        Engines(transcribers: [await AppleSpeechEngine.make(),
                               WhisperKitEngine(variant: whisperVariant)],
                diarizer: CommunityOneDiarizer())
    }

    // MARK: - Engine routing (§4.2)

    /// `metadata.declaredLanguage` sentinel: no pinned language, the engine
    /// re-detects as the recording progresses.
    public static let autoDetectLanguage = "auto"

    /// Returns the engine for the declared language plus a degradation note
    /// when a fallback substitution happened (§17).
    public static func selectEngine(from engines: Engines, language: Locale.Language?,
                             autoDetect: Bool = false) throws
        -> (engine: any SpeechTranscribing, substitution: String?) {
        if autoDetect {
            if let engine = engines.transcribers.first(where: { $0.supportsLanguageAutoDetection }) {
                return (engine, nil)
            }
            if let fallback = engines.transcribers.first {
                return (fallback, "No engine supports mixed-language auto-detection; used \(type(of: fallback).engineID) with a single language instead.")
            }
            throw LonghandError.engineUnavailable(engine: "none", language: autoDetectLanguage)
        }
        // Route on the device language rather than skipping the check.
        let language = language ?? Locale.current.language
        if let engine = engines.transcribers.first(where: { $0.supports(language: language) }) {
            return (engine, nil)
        }
        // §17: record the substitution in models.asr.
        if let fallback = engines.transcribers.first {
            return (fallback, "No engine declares support for “\(language.minimalIdentifier)”; used \(type(of: fallback).engineID) instead.")
        }
        throw LonghandError.engineUnavailable(engine: "none", language: language.minimalIdentifier)
    }

    // MARK: - Run

    public static func run(files: JobFiles, engines: Engines,
                    profiles: [SpeakerProfile] = [],
                    userConfirmedRawPCM: Bool = false,
                    userConfirmedModelDownload: Bool = false,
                    progress outerProgress: @escaping ProgressSink) async throws -> JobRecord {
        guard var record = try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job") else {
            throw LonghandError.checkpointCorrupt(stage: "job")
        }
        // Timing rides the progress sink rather than the stage boundaries, so
        // one wrapper also measures what happens inside WhisperKit.
        let clock = StageClock()
        var recordedThisRun = false
        let progress: ProgressSink = { update in
            clock.enter(update.stage)
            outerProgress(update)
        }
        guard var metadata = (try? AtomicFile.readJSON(ImportMetadata.self, from: files.metadata, stage: "IMPORTED")) ?? nil else {
            // Outside the do/catch below, so mark it failed here or the row
            // stays active and every launch retries it silently.
            if record.state.isActive {
                try? record.transition(to: .failed)
                record.errorDescription = "This recording's metadata is missing or unreadable."
                try? AtomicFile.writeJSON(record, to: files.job)
            }
            throw LonghandError.checkpointCorrupt(stage: "IMPORTED")
        }
        if record.state == .interrupted || record.state == .failed {
            try record.transition(to: record.lastCheckpointState == .imported ? .imported : record.lastCheckpointState)
        }
        // A kill between a checkpoint write and the job.json write leaves the
        // record behind the disk; gating stages on a stale state then skips
        // work or trips an illegal transition. Forward only, never terminal.
        if record.state.isActive, let implied = stateImpliedByCheckpoints(files: files) {
            // Stepped, not jumped: there is no IMPORTED → DIARIZED edge, and a
            // rejected jump would strand the record behind its checkpoints.
            for step in JobPipeline.forwardStates {
                guard record.state != implied else { break }
                if record.state.canTransition(to: step), Self.pipelineOrder(step) <= Self.pipelineOrder(implied),
                   Self.pipelineOrder(step) > Self.pipelineOrder(record.state) {
                    try record.transition(to: step)
                }
            }
        }
        record.errorDescription = nil

        // Read-modify-write: a rename or pause landing while the run holds
        // `record` in memory must survive the next checkpoint.
        // This run's own time, kept beside the running totals. Which stages a
        // run repeats depends on where the last one stopped, so only a single
        // run's figures can be compared with anything.
        var thisRunSeconds: [JobStage: TimeInterval] = [:]
        func persist() throws {
            let drained = clock.drain()
            for (stage, seconds) in drained {
                record.recordStage(stage, seconds: seconds)
                thisRunSeconds[stage, default: 0] += seconds
            }
            if !thisRunSeconds.isEmpty {
                // Counted on the first stage that costs anything, not on entry:
                // a run that finds every checkpoint present and only re-exports
                // has spent no sitting worth counting.
                if record.lastRunStageSeconds == nil || !recordedThisRun {
                    recordedThisRun = true
                    record.processingRuns = (record.processingRuns ?? 0) + 1
                }
                record.lastRunStageSeconds = thisRunSeconds.reduce(into: [:]) {
                    $0[$1.key.rawValue] = ($1.value * 1000).rounded() / 1000
                }
            }
            if let onDisk = (try? AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job")) ?? nil {
                record = record.mergingUserFields(from: onDisk)
            }
            try AtomicFile.writeJSON(record, to: files.job)
        }

        /// Stage bookkeeping that cannot fail a job whose work succeeded:
        /// re-entering the stage the record already sits at is normal on
        /// resume, and IDENTIFIED has no self-edge.
        func advance(to next: JobState) throws {
            guard record.state != next, record.state.canTransition(to: next) else { return }
            try record.transition(to: next)
        }

        // §17: a failure names its stage.
        var currentStage = JobStage.preparing

        do {
            /// A deleted job must stay deleted: `AtomicFile.write` recreates a
            /// missing directory, so a run outliving its folder rebuilds it.
            func checkStillExists() throws {
                guard FileManager.default.fileExists(atPath: files.root.path) else {
                    throw CancellationError()
                }
            }

            // Checked at every stage boundary. Within a stage it is up to the
            // engine: WhisperKit checks internally, the synchronous normalize
            // and diarize loops do not, so a stop there waits them out.
            try Task.checkCancellation()

            // ---- PREPARE (§5.4, §5.5) ------------------------------------
            guard let originalURL = files.findOriginal() else {
                throw LonghandError.decodeFailed(reason: "original recording is missing from the job folder")
            }
            let needsAudio = try AtomicFile.readJSON(ASRResult.self, from: files.asr, stage: "TRANSCRIBED") == nil
            var asset: AudioAsset?
            if needsAudio {
                progress(PipelineProgress(stage: .preparing, fraction: 0))
                let (prepared, stats, _) = try FormatAdapterChain.normalize(
                    url: originalURL, destinationURL: files.normalizedPCM,
                    userConfirmedRawPCM: userConfirmedRawPCM)
                asset = prepared
                metadata.durationSeconds = prepared.duration
                metadata.channelCount = stats.channelCount
                metadata.channelRMSEnergy = stats.rmsEnergy.isEmpty ? nil : stats.rmsEnergy
                metadata.interChannelCorrelation = stats.interChannelCorrelation
                metadata.appliedGainDb = stats.appliedGainDb
                try AtomicFile.writeJSON(metadata, to: files.metadata)
                if let gain = stats.appliedGainDb {
                    // §17: an altered input is never silent.
                    record.degradations.appendIfNew(Degradation(
                        kind: .quietBoostApplied,
                        message: "Recording was very quiet; volume boosted by \(Int(gain.rounded())) dB for transcription (original audio unchanged)."))
                }
                record.duration = prepared.duration
                if record.state == .imported { try record.transition(to: .prepared) }
                try persist()
            }

            try Task.checkCancellation()
            try checkStillExists()
            // ---- ASR (§6) --------------------------------------------------
            let autoDetect = metadata.declaredLanguage == Self.autoDetectLanguage
            let language = autoDetect ? nil
                : metadata.declaredLanguage.map { Locale.Language(identifier: $0) }
            var asrResult = try AtomicFile.readJSON(ASRResult.self, from: files.asr, stage: "TRANSCRIBED")
            if asrResult == nil {
                currentStage = .transcribing
                guard let asset else {
                    throw LonghandError.decodeFailed(reason: "prepared audio unavailable")
                }
                let (engine, substitution) = try selectEngine(from: engines, language: language,
                                                              autoDetect: autoDetect)
                if let substitution {
                    record.degradations.appendIfNew(Degradation(kind: .engineSubstituted,
                                                                message: substitution))
                }
                // §4.2.3(ii): disclose the size and take consent before the fetch.
                if let bytes = engine.pendingDownloadBytes, !userConfirmedModelDownload {
                    throw LonghandError.modelDownloadRequired(
                        asset: "The \(type(of: engine).engineID) speech model", bytes: bytes)
                }
                // nil language + auto-capable engine = per-window detection.
                let pinnedLanguage = autoDetect ? nil : language
                var result = try await engine.transcribe(asset, language: pinnedLanguage, progress: progress)
                // Hallucination backstops (§6.4) apply to Whisper-family output.
                if type(of: engine).engineID == WhisperKitEngine.engineID {
                    let (kept, suppressed) = HallucinationFilter.filter(segments: result.segments, speechRegions: nil)
                    result.segments = kept
                    result.suppressedSpans.append(contentsOf: suppressed)
                }
                try AtomicFile.writeJSON(result, to: files.asr)
                asrResult = result
                if record.state == .prepared { try record.transition(to: .transcribed) }
                record.language = result.language
                try persist()
            }
            guard let asr = asrResult else { throw LonghandError.checkpointCorrupt(stage: "TRANSCRIBED") }

            try Task.checkCancellation()
            try checkStillExists()
            // ---- Diarization (§7), degradable per §17 ---------------------
            var diarization = try AtomicFile.readJSON(DiarizationResult.self, from: files.diarization, stage: "DIARIZED")
            // Gated on the checkpoint and the prepared audio, not on the
            // record's state, which can lag the disk. The audio is deleted at
            // COMPLETE (§13.4), so a re-merge of a job that degraded without
            // diarization stays degraded rather than throwing.
            let preparedAudioExists = FileManager.default.fileExists(atPath: files.normalizedPCM.path)
            if diarization == nil, preparedAudioExists {
                progress(PipelineProgress(stage: .diarizing, fraction: 0))
                if let bytes = engines.diarizer.pendingDownloadBytes, !userConfirmedModelDownload {
                    throw LonghandError.modelDownloadRequired(
                        asset: "Speaker identification", bytes: bytes)
                }
                do {
                    // §7.1: a trustworthy (user-declared) count only; never from filename.
                    let audio = AudioAsset(url: files.normalizedPCM,
                                           sampleRate: AudioNormalizer.targetSampleRate,
                                           channelCount: 1,
                                           duration: metadata.durationSeconds ?? 0)
                    let result = try await engines.diarizer.diarize(audio, expectedSpeakers: metadata.expectedSpeakerCount,
                                                                    progress: progress)
                    try AtomicFile.writeJSON(result, to: files.diarization)
                    diarization = result
                    try advance(to: .diarized)
                } catch let error as LonghandError {
                    // A consent prompt is not the diarizer failing; it has to
                    // reach the UI so the user can answer it.
                    if case .modelDownloadRequired = error { throw error }
                    record.degradations.appendIfNew(Self.diarizationUnavailable(because: error))
                } catch is CancellationError {
                    // Swallowing this would finish the job unlabelled and blame
                    // the diarizer for what the user stopped.
                    throw CancellationError()
                } catch {
                    record.degradations.appendIfNew(Self.diarizationUnavailable(because: error))
                }
                try persist()
            }

            try Task.checkCancellation()
            try checkStillExists()
            // ---- Merge + turns (§8, §8.1, §8.2) ----------------------------
            currentStage = .merging
            progress(PipelineProgress(stage: .merging, fraction: 0))
            let params = MergeParams()
            let effectiveDiarization = diarization
                ?? DiarizationResult(engine: "none", modelIdentifier: "none", intervals: [])
            let merged = MergeEngine.merge(asr: asr, diarization: effectiveDiarization, params: params)
            try AtomicFile.writeJSON(merged, to: files.mergedWords)
            let rawTurns = TurnBuilder.buildTurns(words: merged.words, params: params)

            // Generic labels plus whatever identification claimed. User names
            // are not read here: they live in overlay.json and are applied by
            // writeAll, which is what lets this stage rebuild turns from
            // scratch on every re-merge (§10 COMPLETE→MERGED).
            let priorIdentity = try AtomicFile.readJSON(IdentityResult.self, from: files.identity, stage: "IDENTIFIED")
            var speakers = speakerTable(clusters: effectiveDiarization.speakerIDs, identity: priorIdentity)

            try advance(to: .merged)
            try persist()

            // ---- Known-speaker identification (§9.3) -----------------------
            // No profiles or no centroids means generic labels, never an
            // error. Matches carry confirmedByUser=false so the UI can tell
            // "the model thinks" from "the user said" (§13.1).
            if let centroids = diarization?.centroids, !profiles.isEmpty {
                currentStage = .identifying
                progress(PipelineProgress(stage: .identifying, fraction: 0))
                let identity = SpeakerMatcher.match(centroids: centroids,
                                                    profiles: profiles,
                                                    modelIdentifier: engines.diarizer.modelIdentifier)
                try AtomicFile.writeJSON(identity, to: files.identity)
                for (cluster, match) in identity.matches {
                    speakers[cluster] = .init(displayName: match.displayName,
                                              matchScore: match.score,
                                              confirmedByUser: false)
                }
                if !identity.matches.isEmpty {
                    try advance(to: .identified)
                    try persist()
                }
            }

            let turns = TurnBuilder.transcriptTurns(from: rawTurns, speakers: speakers)

            // ---- Transcript + exports (§13.1) ------------------------------
            let identityApplied = speakers.values.contains { $0.matchScore != nil }
            let transcript = Transcript(
                recordingID: record.id.uuidString,
                sourceHash: metadata.sourceHash,
                duration: metadata.durationSeconds ?? record.duration ?? 0,
                language: asr.language,
                pipelineVersion: Transcript.currentPipelineVersion,
                models: .init(asr: "\(asr.engine)/\(asr.modelIdentifier.split(separator: "/").last.map(String.init) ?? asr.modelIdentifier)",
                              diarization: diarization.map { "\($0.engine)/\($0.modelIdentifier.split(separator: "/").last.map(String.init) ?? $0.modelIdentifier)" },
                              speakerID: identityApplied ? "centroid-cosine/\(engines.diarizer.modelIdentifier)" : nil),
                mergeParams: params.record,
                speakers: speakers,
                turns: turns
            )
            // §17: three cases, not two.
            //
            // This used to fire only when the transcript came back empty, which
            // meant the common case went unreported: a transcript with text in
            // it, from which the §6.4 filter had quietly removed a passage. The
            // owner's own library has one (a Hebrew question dropped as a
            // `verbatimRepeat`), and nothing anywhere said so. Filtered speech
            // is a degraded transcript whether or not anything survived, and
            // §6.4's "never silently discard" is not satisfied by writing the
            // span to a checkpoint no one reads.
            if !asr.suppressedSpans.isEmpty {
                let count = asr.suppressedSpans.count
                let passages = "\(count) passage\(count == 1 ? "" : "s")"
                let verb = count == 1 ? "was" : "were"
                record.degradations.appendIfNew(Degradation(
                    kind: .speechFilteredAsHallucination,
                    message: turns.isEmpty
                        ? "No speech kept: \(passages) \(verb) filtered as likely hallucination."
                        : "\(passages) \(verb) filtered as likely hallucination and left out of this transcript."))
            } else if turns.isEmpty {
                record.degradations.appendIfNew(Degradation(
                    kind: .noSpeechDetected,
                    message: "No speech detected in this recording."))
            }

            currentStage = .exporting
            progress(PipelineProgress(stage: .exporting, fraction: 0))
            let exportResult = try TranscriptExporter.writeAll(transcript, to: files)
            if exportResult.staleCount > 0 {
                // Kept in the overlay, reported here, never dropped in silence.
                record.degradations.appendIfNew(Degradation(
                    kind: .editsNotReattached,
                    message: "\(exportResult.staleCount) edit\(exportResult.staleCount == 1 ? "" : "s") could not be reattached after this transcript changed."))
            }

            try advance(to: .complete)
            // §13.4: reproducible from the original, so deleted at COMPLETE.
            files.deleteTransientArtifacts()
            for stray in files.strayWorkingFiles() { try? FileManager.default.removeItem(at: stray) }
            try persist()
            return record
        } catch is CancellationError {
            try? record.transition(to: .interrupted)
            // Through persist(), so a pause flag written while this run was
            // unwinding survives the checkpoint that records the stop.
            try? persist()
            throw LonghandError.cancelled
        } catch let error as LonghandError where error.isAwaitingAnswer {
            // A question is not a failure: everything this run produced is on
            // disk and answering resumes from there, which is INTERRUPTED, the
            // same state a pause writes.
            if record.state.isActive {
                try? record.transition(to: .interrupted)
            }
            record.errorDescription = nil
            try? persist()
            throw error
        } catch {
            if record.state.isActive {
                try? record.transition(to: .failed)
            }
            let detail = (error as? LonghandError)?.localizedDescription ?? error.localizedDescription
            // Drained before the message is composed, so the failure can name
            // where the time went. "The model would not load" and "it spent
            // three minutes not loading" are different bugs, and only the
            // second one is visible without pulling the container.
            // Through persist(), so the failing run's own figures are recorded
            // the same way a successful one's are.
            try? persist()
            record.errorDescription = failureMessage(stage: currentStage, detail: detail,
                                                     thisRun: thisRunSeconds)
            try? persist()
            throw error
        }
    }

    /// Time per stage, accumulated as the progress sink reports stage changes.
    /// `ContinuousClock`, not `Date`: a clock adjustment mid-transcription
    /// would produce a negative measurement. Locked because the sink is
    /// `@Sendable` and WhisperKit calls it from its own tasks.
    final class StageClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: (stage: JobStage, since: ContinuousClock.Instant)?
        private var totals: [JobStage: TimeInterval] = [:]

        func enter(_ stage: JobStage) {
            let now = ContinuousClock.now
            lock.lock()
            defer { lock.unlock() }
            if let current, current.stage == stage { return }
            close(at: now)
            current = (stage, now)
        }

        /// Drains, so a stage's time is written once even though `persist()`
        /// runs at every boundary.
        func drain() -> [JobStage: TimeInterval] {
            let now = ContinuousClock.now
            lock.lock()
            defer { lock.unlock() }
            close(at: now)
            // Re-opened, so the running stage's clock keeps going across the
            // write rather than restarting from zero.
            if let stage = current?.stage { current = (stage, now) }
            let measured = totals
            totals = [:]
            return measured
        }

        private func close(at now: ContinuousClock.Instant) {
            guard let current else { return }
            let elapsed = TimeInterval(current.since.duration(to: now).components.seconds)
                + TimeInterval(current.since.duration(to: now).components.attoseconds) / 1e18
            totals[current.stage, default: 0] += elapsed
        }
    }

    /// The note carries the cause because the error is gone the instant the
    /// job completes, and "no speaker labels" alone does not say whether to
    /// retry on Wi-Fi or free up space. One sentence, not a raw error dump.
    static func diarizationUnavailable(because error: Error) -> Degradation {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return Degradation(
            kind: .diarizationUnavailable,
            message: "Diarization unavailable: the transcript has timestamps but no speaker labels. Reason: \(reason)")
    }

    /// A failure names its stage (§17), and says where this run's time went
    /// when one stage dominates it. "The model would not load" and "it spent
    /// three minutes not loading" are different bugs, and the second is
    /// otherwise invisible without pulling the job folder.
    ///
    /// `thisRun` rather than the record: `stageSeconds` accumulates across
    /// runs, so a resumed job would otherwise report a total nobody spent in
    /// one sitting. No judgement is attached, because none is warranted: a slow
    /// stage is worth reporting on a failure whether or not it misbehaved.
    static func failureMessage(stage: JobStage, detail: String,
                               thisRun: [JobStage: TimeInterval]) -> String {
        let message = "\(stageDisplayName(stage)) failed: \(detail)"
        guard let dominant = StageBudget.dominantStage(in: thisRun) else { return message }
        return message + " Most of that time (\(StageBudget.durationText(dominant.seconds)))"
            + " went on \(stageDisplayName(dominant.stage).lowercased())."
    }

    public static func stageDisplayName(_ stage: JobStage) -> String {
        switch stage {
        case .importing: "Import"
        case .preparing: "Audio preparation"
        case .downloadingModel: "Model download"
        case .loadingModel: "Loading model"
        case .transcribing: "Transcription"
        case .diarizing: "Speaker detection"
        case .merging: "Merge"
        case .identifying: "Speaker identification"
        case .exporting: "Export"
        }
    }

    // MARK: - Re-transcribe (COMPLETE → PREPARED re-entry, §13.2)

    /// Re-runs inference from the retained original under a new declared
    /// language. Deletes ASR and downstream checkpoints; the original stays.
    public static func retranscribe(files: JobFiles, newLanguage: String?) throws {
        guard var record = try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"),
              var metadata = try AtomicFile.readJSON(ImportMetadata.self, from: files.metadata, stage: "IMPORTED") else {
            throw LonghandError.checkpointCorrupt(stage: "job")
        }
        // Validate before touching anything: rejecting an active job after
        // rewriting the language and deleting checkpoints would still change
        // the language and destroy work a running job had produced.
        switch record.state {
        case .complete:
            try record.transition(to: .prepared)
        case .failed, .interrupted:
            try record.transition(to: .imported)
        default:
            // Not offered while a job is actively processing.
            throw LonghandError.invalidStateTransition(from: record.state, to: .prepared)
        }

        metadata.declaredLanguage = newLanguage
        try AtomicFile.writeJSON(metadata, to: files.metadata)

        let fm = FileManager.default
        // Inference checkpoints must go: they are what is being redone.
        for url in [files.asr, files.diarization, files.mergedWords, files.identity] {
            try? fm.removeItem(at: url)
        }
        // The transcript and its exports stay until the re-run replaces them
        // atomically at its export stage; deleting them up front would leave a
        // failed or abandoned run with nothing to read.

        record.language = newLanguage
        record.degradations = []
        record.errorDescription = nil
        try AtomicFile.writeJSON(record, to: files.job)
    }

    /// Pipeline order, for reconciling a record with the checkpoints on disk.
    static let forwardStates: [JobState] = [.prepared, .transcribed, .diarized, .merged, .identified]

    static func pipelineOrder(_ state: JobState) -> Int {
        switch state {
        case .imported: 0
        case .prepared: 1
        case .transcribed: 2
        case .diarized: 3
        case .merged: 4
        case .identified: 5
        case .complete: 6
        case .interrupted, .failed: -1
        }
    }

    /// The furthest state the checkpoints on disk can justify, or nil when
    /// there is nothing beyond the import.
    static func stateImpliedByCheckpoints(files: JobFiles) -> JobState? {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        if exists(files.identity) { return .identified }
        if exists(files.mergedWords) { return .merged }
        if exists(files.diarization) { return .diarized }
        if exists(files.asr) { return .transcribed }
        return nil
    }

    // MARK: - Rerender (the derived-transcript rule)

    /// A generic label per cluster, overwritten by whatever identification
    /// claimed. Never the user's names: those are overlay content.
    static func speakerTable(clusters: [String], identity: IdentityResult?) -> [String: Transcript.Speaker] {
        var speakers: [String: Transcript.Speaker] = [:]
        for (index, cluster) in clusters.enumerated() {
            speakers[cluster] = .init(displayName: "Speaker \(index + 1)")
        }
        for (cluster, match) in identity?.matches ?? [:] {
            speakers[cluster] = .init(displayName: match.displayName,
                                      matchScore: match.score,
                                      confirmedByUser: false)
        }
        return speakers
    }

    /// Rebuilds `transcript.json` and the exports from the durable
    /// checkpoints, then applies the overlay (inside `writeAll`). The machine's
    /// own text is never overwritten in place, which is what makes an edit
    /// reversible. Every post-completion mutation goes through here.
    @discardableResult
    public static func rerender(files: JobFiles) throws -> UserOverlay.ApplyResult {
        guard let previous = try AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE") else {
            throw LonghandError.checkpointCorrupt(stage: "COMPLETE")
        }
        guard let merged = try AtomicFile.readJSON(MergeOutput.self, from: files.mergedWords, stage: "MERGED") else {
            // Older jobs may predate the merged-word checkpoint. Re-applying
            // the overlay is still correct; only un-edit needs the words.
            return try TranscriptExporter.writeAll(previous, to: files)
        }
        let identity = try AtomicFile.readJSON(IdentityResult.self, from: files.identity, stage: "IDENTIFIED")
        let diarization = try AtomicFile.readJSON(LonghandKit.DiarizationResult.self, from: files.diarization, stage: "DIARIZED")

        let rawTurns = TurnBuilder.buildTurns(words: merged.words, params: merged.params)
        let clusters = diarization?.speakerIDs ?? Array(Set(merged.words.compactMap(\.speaker))).sorted()
        let speakers = speakerTable(clusters: clusters, identity: identity)

        var transcript = previous
        transcript.speakers = speakers
        transcript.turns = TurnBuilder.transcriptTurns(from: rawTurns, speakers: speakers)
        transcript.mergeParams = merged.params.record
        if let identity, !identity.matches.isEmpty {
            transcript.models.speakerID = "centroid-cosine/\(identity.modelIdentifier)"
        }
        return try TranscriptExporter.writeAll(transcript, to: files)
    }

    /// The single path for every user-authored change.
    @discardableResult
    public static func updateOverlay(files: JobFiles,
                                     _ mutate: (inout UserOverlay) -> Void) throws -> UserOverlay.ApplyResult {
        var overlay = try AtomicFile.readJSON(UserOverlay.self, from: files.overlay, stage: "overlay")
            ?? UserOverlay()
        mutate(&overlay)
        try AtomicFile.writeJSON(overlay, to: files.overlay)
        return try rerender(files: files)
    }

    // MARK: - Confirm speaker (COMPLETE self-edge, §9.3 / §13.1)

    /// Records agreement with an automatic match, so the auto badge clears
    /// and the claim outlives every future re-merge.
    public static func confirmSpeaker(files: JobFiles, cluster: String) throws {
        guard let transcript = try AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE"),
              let speaker = transcript.speakers[cluster] else { return }
        try updateOverlay(files: files) { overlay in
            overlay.setSpeakerName(speaker.displayName, forCluster: cluster)
        }
    }

    // MARK: - Turn-level edits (§ addition, overlay-backed)

    /// Editing back to the machine's own words removes the correction rather
    /// than recording a no-op.
    public static func editTurnText(files: JobFiles, turn: Transcript.Turn, newText: String) throws {
        try updateOverlay(files: files) { overlay in
            overlay.setText(newText, forTurn: turn)
        }
    }

    /// Restores the derived text for a turn the user had edited.
    public static func clearTurnEdit(files: JobFiles, turn: Transcript.Turn) throws {
        try updateOverlay(files: files) { overlay in
            overlay.clearText(forTurn: turn)
        }
    }

    /// Leaves the diarizer's own claim alone (§9.2), so centroids and
    /// enrollment eligibility keep reading unmodified machine output.
    public static func assignTurn(files: JobFiles, turn: Transcript.Turn,
                                  toCluster cluster: String, displayName: String? = nil) throws {
        try updateOverlay(files: files) { overlay in
            overlay.assign(turn: turn, toCluster: cluster, displayName: displayName)
        }
    }

    public static func addMarker(files: JobFiles, at time: TimeInterval, label: String? = nil) throws {
        try updateOverlay(files: files) { overlay in
            overlay.addMarker(at: time, label: label)
        }
    }

    // MARK: - Re-identify (COMPLETE → IDENTIFIED re-entry edge, §10)

    /// Re-runs identification from the stored diarization checkpoint after new
    /// enrollment: no inference, no ASR rerun.
    public static func reidentify(files: JobFiles, profiles: [SpeakerProfile],
                           diarizerModelIdentifier: String) throws {
        guard try AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE") != nil,
              let diarization = try AtomicFile.readJSON(LonghandKit.DiarizationResult.self, from: files.diarization, stage: "DIARIZED"),
              let centroids = diarization.centroids else { return }

        let identity = SpeakerMatcher.match(centroids: centroids, profiles: profiles,
                                            modelIdentifier: diarizerModelIdentifier)
        try AtomicFile.writeJSON(identity, to: files.identity)
        // The overlay is applied after this, so §13.1 ("the user said" beats
        // "the model thinks") holds by construction, not by a guard here.
        try rerender(files: files)
    }

    // MARK: - Relabel (COMPLETE self-edge, §10 / §15.3)

    /// Renames a speaker without re-running any inference.
    public static func relabelSpeaker(files: JobFiles, cluster: String, newName: String) throws {
        guard try AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE") != nil else {
            throw LonghandError.checkpointCorrupt(stage: "COMPLETE")
        }
        try updateOverlay(files: files) { overlay in
            overlay.setSpeakerName(newName, forCluster: cluster)
        }
    }
}
