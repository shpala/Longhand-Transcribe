import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// When the library should stop transcribing for the device's sake.
@Suite struct ProcessingHoldTests {

    @Test func heatHoldsRegardlessOfTheLowPowerSetting() {
        #expect(ProcessingHold.current(lowPowerMode: false, thermalState: .serious, pausesInLowPowerMode: false) == .thermal)
        #expect(ProcessingHold.current(lowPowerMode: true, thermalState: .critical, pausesInLowPowerMode: false) == .thermal)
        #expect(ProcessingHold.current(lowPowerMode: false, thermalState: .fair, pausesInLowPowerMode: true) == nil)
    }

    @Test func lowPowerModeHoldsOnlyWhenAskedTo() {
        #expect(ProcessingHold.current(lowPowerMode: true, thermalState: .nominal, pausesInLowPowerMode: true) == .lowPowerMode)
        #expect(ProcessingHold.current(lowPowerMode: true, thermalState: .nominal, pausesInLowPowerMode: false) == nil)
        #expect(ProcessingHold.current(lowPowerMode: false, thermalState: .nominal, pausesInLowPowerMode: true) == nil)
    }

    /// A hold stops the running job at its next checkpoint without the
    /// user's pause flag, so lifting it brings the job back by itself.
    @MainActor
    @Test func aHoldStopsARunningJobAndLiftingItResumesTheJob() async throws {
        // Under the library root: the model lists and resumes what is there,
        // not a folder in the temporary directory.
        let staged = try seededJob()
        let record = try #require(try AtomicFile.readJSON(JobRecord.self, from: staged.job, stage: "job"))
        let files = JobStore.files(for: record.id)
        try FileManager.default.createDirectory(at: files.root.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged.root, to: files.root)
        defer { try? FileManager.default.removeItem(at: files.root) }

        // A pipeline that waits until told, so the hold has something to stop.
        // The wait honours cancellation the way the real stages do at their
        // boundaries.
        let gate = Gate()
        let model = JobLibraryModel(backgroundWrapper: { _, _, progress, work in
            try await gate.wait()
            try await work(progress)
        }, observesSystemState: false)
        model.refresh()
        model.start(jobID: record.id)
        try await waitUntil { model.runningJobs.contains(record.id) }

        model.apply(hold: .thermal)
        #expect(model.processingHold == .thermal)
        try await waitUntil { !model.runningJobs.contains(record.id) }
        let stopped = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        #expect(stopped.pausedByUser != true, "a system hold is not the user's pause")

        // While held, nothing starts.
        model.start(jobID: record.id)
        try await waitUntil { !model.runningJobs.contains(record.id) }
        #expect(!model.runningJobs.contains(record.id))

        await gate.open()
        model.apply(hold: nil)
        #expect(model.processingHold == nil)
        try await waitUntil { model.job(record.id)?.state == .complete }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

        func wait() async throws {
            if isOpen { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.continuation.resume() }
            waiters = []
        }

        private func cancel(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}
