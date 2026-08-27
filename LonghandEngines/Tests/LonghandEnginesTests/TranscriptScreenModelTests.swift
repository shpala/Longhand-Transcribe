import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// The transcript screen's data and marker rules, shared by both shells. The
/// seeded job has two turns: "We need Wednesday" from 0.0 to 1.6 and "Fine
/// with me" from 4.0 to 5.4.
@MainActor
@Suite struct TranscriptScreenModelTests {

    private func completedJob() async throws -> (TranscriptScreenModel, JobFiles) {
        let files = try seededJob()
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        let record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        let screen = TranscriptScreenModel(jobID: record.id, files: files)
        screen.load()
        return (screen, files)
    }

    /// The Mac drew no row for these, so a flag pressed near the end of a
    /// recording disappeared.
    @Test func aMarkerAfterTheLastWordIsDrawnAfterTheLastTurn() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try JobPipeline.addMarker(files: files, at: 6.0)
        screen.load()

        #expect(screen.trailingRowMarkers.map(\.time) == [6.0])
        #expect(screen.rowMarkerLabel(screen.trailingRowMarkers[0], at: nil) == "Marked at 00:06")
        #expect(screen.rowMarkers(beforeTurnAt: 0).isEmpty)
        #expect(screen.rowMarkers(beforeTurnAt: 1).isEmpty)
    }

    @Test func aMarkerAmongTheWordsIsPlacedInlineAndNowhereElse() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try JobPipeline.addMarker(files: files, at: 0.5)
        screen.load()

        #expect(screen.placedMarkers(at: 0).map(\.beforeWord) == [2])
        #expect(screen.renderedWords(at: 0, isCurrent: false) != nil,
                "a marked turn needs its words even when it is not playing")
        #expect(screen.rowMarkers(beforeTurnAt: 1).isEmpty)
        #expect(screen.trailingRowMarkers.isEmpty)
    }

    @Test func aMarkerBetweenTurnsGetsARowBeforeTheNextOne() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try JobPipeline.addMarker(files: files, at: 2.5, label: "budget")
        screen.load()

        #expect(screen.rowMarkers(beforeTurnAt: 1).map(\.label) == ["budget"])
        #expect(screen.rowMarkerLabel(screen.rowMarkers(beforeTurnAt: 1)[0], at: 1) == "budget")
        #expect(screen.placedMarkers(at: 0).isEmpty && screen.placedMarkers(at: 1).isEmpty)
    }

    /// Editing a turn's text throws away its word timings, so its inline
    /// marker has to fall back to a row rather than vanish with them.
    @Test func editingAMarkedTurnMovesItsMarkerToARow() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try JobPipeline.addMarker(files: files, at: 0.5)
        screen.load()

        let turn = try #require(screen.transcript?.turns.first)
        try screen.edit(turn, to: "We need Thursday")

        #expect(screen.transcript?.turns.first?.text == "We need Thursday")
        #expect(screen.placedMarkers(at: 0).isEmpty)
        #expect(screen.rowMarkers(beforeTurnAt: 1).map(\.time) == [0.5])
        #expect(screen.renderedWords(at: 0, isCurrent: false) == nil)
    }

    @Test func correctionsReloadTheScreen() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }

        try screen.rename(cluster: "SPEAKER_00", to: "Dana")
        #expect(screen.transcript?.turns.first?.speaker == "Dana")
        #expect(!screen.isAutoLabeled(try #require(screen.transcript?.turns.first)))

        let second = try #require(screen.transcript?.turns.last)
        #expect(screen.otherSpeakers(than: second).map(\.name) == ["Dana"])
        try screen.reassign(second, to: "SPEAKER_00")
        #expect(screen.transcript?.turns.last?.speaker == "Dana")
    }

    @Test func aFinishedJobWithNoTranscriptFileIsUnreadableNotLoading() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        #expect(!screen.transcriptUnreadable)

        try Data("{ truncated".utf8).write(to: files.transcriptJSON)
        screen.load()
        #expect(screen.transcript == nil)
        #expect(screen.transcriptUnreadable)
    }

    @Test func clockLabelsGainHoursOnlyWhenTheyNeedThem() {
        #expect(TranscriptClock.label(0) == "00:00")
        #expect(TranscriptClock.label(65) == "01:05")
        #expect(TranscriptClock.label(3_900) == "1:05:00", "the Mac printed 65:00")
        #expect(TranscriptClock.rateLabel(1) == "1×")
        #expect(TranscriptClock.rateLabel(1.5) == "1.5×")
    }
}
