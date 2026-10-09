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

    /// Markers made while recording can be relabelled, moved and removed
    /// from the transcript afterwards, and the Markdown follows.
    @Test func markersAreEditableAfterTheFact() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try screen.addMarker(at: 6.0, label: "  Decision  ")
        try screen.addMarker(at: 0.5, label: nil)
        #expect(screen.markers.map(\.label) == [nil, "Decision"])

        let flag = screen.markers[0]
        try screen.relabelMarker(flag, to: "Opening")
        try screen.moveMarker(screen.markers[1], to: 2.0)
        #expect(screen.markers.map { ($0.label ?? "", $0.time) }.map { "\($0.0)@\($0.1)" } == ["Opening@0.5", "Decision@2.0"])
        #expect(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8).contains("Decision"))

        try screen.removeMarker(screen.markers[1])
        #expect(screen.markers.map(\.label) == ["Opening"])
        #expect(!(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)).contains("Decision"))
    }

    @Test func aStagedExportCopyCarriesTheRecordingName() async throws {
        let (_, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let staged = try ExportStaging.stagedCopy(of: files.transcriptMarkdown, title: "Weekly sync: Q3", kind: .markdown)
        defer { ExportStaging.sweep() }
        #expect(staged.lastPathComponent == "Weekly sync- Q3 transcript.md")
        #expect(try Data(contentsOf: staged) == Data(contentsOf: files.transcriptMarkdown))
    }

    // MARK: - Summary

    /// The summary rides the exports: saving one puts it in the Markdown,
    /// editing a word under it marks it stale without dropping it, and
    /// removing it takes it out of the export again.
    @Test func aSummaryIsExportedLabelledStaleAndRemovable() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let transcript = try #require(screen.transcript)
        #expect(screen.summary == nil)

        try screen.saveSummary(TranscriptSummary(model: "test", transcriptHash: TranscriptSummary.hash(of: transcript),
                                                 overview: "Wednesday was agreed.", actionItems: [" ", "Noam drafts"]))
        #expect(screen.summary?.actionItems == ["Noam drafts"], "lists are tidied on save")
        #expect(!screen.summaryIsStale)
        #expect(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8).hasPrefix("## Summary\n\nWednesday was agreed."))

        try screen.edit(transcript.turns[0], to: "We need Thursday")
        #expect(screen.summary != nil, "a correction never drops the summary")
        #expect(screen.summaryIsStale)

        try screen.deleteSummary()
        #expect(screen.summary == nil)
        #expect(!FileManager.default.fileExists(atPath: files.summary.path))
        #expect(!(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)).contains("## Summary"))
    }

    @Test func calendarNamesAreOfferedButNotOnesAlreadyEnrolled() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var metadata = try #require(try AtomicFile.readJSON(ImportMetadata.self, from: files.metadata, stage: "IMPORTED"))
        metadata.calendarEvent = CalendarEventContext(title: "Weekly sync", attendees: ["Dana", "Noam"])
        try AtomicFile.writeJSON(metadata, to: files.metadata)
        screen.load()

        #expect(screen.suggestedSpeakerNames == ["Dana", "Noam"])
        #expect(screen.calendarNameSuggestions(excluding: ["Noam "]) == ["Dana"])
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

/// Every correction is one undoable step on the overlay, and undoing one
/// rebuilds the exports as they were.
@Suite struct TranscriptUndoTests {

    @MainActor
    private func completedJob() async throws -> (TranscriptScreenModel, JobFiles) {
        let files = try seededJob()
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
        let record = try #require(try AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job"))
        let screen = TranscriptScreenModel(jobID: record.id, files: files)
        screen.undoManager = UndoManager()
        screen.load()
        return (screen, files)
    }

    @MainActor
    @Test func renameSplitAndMarkerAllUndoAndRedo() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        #expect(!screen.canUndo)

        try screen.rename(cluster: "SPEAKER_00", to: "Dana")
        #expect(screen.canUndo && screen.undoActionName == "Rename Speaker")
        #expect(screen.transcript?.turns[0].speaker == "Dana")

        let turn = try #require(screen.transcript?.turns[0])     // "We need Wednesday"
        #expect(screen.canSplit(at: 0))
        try screen.split(turn, at: 0, beforeWord: 2)
        #expect(screen.transcript?.turns.map(\.text) == ["We need", "Wednesday", "Fine with me"])
        #expect(screen.transcript?.turns[1].splitFromPrevious == true)
        #expect(screen.undoActionName == "Split Passage")

        try screen.addMarker(at: 1.0, label: "cut here")
        #expect(screen.markers.count == 1)

        screen.undo()
        #expect(screen.markers.isEmpty)
        #expect(screen.canRedo)
        screen.undo()
        #expect(screen.transcript?.turns.count == 2, "the split is undone")
        screen.undo()
        #expect(screen.transcript?.turns[0].speaker == "Speaker 1", "the rename is undone")
        #expect(!screen.canUndo)
        #expect(!(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)).contains("Dana"))

        screen.redo()
        #expect(screen.transcript?.turns[0].speaker == "Dana")
        #expect(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8).contains("Dana"))
        screen.redo()
        #expect(screen.transcript?.turns.count == 3)
    }

    @MainActor
    @Test func aJoinRemovesTheSplitAndSeveralPassagesMoveTogether() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let turn = try #require(screen.transcript?.turns[0])
        try screen.split(turn, at: 0, beforeWord: 1)
        let second = try #require(screen.transcript?.turns[1])
        try screen.join(second)
        #expect(screen.transcript?.turns.count == 2)

        let both = try #require(screen.transcript?.turns)
        try screen.assignToNewSpeaker(both, named: "Noa")
        #expect(screen.transcript?.turns.allSatisfy { $0.speaker == "Noa" } == true)
        #expect(screen.undoActionName == "Reassign 2 Passages")
        screen.undo()
        #expect(screen.transcript?.turns.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    /// An edited turn's words no longer match its text, so it cannot be cut
    /// at a word; reverting the edit makes it splittable again.
    @MainActor
    @Test func anEditedTurnCannotBeSplit() async throws {
        let (screen, files) = try await completedJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let turn = try #require(screen.transcript?.turns[0])
        try screen.edit(turn, to: "We need it Wednesday")
        #expect(!screen.canSplit(at: 0))
        try screen.revertEdit(try #require(screen.transcript?.turns[0]))
        #expect(screen.canSplit(at: 0))
    }
}
