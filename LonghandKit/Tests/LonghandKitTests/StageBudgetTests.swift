import Foundation
import Testing
@testable import LonghandKit

/// The budgets exist to catch a stage that is doing something other than what
/// it claims. They are only worth having if they stay quiet: a note that fires
/// on a healthy run teaches the reader to ignore the one that matters, which
/// is the failure mode this is meant to fix, not cause.
@Suite struct StageBudgetTests {

    private func record(duration: TimeInterval?,
                        _ stages: [JobStage: TimeInterval]) -> JobRecord {
        var record = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                               state: .complete, lastCheckpointState: .complete,
                               duration: duration)
        for (stage, seconds) in stages { record.recordStage(stage, seconds: seconds) }
        return record
    }

    /// Measured on the owner's iPhone 16 Pro Max: the run that failed spent
    /// 179.5 s loading the model, and the run that succeeded spent 146.4 s.
    /// Thirty seconds apart is not a threshold, so `loadingModel` carries no
    /// bound and neither run is called a fault.
    @Test func aSlowModelLoadIsNotCalledAFault() {
        let failed = record(duration: 62.01, [.preparing: 0.739, .loadingModel: 179.474])
        let healthy = record(duration: 62.01, [.preparing: 1.116, .loadingModel: 146.445,
                                               .transcribing: 7.09, .diarizing: 6.715])
        #expect(StageBudget.implausibleStages(in: failed).isEmpty)
        #expect(StageBudget.implausibleStages(in: healthy).isEmpty)
        #expect(StageBudget.limit(for: .loadingModel, recordingSeconds: 62) == nil)
    }

    /// A failure still says where the time went. That needs no budget: it is a
    /// fact about the run, not a claim that anything misbehaved.
    @Test func theDominantStageOfARunIsNamed() {
        let dominant = StageBudget.dominantStage(in: [.preparing: 0.739, .loadingModel: 179.474])
        #expect(dominant?.stage == .loadingModel)
        #expect(dominant?.seconds == 179.474)
    }

    /// No stage dominates, so there is nothing worth singling out.
    @Test func anEvenlySpreadRunNamesNoStage() {
        #expect(StageBudget.dominantStage(in: [.transcribing: 30, .diarizing: 28, .preparing: 25]) == nil)
    }

    /// A run that took no time at all has no story to tell about where it went.
    @Test func aFastRunNamesNoStage() {
        #expect(StageBudget.dominantStage(in: [.merging: 0.01, .exporting: 0.006]) == nil)
    }

    @Test func anOrdinaryRunSaysNothing() {
        let job = record(duration: 600, [.preparing: 2.1, .loadingModel: 148,
                                         .transcribing: 240, .diarizing: 45,
                                         .merging: 0.3, .identifying: 0.2, .exporting: 0.4])
        #expect(StageBudget.implausibleStages(in: job).isEmpty)
        #expect(StageBudget.worstOverrun(in: job) == nil)
    }

    /// A short take legitimately spends longer loading the model than decoding
    /// the audio, which §6.1 says outright. The floor is what keeps that from
    /// reading as a fault.
    @Test func aShortTakeIsNotPunishedForFixedOverheads() {
        let job = record(duration: 8, [.preparing: 3, .transcribing: 20, .diarizing: 15])
        #expect(StageBudget.implausibleStages(in: job).isEmpty)
    }

    /// A download takes as long as the network takes. There is no honest bound,
    /// so there is no claim.
    @Test func aDownloadIsNeverCalledSlow() {
        let job = record(duration: 60, [.downloadingModel: 3600])
        #expect(StageBudget.implausibleStages(in: job).isEmpty)
        #expect(StageBudget.limit(for: .downloadingModel, recordingSeconds: 60) == nil)
    }

    /// A job that failed before the duration was known must not be measured
    /// against a duration of nothing. Fixed-cost stages still have a bound.
    @Test func anUnknownDurationSuppressesOnlyTheScaledStages() {
        #expect(StageBudget.limit(for: .transcribing, recordingSeconds: nil) == nil)
        #expect(StageBudget.limit(for: .preparing, recordingSeconds: 0) == nil)
        #expect(StageBudget.limit(for: .exporting, recordingSeconds: nil) == 60)

        let job = record(duration: nil, [.transcribing: 9_000, .exporting: 300])
        #expect(StageBudget.implausibleStages(in: job) == [.exporting],
                "an unmeasurable stage is not evidence of anything")
    }

    /// Transcription scales with the recording, so the same 10 minutes is fine
    /// for an hour of audio and pathological for ten seconds of it.
    @Test func scaledStagesAreJudgedAgainstTheRecording() {
        #expect(!StageBudget.isImplausible(stage: .transcribing, seconds: 600, recordingSeconds: 3600))
        #expect(StageBudget.isImplausible(stage: .transcribing, seconds: 600, recordingSeconds: 10))
    }

    @Test func overrunsAreReportedInPipelineOrder() {
        let job = record(duration: 30, [.merging: 300, .exporting: 120])
        #expect(StageBudget.implausibleStages(in: job) == [.merging, .exporting])
        // The slowest is the one worth naming, not the first.
        #expect(StageBudget.worstOverrun(in: job)?.stage == .merging)
    }

    @Test func aRunWithNoTimingsIsNotJudged() {
        let job = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                            state: .complete, lastCheckpointState: .complete, duration: 60)
        #expect(StageBudget.implausibleStages(in: job).isEmpty)
    }

    /// One formatter, so a failure message and the timings breakdown cannot
    /// describe the same measurement two different ways.
    @Test func elapsedTimeReadsTheSameEverywhere() {
        #expect(StageBudget.durationText(0.739) == "0.7s")
        #expect(StageBudget.durationText(59.9) == "59.9s")
        #expect(StageBudget.durationText(179.474) == "2:59")
        #expect(StageBudget.durationText(3600) == "60:00")
    }
}

/// `stageSeconds` totals across sittings, which is right for "what did this job
/// cost" and wrong for "how long does this stage take". The phone's own record
/// held 5:26 of model load after a failed run and a successful one, when the
/// load that produced the transcript took 2:26.
@Suite struct ResumedRunAccountingTests {

    private func record(runs: Int?, total: [JobStage: TimeInterval],
                        lastRun: [JobStage: TimeInterval]?) -> JobRecord {
        var record = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                               state: .complete, lastCheckpointState: .complete, duration: 62)
        for (stage, seconds) in total { record.recordStage(stage, seconds: seconds) }
        record.lastRunStageSeconds = lastRun.map { runs in
            runs.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        }
        record.processingRuns = runs
        return record
    }

    /// The real shape, reconstructed from the phone.
    @Test func aResumedJobIsJudgedOnOneRunNotTheTotal() {
        let job = record(runs: 2,
                         total: [.loadingModel: 325.919, .exporting: 120],
                         lastRun: [.loadingModel: 146.445, .exporting: 0.006])
        #expect(job.wasResumed)
        #expect(job.comparableStageSeconds?["exporting"] == 0.006)
        // Export overran only by being summed over two sittings.
        #expect(StageBudget.implausibleStages(in: job).isEmpty,
                "a job must not be called slow for having been interrupted")
    }

    /// The total is still the total: it is the honest answer to what the job
    /// cost, and the breakdown keeps showing it.
    @Test func theTotalStillCountsEverySitting() {
        let job = record(runs: 2,
                         total: [.loadingModel: 325.919],
                         lastRun: [.loadingModel: 146.445])
        #expect(job.totalProcessingSeconds == 325.919)
    }

    /// A single run is the overwhelmingly common case and reads unchanged.
    @Test func aSingleRunJobIsNotLabelledAsResumed() {
        let job = record(runs: 1, total: [.loadingModel: 12], lastRun: [.loadingModel: 12])
        #expect(!job.wasResumed)
    }

    /// A record written before any of this existed has no per-run figures, so
    /// the totals stand in rather than the job going unmeasured.
    @Test func aLegacyRecordFallsBackToItsTotals() {
        let job = record(runs: nil, total: [.exporting: 300], lastRun: nil)
        #expect(!job.wasResumed)
        #expect(job.comparableStageSeconds?["exporting"] == 300)
        #expect(StageBudget.implausibleStages(in: job) == [.exporting])
    }

    @Test func perRunFiguresSurviveTheRoundTrip() throws {
        let job = record(runs: 3, total: [.transcribing: 90], lastRun: [.transcribing: 30])
        let decoded = try JSONDecoder().decode(JobRecord.self, from: JSONEncoder().encode(job))
        #expect(decoded.processingRuns == 3)
        #expect(decoded.lastRunStageSeconds?["transcribing"] == 30)
        #expect(decoded.stageSeconds?["transcribing"] == 90)
    }
}
