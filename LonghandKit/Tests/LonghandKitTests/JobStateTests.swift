import Foundation
import Testing
@testable import LonghandKit

@Suite struct JobStateTests {

    @Test func forwardPipelineIsLegal() {
        let path: [JobState] = [.imported, .prepared, .transcribed, .diarized, .merged, .identified, .complete]
        for (from, to) in zip(path, path.dropFirst()) {
            #expect(from.canTransition(to: to), "\(from) → \(to) must be legal")
        }
    }

    @Test func speakerIDIsOptional() {
        #expect(JobState.merged.canTransition(to: .complete))
    }

    @Test func diarizationFailureDegradesToMerge() {
        // §17: diarization fails → still export a timestamped transcript.
        #expect(JobState.transcribed.canTransition(to: .merged))
    }

    @Test func reentryEdgesExist() {
        // §10: re-merge after τ change and re-identify after enrollment,
        // without re-entering TRANSCRIBED; relabel/export is a COMPLETE self-edge.
        #expect(JobState.complete.canTransition(to: .merged))
        #expect(JobState.complete.canTransition(to: .identified))
        #expect(JobState.complete.canTransition(to: .complete))
        #expect(!JobState.complete.canTransition(to: .transcribed))
        #expect(!JobState.complete.canTransition(to: .imported))
    }

    @Test func explicitRerunReentersAtPrepared() {
        // §13.2: re-running with a new model/language is an explicit user
        // action; it re-enters at PREPARED, never silently.
        #expect(JobState.complete.canTransition(to: .prepared))
        var record = JobRecord(id: UUID(), title: "t", createdAt: .distantPast,
                               state: .complete, lastCheckpointState: .complete)
        try? record.transition(to: .prepared)
        #expect(record.state == .prepared)
    }

    @Test func noExportedState() {
        // EXPORTED was removed in v1.1 (§10); export is an action, not a state.
        #expect(!JobState.allCases.map(\.rawValue).contains("EXPORTED"))
    }

    @Test func activeStatesCanInterruptAndFail() {
        for state in JobState.allCases where state.isActive {
            #expect(state.canTransition(to: .interrupted))
            #expect(state.canTransition(to: .failed))
        }
        #expect(!JobState.complete.canTransition(to: .interrupted))
    }

    @Test func skippingStagesForwardIsIllegal() {
        #expect(!JobState.imported.canTransition(to: .transcribed))
        #expect(!JobState.prepared.canTransition(to: .diarized))
        #expect(!JobState.imported.canTransition(to: .complete))
    }

    @Test func resumeRestoresCheckpointState() throws {
        var record = JobRecord(id: UUID(), title: "test", createdAt: .distantPast,
                               state: .imported, lastCheckpointState: .imported)
        try record.transition(to: .prepared)
        try record.transition(to: .transcribed)
        try record.transition(to: .interrupted)
        #expect(record.lastCheckpointState == .transcribed)
        try record.transition(to: record.lastCheckpointState)
        #expect(record.state == .transcribed)
    }

    @Test func illegalTransitionThrows() {
        var record = JobRecord(id: UUID(), title: "test", createdAt: .distantPast,
                               state: .imported, lastCheckpointState: .imported)
        #expect(throws: LonghandError.invalidStateTransition(from: .imported, to: .complete)) {
            try record.transition(to: .complete)
        }
    }
}

/// `JobPipeline.run` keeps a record in memory across a whole job and writes it
/// back at every stage boundary. Anything the user changes meanwhile has to
/// survive that write.
@Suite struct JobRecordUserFieldsTests {

    private func record(title: String, state: JobState = .transcribed,
                        paused: Bool? = nil) -> JobRecord {
        JobRecord(id: UUID(), title: title, createdAt: Date(), state: state,
                  lastCheckpointState: state, pausedByUser: paused)
    }

    @Test func mergingKeepsTheOnDiskTitleAndPauseFlag() {
        let inMemory = record(title: "mac-take-E10E8995", state: .diarized)
        let onDisk = record(title: "Wednesday standup", state: .transcribed, paused: true)

        let merged = inMemory.mergingUserFields(from: onDisk)
        #expect(merged.title == "Wednesday standup")
        #expect(merged.pausedByUser == true)
    }

    @Test func mergingKeepsThePipelinesOwnProgress() {
        let inMemory = record(title: "old", state: .diarized)
        // The on-disk copy is stale about everything the pipeline owns.
        let onDisk = record(title: "new", state: .imported)

        let merged = inMemory.mergingUserFields(from: onDisk)
        #expect(merged.state == .diarized, "the run knows the state, not the file")
        #expect(merged.lastCheckpointState == .diarized)
        #expect(merged.id == inMemory.id)
    }
}

/// Progress has to be honest (§17) and monotonic: the system's background
/// pill is one bar for a whole job, and a bar that jumps backwards reads as a
/// failure.
@Suite struct PipelineProgressTests {

    @Test func overallProgressNeverGoesBackwardsAcrossStages() {
        let sequence: [(JobStage, Double)] = [
            (.preparing, 0), (.downloadingModel, 0), (.downloadingModel, 1),
            (.transcribing, 0), (.transcribing, 0.5), (.transcribing, 1),
            (.diarizing, 0), (.diarizing, 1), (.merging, 0), (.identifying, 0), (.exporting, 0),
        ]
        let overall = sequence.map { PipelineProgress(stage: $0.0, fraction: $0.1).overallFraction }
        #expect(zip(overall, overall.dropFirst()).allSatisfy { $0 <= $1 },
                "each step must be at least as far along as the last: \(overall)")
        #expect(overall.last! < 1.0, "the bar completes when the job does, not before")
    }

    /// Transcription is the only stage that takes real time on a long
    /// recording, so it owns most of the bar.
    @Test func transcriptionDominatesTheBar() {
        let start = PipelineProgress(stage: .transcribing, fraction: 0).overallFraction
        let end = PipelineProgress(stage: .transcribing, fraction: 1).overallFraction
        #expect(end - start > 0.7)
    }

    @Test func shortStagesReportThemselvesIndeterminate() {
        #expect(PipelineProgress(stage: .merging, fraction: 0).isDeterminate == false)
        #expect(PipelineProgress(stage: .transcribing, fraction: 0.4, isDeterminate: true).isDeterminate)
    }
}
