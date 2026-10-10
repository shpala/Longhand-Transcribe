import Foundation
import LonghandKit

/// Filesystem-backed job listing. Large immutable artifacts live as files;
/// SQLite/GRDB or SwiftData indexing (§13.2) can replace this scan without
/// changing the on-disk layout.
public nonisolated enum JobStore {

    public static func allJobs() -> [(record: JobRecord, files: JobFiles)] {
        let root = ImportService.recordingsRoot
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var jobs: [(JobRecord, JobFiles)] = []
        for folder in folders {
            let files = JobFiles(root: folder)
            guard let record = try? AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job") else { continue }
            jobs.append((record, files))
        }
        return jobs.sorted { $0.0.createdAt > $1.0.createdAt }
    }

    public static func files(for jobID: UUID) -> JobFiles {
        JobFiles(recordingsRoot: ImportService.recordingsRoot, jobID: jobID)
    }

    /// Renames a job. Read-modify-write, because a run may be holding this
    /// record in memory; `JobPipeline.persist` merges the title back the same
    /// way, so neither side clobbers the other.
    public static func rename(jobID: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A person's title, from here on: no summary replaces it.
        try mutate(jobID: jobID) {
            $0.title = trimmed
            $0.titleOrigin = nil
        }
    }

    /// Names a recording after what was said in it, if nobody has named it
    /// yet: only a date-stamp placeholder, or an earlier generated title,
    /// gives way. Returns whether the title changed. Same read-modify-write
    /// as `rename`, and read as late as possible for the same reason: the
    /// model took seconds, and a rename may have landed meanwhile.
    @discardableResult
    public static func applyGeneratedTitle(_ title: String, jobID: UUID) throws -> Bool {
        guard let title = TranscriptSummary.usableTitle(title) else { return false }
        var changed = false
        try mutate(jobID: jobID) { record in
            guard record.acceptsGeneratedTitle, record.title != title else { return }
            record.title = title
            record.titleOrigin = .generated
            changed = true
        }
        return changed
    }

    /// Read-modify-write of one field, as late as possible.
    ///
    /// A running pipeline persists the record at every stage boundary, so a
    /// mutation built on a copy read earlier would write back a stale state
    /// and lastCheckpointState along with the field it meant to change. The
    /// read happens here, immediately before the write.
    static func mutate(jobID: UUID, _ change: (inout JobRecord) -> Void) throws {
        let files = self.files(for: jobID)
        guard var record = try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job") else {
            throw LonghandError.checkpointCorrupt(stage: "job")
        }
        change(&record)
        try AtomicFile.writeJSON(record, to: files.job)
    }

    /// Marks a job as stopped by the user rather than by the system, so it is
    /// not auto-resumed. Same read-modify-write discipline.
    public static func setPaused(_ paused: Bool, jobID: UUID) throws {
        try mutate(jobID: jobID) { $0.pausedByUser = paused ? true : nil }
    }

    public static func delete(jobID: UUID) {
        try? FileManager.default.removeItem(at: files(for: jobID).root)
    }

    /// Per-job disk usage for the §13.4 storage screen.
    public static func diskUsage(of files: JobFiles) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: files.root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
