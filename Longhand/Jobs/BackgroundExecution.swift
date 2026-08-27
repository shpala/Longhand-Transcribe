import Foundation
import BackgroundTasks
import LonghandKit
import LonghandEngines

/// §11.1 foreground-first policy: a job starts in the foreground and claims a
/// continued-processing task so it survives backgrounding, with the system's
/// pill for visible progress. A refused task means the work runs inline and
/// pauses with the app; checkpoints (§10) make both paths safe, and expiration
/// cancels into INTERRUPTED rather than corrupting anything.
///
/// Default resources only (CPU + ANE): background GPU needs the
/// `continued-processing.gpu` entitlement, which requires Apple approval.
nonisolated final class BackgroundExecutionCoordinator: @unchecked Sendable {

    static let shared = BackgroundExecutionCoordinator()
    static let identifierPrefix = "com.shpala.Longhand.processing."

    private let lock = NSLock()
    private var pending: [String: @Sendable (BGContinuedProcessingTask) -> Void] = [:]
    private var attempted = false
    /// Submitting without a successful registration is an uncatchable ObjC
    /// assertion rather than a thrown error, so the inline fallback keys off
    /// this and never off submit failing.
    private var registrationSucceeded = false

    /// BGTaskScheduler requires registration before the app finishes launching.
    func registerLaunchHandler() {
        lock.lock()
        defer { lock.unlock() }
        guard !attempted else { return }
        attempted = true
        registrationSucceeded = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifierPrefix + "*", using: nil
        ) { task in
            guard let task = task as? BGContinuedProcessingTask,
                  let start = Self.shared.claim(task.identifier) else {
                task.setTaskCompleted(success: false)
                return
            }
            start(task)
        }
    }

    private var canSubmit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registrationSucceeded
    }

    private func claim(_ identifier: String) -> (@Sendable (BGContinuedProcessingTask) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: identifier)
    }

    private func stash(_ identifier: String, _ start: @escaping @Sendable (BGContinuedProcessingTask) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending[identifier] = start
    }

    private func unstash(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeValue(forKey: identifier)
    }

    /// Runs `work` under a continued-processing task when the system grants
    /// one, inline otherwise; rethrows the work's error either way.
    func run(jobID: UUID, title: String,
             progress outerProgress: @escaping ProgressSink,
             work: @escaping @Sendable (@escaping ProgressSink) async throws -> Void) async throws {
        guard canSubmit else {
            // Simulator or registration refusal: §11.1 foreground-only fallback.
            try await work(outerProgress)
            return
        }
        let identifier = Self.identifierPrefix + jobID.uuidString
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: String(localized: "Preparing…"))
        request.strategy = .fail   // no grant → run inline immediately

        // A continuation does not carry cancellation into the Task started
        // inside it, so the handle is boxed and cancelled explicitly.
        let inner = TaskBox()
        try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let start: @Sendable (BGContinuedProcessingTask) -> Void = { task in
                // Continued tasks MUST report progress (NSProgressReporting).
                task.progress.totalUnitCount = 1000
                let lastStage = StageBox()
                let pill = ProgressRatchet()
                // BGContinuedProcessingTask is not Sendable, but this closure
                // and the expiration handler are its only users and both run on
                // the system's callback queue for this one task.
                let taskBox = UncheckedBox(task)
                let job = Task {
                    do {
                        try await work { update in
                            outerProgress(update)
                            // One bar for the whole job, so it takes the
                            // whole-job fraction: the per-stage one would jump
                            // back to zero at every stage change.
                            taskBox.value.progress.completedUnitCount =
                                Int64(pill.advance(to: update.overallFraction) * 1000)
                            if lastStage.replace(update.stage) {
                                taskBox.value.updateTitle(title, subtitle: Self.subtitle(for: update))
                            }
                        }
                        taskBox.value.setTaskCompleted(success: true)
                        continuation.resume()
                    } catch {
                        taskBox.value.setTaskCompleted(success: false)
                        continuation.resume(throwing: error)
                    }
                }
                inner.store(job)
                // Expiration → cooperative cancel → pipeline checkpoints and
                // marks INTERRUPTED (§10); resume happens on next run. A user
                // pause takes the same path, via the cancellation handler.
                task.expirationHandler = { job.cancel() }
            }

            stash(identifier, start)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                // Unsupported (simulator) or refused (system load): the §11.1
                // fallback, same work with a foreground-only lifetime.
                unstash(identifier)
                let fallback = Task {
                    do {
                        try await work(outerProgress)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                inner.store(fallback)
            }
        }
        } onCancel: {
            inner.cancel()
        }
    }

    /// Holds whichever Task is currently doing the work, so cancellation can
    /// reach across the continuation boundary.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func store(_ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                task.cancel()   // cancelled before the task existed
            } else {
                self.task = task
            }
        }

        func cancel() {
            lock.lock()
            let task = self.task
            cancelled = true
            lock.unlock()
            task?.cancel()
        }
    }

    /// Carries a non-Sendable system object into the one task that owns it.
    private struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Keeps the system pill monotonic; a bar that retreats reads as failure.
    private final class ProgressRatchet: @unchecked Sendable {
        private let lock = NSLock()
        private var highest: Double = 0
        func advance(to value: Double) -> Double {
            lock.lock()
            defer { lock.unlock() }
            highest = max(highest, min(1, max(0, value)))
            return highest
        }
    }

    private final class StageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stage: JobStage?
        /// Returns true when the stage actually changed.
        func replace(_ new: JobStage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard stage != new else { return false }
            stage = new
            return true
        }
    }

    private static func subtitle(for update: PipelineProgress) -> String {
        if update.stage == .loadingModel, update.isFirstModelLoad {
            return String(localized: "Preparing speech model (one-time)…")
        }
        return switch update.stage {
        case .importing: String(localized: "Importing…")
        case .preparing: String(localized: "Preparing audio…")
        case .downloadingModel: String(localized: "Downloading speech model…")
        case .loadingModel: String(localized: "Loading speech model…")
        case .transcribing: String(localized: "Transcribing…")
        case .diarizing: String(localized: "Detecting speakers…")
        case .merging: String(localized: "Merging…")
        case .identifying: String(localized: "Identifying speakers…")
        case .exporting: String(localized: "Exporting…")
        }
    }
}
