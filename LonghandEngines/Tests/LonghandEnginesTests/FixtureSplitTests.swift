import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// The committed seed fixture is what the UI suites cut at; if its words
/// stop joining into its turn text, Split Passage silently disappears there.
@Suite struct FixtureSplitTests {
    @MainActor
    @Test func theSeedFixturesFirstTurnIsSplittable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".claude/skills/run-longhand/fixture/seed-job")
        let files = JobFiles(root: root)
        let record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        let screen = TranscriptScreenModel(jobID: record.id, files: files)
        screen.load()
        #expect(screen.transcript != nil)
        #expect(screen.canSplit(at: 0), "turn 0 words: \(screen.index.words(forTurnAt: 0).count), text: \(screen.transcript?.turns[0].text ?? "")")
    }
}
