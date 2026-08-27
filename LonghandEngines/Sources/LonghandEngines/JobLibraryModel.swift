import Foundation
import Observation
import LonghandKit

/// Admits one pipeline run at a time.
///
/// Resuming after a kill, draining a batch of watch takes and a multi-file
/// import all start several jobs at once, and each run loads its own 626 MB (or
/// 947 MB) model. On a phone that is a jetsam, and the work is ANE-bound
/// anyway, so sequencing them costs nothing in aggregate.
///
/// Waiting is cancellable. A job paused while it queued used to hold its place
/// until every job ahead of it had finished, which on a long recording is an
/// hour of a row saying "Stopping…", and a resume in that hour did nothing
/// because the job still counted as running.
actor PipelineGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Throws `CancellationError` when the task is cancelled while waiting.
    /// A caller that returns normally holds the gate and must `release` it.
    func acquire() async throws {
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before it got here: the handler below has already
                // run, found nothing to remove, and will not run again.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    /// For tests, which need to know a task has actually joined the queue
    /// rather than guess with a sleep.
    var waitingCount: Int { waiters.count }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Already handed the gate by `release` is fine: the caller then holds it,
    /// sees the cancellation itself, and releases as usual.
    private func withdraw(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@Observable
@MainActor
public final class JobLibraryModel {

    /// Shared across every model instance in the process, which matters on
    /// macOS where Settings and the library both hold one.
    static let pipelineGate = PipelineGate()

    public typealias BackgroundWrapper = @Sendable (
        _ jobID: UUID,
        _ title: String,
        _ progress: @escaping ProgressSink,
        _ work: @escaping @Sendable (@escaping ProgressSink) async throws -> Void
    ) async throws -> Void

    public var jobs: [JobRecord] = []
    public var progressByJob: [UUID: PipelineProgress] = [:]
    public var runningJobs: Set<UUID> = []
    /// An unrecognized file that may be raw PCM (§5.5), awaiting confirmation.
    public var pendingRawPCMJob: JobRecord?
    /// A job stopped at the §4.2.3(ii) consent point.
    public var pendingModelDownload: PendingModelDownload?
    /// A failure with no job row to live on, surfaced rather than swallowed (§17).
    public var errorAlert: ErrorAlert?

    public struct ErrorAlert: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public let message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    private let backgroundWrapper: BackgroundWrapper
    private let onRefresh: (JobRecord?) -> Void
    /// So a companion device can follow a job rather than hearing only about
    /// its start and finish.
    public var onProgress: ((UUID, PipelineProgress) -> Void)?

    private var engines: JobPipeline.Engines?
    /// What the cached engines were built with: a Settings change has to
    /// rebuild them, or "Maximum accuracy" silently keeps using turbo.
    private var enginesWhisperVariant: WhisperModelVariant?
    /// Handles, not just IDs, so a job can actually be stopped.
    private var runTasks: [UUID: Task<Void, Error>] = [:]
    /// Jobs actually inside `run`. `runningJobs` is set optimistically by
    /// `start` so a retried row updates at once, and guarding on it here would
    /// make `run` refuse to do anything.
    private var activeRuns: Set<UUID> = []

    public init(backgroundWrapper: @escaping BackgroundWrapper = { _, _, progress, work in
                    try await work(progress)
                },
                onRefresh: @escaping (JobRecord?) -> Void = { _ in }) {
        self.backgroundWrapper = backgroundWrapper
        self.onRefresh = onRefresh
    }

    // MARK: - Library

    public func refresh() {
        jobs = JobStore.allJobs().map(\.record)
        onRefresh(jobs.first)
    }

    public func job(_ jobID: UUID) -> JobRecord? {
        jobs.first { $0.id == jobID }
    }

    /// Total on-disk size of all job folders, for the Settings screen (§13.4).
    public func totalDiskUsage() -> Int64 {
        JobStore.allJobs().reduce(into: Int64(0)) { $0 += JobStore.diskUsage(of: $1.files) }
    }

    public static func describe(_ error: Error) -> String {
        (error as? LonghandError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Import

    /// `securityScoped` is true for document-picker URLs; false for files the
    /// app created itself (in-app recordings). `deleteSourceAfterImport`
    /// removes a temporary source once the protected copy exists.
    public func importRecording(from url: URL, securityScoped: Bool = true,
                                deleteSourceAfterImport: Bool = false,
                                declaredLanguage: String?, expectedSpeakerCount: Int?,
                                location: CapturedLocation? = nil,
                                title: String? = nil,
                                sourceTakeID: String? = nil,
                                markers: [TimeInterval] = []) {
        Task {
            do {
                let imported = try await Task.detached {
                    try await ImportService.importRecording(from: url, securityScoped: securityScoped,
                                                            declaredLanguage: declaredLanguage,
                                                            expectedSpeakerCount: expectedSpeakerCount,
                                                            location: location,
                                                            title: title,
                                                            sourceTakeID: sourceTakeID,
                                                            markers: markers)
                }.value
                if deleteSourceAfterImport {
                    try? FileManager.default.removeItem(at: url)
                }
                refresh()
                if imported.record.state != .failed {
                    await run(jobID: imported.record.id, userConfirmedRawPCM: false,
                      userConfirmedModelDownload: false)
                }
            } catch {
                // No job row to live on, so it goes in an alert (§17).
                refresh()
                errorAlert = ErrorAlert(title: "Couldn't Import Recording",
                                        message: Self.describe(error))
            }
        }
    }

    public func confirmRawPCM(jobID: UUID) {
        pendingRawPCMJob = nil
        // Raising the question parked the job; answering it un-parks.
        try? JobStore.setPaused(false, jobID: jobID)
        start(jobID: jobID, userConfirmedRawPCM: true)
    }

    // MARK: - Running

    /// The job paused at a model-download prompt, plus what it wants to fetch.
    public struct PendingModelDownload: Identifiable, Sendable, Equatable {
        public let jobID: UUID
        public let asset: String
        public let bytes: Int64
        public var id: UUID { jobID }
        public var sizeText: String { ByteCountFormatter().string(fromByteCount: bytes) }
    }

    /// Takes the pending value rather than reading it back: the caller is a
    /// confirmation dialog whose `isPresented` setter clears it on dismissal,
    /// and that can land before the button's action.
    public func confirmModelDownload(_ pending: PendingModelDownload? = nil) {
        guard let pending = pending ?? pendingModelDownload else { return }
        pendingModelDownload = nil
        // "Not now" may have parked it; agreeing un-parks it.
        try? JobStore.setPaused(false, jobID: pending.jobID)
        start(jobID: pending.jobID, userConfirmedModelDownload: true)
    }

    /// "Not now" parks the job, so `resumeUnfinished` does not pick it up and
    /// ask again on the next library appearance.
    public func cancelModelDownload(_ pending: PendingModelDownload? = nil) {
        guard let pending = pending ?? pendingModelDownload else {
            pendingModelDownload = nil
            return
        }
        pendingModelDownload = nil
        try? JobStore.setPaused(true, jobID: pending.jobID)
        refresh()
    }

    public func start(jobID: UUID, userConfirmedRawPCM: Bool = false,
                      userConfirmedModelDownload: Bool = false) {
        guard !runningJobs.contains(jobID) else { return }
        // Here, not inside the async `run`: a retried row would otherwise keep
        // saying "Couldn't transcribe" until the task got scheduled, and a
        // second tap could start the same job twice.
        runningJobs.insert(jobID)
        Task { [weak self] in
            guard let self else { return }
            await self.run(jobID: jobID, userConfirmedRawPCM: userConfirmedRawPCM,
                           userConfirmedModelDownload: userConfirmedModelDownload)
        }
    }

    public func run(jobID: UUID, userConfirmedRawPCM: Bool,
                    userConfirmedModelDownload: Bool = false) async {
        guard !activeRuns.contains(jobID) else { return }
        activeRuns.insert(jobID)
        runningJobs.insert(jobID)
        defer {
            activeRuns.remove(jobID)
            runningJobs.remove(jobID)
            runTasks[jobID] = nil
            progressByJob[jobID] = nil
            // A pause that lost the race with completion would otherwise leave
            // the row saying "Stopping…" forever.
            if let record = try? AtomicFile.readJSON(JobRecord.self,
                                                     from: JobStore.files(for: jobID).job, stage: "job") ?? nil,
               record.pausedByUser == true, !record.state.isActive, record.state != .interrupted {
                try? JobStore.setPaused(false, jobID: jobID)
            }
            refresh()
        }

        let files = JobStore.files(for: jobID)
        let whisperVariant = WhisperModelVariant.current
        if engines == nil || enginesWhisperVariant != whisperVariant {
            engines = await JobPipeline.makeDefaultEngines(whisperVariant: whisperVariant)
            enginesWhisperVariant = whisperVariant
        }
        guard let engines else { return }
        // Building the engines takes seconds, and a pause in that window has
        // nothing to cancel yet.
        if let record = (try? AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job")) ?? nil,
           record.pausedByUser == true {
            return
        }

        let sink: ProgressSink = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.progressByJob[jobID] = update
                self?.onProgress?(jobID, update)
            }
        }
        let title = job(jobID)?.title ?? "Recording"
        let wrapper = backgroundWrapper

        // Its own task, so `pause` has something to cancel. Registering the
        // handle in `start` is not enough: an import awaits `run` directly, as
        // does the UI-test hook.
        let work = Task { @MainActor in
            try await Self.pipelineGate.acquire()
            defer { Task { await Self.pipelineGate.release() } }
            // A job cancelled while it queued should not then start.
            try Task.checkCancellation()
            try await wrapper(jobID, title, sink) { innerSink in
                _ = try await JobPipeline.run(files: files, engines: engines,
                                              profiles: SpeakerProfileStore.load(),
                                              userConfirmedRawPCM: userConfirmedRawPCM,
                                              userConfirmedModelDownload: userConfirmedModelDownload,
                                              progress: innerSink)
            }
        }
        runTasks[jobID] = work

        do {
            try await work.value
        } catch {
            // A job stopped on a question is parked, not merely interrupted:
            // otherwise the row promises "will resume", `resumeUnfinished`
            // obliges, hits the same gate, and asks again.
            if let longhand = error as? LonghandError, longhand.isAwaitingAnswer {
                try? JobStore.setPaused(true, jobID: jobID)
            }
            if case LonghandError.unsupportedMedia(_, rawPCMCandidate: true) = error {
                refresh()
                pendingRawPCMJob = job(jobID)
            } else if case let LonghandError.modelDownloadRequired(asset, bytes) = error {
                refresh()
                pendingModelDownload = PendingModelDownload(jobID: jobID, asset: asset, bytes: bytes)
            }
        }
    }

    /// Stops a running job, keeping its checkpoints. The flag is written
    /// before the cancel so the pipeline's own INTERRUPTED write merges it in
    /// rather than racing it (see `JobRecord.mergingUserFields`).
    public func pause(jobID: UUID) {
        do {
            try JobStore.setPaused(true, jobID: jobID)
        } catch {
            errorAlert = ErrorAlert(title: "Couldn't Pause", message: Self.describe(error))
            return
        }
        runTasks[jobID]?.cancel()
        refresh()
    }

    /// Picks the job back up from its last durable checkpoint.
    public func resume(jobID: UUID) {
        try? JobStore.setPaused(false, jobID: jobID)
        refresh()
        start(jobID: jobID)
    }

    public func rename(jobID: UUID, to title: String) {
        do {
            try JobStore.rename(jobID: jobID, to: title)
            refresh()
        } catch {
            errorAlert = ErrorAlert(title: "Couldn't Rename Recording",
                                    message: Self.describe(error))
        }
    }

    /// Picks up everything in an active state that no task owns, not just the
    /// INTERRUPTED rows: a take imported while the app was woken in the
    /// background can sit at IMPORTED with nobody to start it. User-paused
    /// jobs are left alone.
    public func resumeUnfinished() {
        for job in jobs where !runningJobs.contains(job.id) {
            guard job.state.isActive || job.state == .interrupted else { continue }
            guard !job.isPaused else { continue }
            start(jobID: job.id)
        }
    }

    // MARK: - Deletion and re-runs

    public func delete(jobID: UUID) {
        guard let running = runTasks[jobID] else {
            JobStore.delete(jobID: jobID)
            refresh()
            return
        }
        // Cancellation is only observed at stage boundaries and an atomic
        // write recreates a missing directory, so deleting under a live run
        // resurrects it. Hide the row now, delete once it stops.
        running.cancel()
        jobs.removeAll { $0.id == jobID }
        Task { [weak self] in
            _ = await running.result
            JobStore.delete(jobID: jobID)
            self?.refresh()
        }
    }

    /// Explicit re-run with a different language (§13.2): resets checkpoints
    /// and reprocesses from the retained original.
    public func retranscribe(jobID: UUID, language: String?) {
        // The transcript screen offers this whenever a transcript exists, which
        // includes while the job is running.
        guard !runningJobs.contains(jobID) else {
            errorAlert = ErrorAlert(title: "Still Transcribing",
                                    message: "Pause this recording before re-transcribing it.")
            return
        }
        do {
            try JobPipeline.retranscribe(files: JobStore.files(for: jobID), newLanguage: language)
            refresh()
            start(jobID: jobID)
        } catch {
            refresh()
            errorAlert = ErrorAlert(title: "Couldn't Re-transcribe",
                                    message: Self.describe(error))
        }
    }

    /// Re-runs identification from the stored diarization checkpoint (§10
    /// COMPLETE→IDENTIFIED re-entry). False when there is no checkpoint to
    /// match against; throws on a corrupt one so callers can alert.
    @discardableResult
    public func reidentify(jobID: UUID) throws -> Bool {
        let files = JobStore.files(for: jobID)
        guard let diarization = try AtomicFile.readJSON(DiarizationResult.self, from: files.diarization, stage: "DIARIZED") else {
            return false
        }
        try JobPipeline.reidentify(files: files, profiles: SpeakerProfileStore.load(),
                                   diarizerModelIdentifier: diarization.modelIdentifier)
        return true
    }

    /// Applies the current voice profiles to every COMPLETE job. Failures are
    /// counted and returned (§17), never silent.
    public func reidentifyAll() async -> (rematched: Int, failed: Int) {
        var rematched = 0, failed = 0
        for job in jobs where job.state == .complete {
            // Each pass re-reads checkpoints and rewrites five exports; without
            // a suspension point the library does all of it in one main-actor
            // hop and the UI freezes for the duration.
            await Task.yield()
            do {
                if try reidentify(jobID: job.id) { rematched += 1 }
            } catch {
                failed += 1
            }
        }
        refresh()
        return (rematched, failed)
    }
}
