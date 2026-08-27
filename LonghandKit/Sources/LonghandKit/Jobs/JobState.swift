import Foundation

public enum JobStage: String, Codable, Sendable {
    // `loadingModel` is separate from `transcribing`: it is a fixed cost that
    // does not scale with the recording, and staging a 626 MB model onto the
    // Neural Engine can dominate a short take.
    case importing, preparing, downloadingModel, loadingModel, transcribing,
         diarizing, merging, identifying, exporting

    /// The order the work happens in, so a breakdown reads that way. `importing`
    /// is absent: it belongs to the import, not to a pipeline run, and never
    /// carries a measurement.
    public static let pipelineOrder: [JobStage] = [
        .preparing, .downloadingModel, .loadingModel, .transcribing,
        .diarizing, .merging, .identifying, .exporting,
    ]
}

/// Job state machine (§10). EXPORTED is not a state: export is a repeatable
/// action on a COMPLETE job. Re-entry edges into MERGED and IDENTIFIED make
/// "no ASR rerun required" (§15.3) a property of the machine.
public enum JobState: String, Codable, Sendable, CaseIterable {
    case imported = "IMPORTED"
    case prepared = "PREPARED"
    case transcribed = "TRANSCRIBED"
    case diarized = "DIARIZED"
    case merged = "MERGED"
    case identified = "IDENTIFIED"
    case complete = "COMPLETE"
    case interrupted = "INTERRUPTED"
    case failed = "FAILED"

    public var isActive: Bool {
        switch self {
        case .imported, .prepared, .transcribed, .diarized, .merged, .identified:
            return true
        case .complete, .interrupted, .failed:
            return false
        }
    }

    public func canTransition(to next: JobState) -> Bool {
        switch (self, next) {
        // Forward pipeline.
        case (.imported, .prepared),
             (.prepared, .transcribed),
             (.transcribed, .diarized),
             (.diarized, .merged),
             (.merged, .identified),
             (.merged, .complete),      // speaker ID is optional (§9)
             (.identified, .complete):
            return true
        // Diarization unavailable/failed: degrade to unlabelled merge (§17).
        case (.transcribed, .merged):
            return true
        // Re-entry edges (§10): re-merge after τ change, re-identify after new
        // enrollment, relabel/re-export on COMPLETE itself.
        case (.complete, .merged),
             (.complete, .identified),
             (.complete, .complete):
            return true
        // Explicit re-run with a different model/language is a user action
        // (§13.2); it re-enters at PREPARED and re-runs inference stages.
        case (.complete, .prepared):
            return true
        // Any active state may be interrupted or fail.
        case _ where self.isActive && (next == .interrupted || next == .failed):
            return true
        // Resume/retry restores the last durable checkpoint's state (§10, §17).
        case (.interrupted, _), (.failed, _):
            return next.isActive
        default:
            return false
        }
    }
}

/// Durable job record persisted alongside checkpoints.
public struct JobRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var state: JobState
    /// Last state whose checkpoint is durable; resume target after INTERRUPTED/FAILED.
    public var lastCheckpointState: JobState
    public var duration: TimeInterval?
    public var language: String?
    public var errorDescription: String?
    /// Visible degradations (§17): a lesser transcript is never silent.
    public var degradations: [Degradation]
    /// The user stopped this job rather than the system interrupting it. Both
    /// land in INTERRUPTED with checkpoints intact, but only a system
    /// interruption should resume on its own. Optional so existing `job.json`
    /// files keep decoding: the synthesized `init(from:)` ignores defaults.
    public var pausedByUser: Bool?
    /// Seconds per stage from the last run, keyed by `JobStage`'s raw value, so
    /// "why is Hebrew slow" has a measurement behind it and model load is
    /// distinguishable from decoding. Accumulated across a resumed run, since
    /// a job that stopped and continued really did spend both. Optional for
    /// the same decoding reason as `pausedByUser`.
    public var stageSeconds: [String: TimeInterval]?
    /// The same measurement for the most recent run alone.
    ///
    /// `stageSeconds` is a total across runs and is right to be: a job that
    /// stopped and continued really did load the model twice. It is the wrong
    /// number to compare with, though, because it belongs to no single sitting.
    /// The phone's own record read 5:26 of model load after a failed run and a
    /// successful one, when the load that produced the transcript took 2:26.
    /// Optional for the same decoding reason as `pausedByUser`.
    public var lastRunStageSeconds: [String: TimeInterval]?
    /// How many runs contributed time. Nil on a record written before this
    /// existed, and 1 for the overwhelmingly common single-run job.
    public var processingRuns: Int?

    public init(id: UUID, title: String, createdAt: Date, state: JobState,
                lastCheckpointState: JobState, duration: TimeInterval? = nil,
                language: String? = nil, errorDescription: String? = nil,
                degradations: [Degradation] = [], pausedByUser: Bool? = nil,
                stageSeconds: [String: TimeInterval]? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.state = state
        self.lastCheckpointState = lastCheckpointState
        self.duration = duration
        self.language = language
        self.errorDescription = errorDescription
        self.degradations = degradations
        self.pausedByUser = pausedByUser
        self.stageSeconds = stageSeconds
    }

    /// Adds a stage's elapsed time to whatever a previous run recorded.
    public mutating func recordStage(_ stage: JobStage, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        var seconds = seconds + (stageSeconds?[stage.rawValue] ?? 0)
        // Rounded at the storage boundary: this file gets read by a person.
        seconds = (seconds * 1000).rounded() / 1000
        stageSeconds = (stageSeconds ?? [:]).merging([stage.rawValue: seconds]) { _, new in new }
    }

    public var totalProcessingSeconds: TimeInterval? {
        guard let stageSeconds, !stageSeconds.isEmpty else { return nil }
        return stageSeconds.values.reduce(0, +)
    }

    /// True when the totals are a sum over sittings rather than one run's cost,
    /// which is the difference between a number to read and a number to compare.
    public var wasResumed: Bool { (processingRuns ?? 1) > 1 }

    /// The per-stage figures worth comparing: one run's, falling back to the
    /// totals for a record written before the distinction existed.
    public var comparableStageSeconds: [String: TimeInterval]? {
        lastRunStageSeconds ?? stageSeconds
    }

    /// Waiting for the user, not an interruption to recover from.
    public var isPaused: Bool { state == .interrupted && pausedByUser == true }

    /// User-owned fields from `other`, pipeline-owned fields from `self`.
    /// `JobPipeline.run` holds a record in memory for the length of a job and
    /// re-persists it at every stage boundary, so a rename or a pause landing
    /// meanwhile would otherwise be clobbered.
    public func mergingUserFields(from other: JobRecord) -> JobRecord {
        var merged = self
        merged.title = other.title
        merged.pausedByUser = other.pausedByUser
        return merged
    }

    public mutating func transition(to next: JobState) throws {
        guard state.canTransition(to: next) else {
            throw LonghandError.invalidStateTransition(from: state, to: next)
        }
        state = next
        if next.isActive || next == .complete {
            lastCheckpointState = next
        }
    }
}
