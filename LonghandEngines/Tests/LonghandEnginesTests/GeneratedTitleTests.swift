import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// A model may name a recording that still carries its date stamp, and
/// nothing a person named. Runs against a job folder of its own under the
/// real recordings root, deleted on the way out.
@Suite struct GeneratedTitleTests {

    private func makeJob(title: String, origin: JobRecord.TitleOrigin?) throws -> UUID {
        let id = UUID()
        let files = JobStore.files(for: id)
        try files.createDirectory()
        var record = JobRecord(id: id, title: title, createdAt: Date(), state: .complete,
                               lastCheckpointState: .complete)
        record.titleOrigin = origin
        try AtomicFile.writeJSON(record, to: files.job)
        return id
    }

    private func record(_ id: UUID) throws -> JobRecord {
        try #require(try AtomicFile.readJSON(JobRecord.self, from: JobStore.files(for: id).job, stage: "job"))
    }

    @Test func aPlaceholderTakesTheSummarysTitle() throws {
        let id = try makeJob(title: "9 Oct 2026 at 16:17", origin: .placeholder)
        defer { JobStore.delete(jobID: id) }
        #expect(try JobStore.applyGeneratedTitle("“Budget for the spring launch.”", jobID: id))
        let after = try record(id)
        #expect(after.title == "Budget for the spring launch")
        #expect(after.titleOrigin == .generated)
    }

    @Test func aPersonsTitleIsNeverReplaced() throws {
        let id = try makeJob(title: "Call with the landlord", origin: nil)
        defer { JobStore.delete(jobID: id) }
        #expect(try !JobStore.applyGeneratedTitle("Rent negotiation", jobID: id))
        #expect(try record(id).title == "Call with the landlord")
    }

    @Test func aRenameEndsGeneration() throws {
        let id = try makeJob(title: "9 Oct 2026 at 16:17", origin: .placeholder)
        defer { JobStore.delete(jobID: id) }
        try JobStore.rename(jobID: id, to: "Standup")
        #expect(try record(id).titleOrigin == nil)
        #expect(try !JobStore.applyGeneratedTitle("Daily sync", jobID: id))
        #expect(try record(id).title == "Standup")
    }

    @Test func aGeneratedTitleMayBeRegenerated() throws {
        let id = try makeJob(title: "First draft", origin: .generated)
        defer { JobStore.delete(jobID: id) }
        #expect(try JobStore.applyGeneratedTitle("Second draft", jobID: id))
        #expect(try record(id).title == "Second draft")
    }

    @Test func anUnusableTitleChangesNothing() throws {
        let id = try makeJob(title: "9 Oct 2026 at 16:17", origin: .placeholder)
        defer { JobStore.delete(jobID: id) }
        #expect(try !JobStore.applyGeneratedTitle("   ", jobID: id))
        #expect(try !JobStore.applyGeneratedTitle(String(repeating: "x", count: 80), jobID: id))
        #expect(try record(id).title == "9 Oct 2026 at 16:17")
    }
}
