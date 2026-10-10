import Foundation
import Testing
@testable import LonghandKit

private func transcript(_ turns: [(speaker: String, start: TimeInterval, text: String)]) -> Transcript {
    Transcript(
        recordingID: "SUMMARY-1",
        sourceHash: "cafe",
        duration: 600,
        language: "en",
        pipelineVersion: Transcript.currentPipelineVersion,
        models: .init(asr: "test/fixture"),
        mergeParams: .init(boundaryToleranceMs: 250, turnGapSeconds: 1.0),
        speakers: ["SPEAKER_00": .init(displayName: "Dana"), "SPEAKER_01": .init(displayName: "Noam")],
        turns: turns.enumerated().map { index, turn in
            .init(id: index, cluster: turn.speaker == "Dana" ? "SPEAKER_00" : "SPEAKER_01",
                  speaker: turn.speaker, start: turn.start, end: turn.start + 2,
                  overlapped: false, text: turn.text)
        }
    )
}

private func words(_ count: Int, prefix: String = "w") -> String {
    (0..<count).map { "\(prefix)\($0)" }.joined(separator: " ")
}

@Suite struct SummaryChunkerTests {

    @Test func aShortTranscriptIsOneChunkWithSpeakerNames() {
        let chunks = SummaryChunker.chunks(of: transcript([
            ("Dana", 0, "We need this by Wednesday."),
            ("Noam", 3, "Fine with me."),
        ]), maxWords: 100)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Dana: We need this by Wednesday.\nNoam: Fine with me.")
        #expect(chunks[0].wordCount == 8)
        #expect(chunks[0].start == 0)
    }

    @Test func turnsAreKeptWholeWhenTheNextChunkHasRoom() {
        let chunks = SummaryChunker.chunks(of: transcript([
            ("Dana", 0, words(60)),
            ("Noam", 10, words(60, prefix: "n")),
            ("Dana", 20, words(60, prefix: "d")),
        ]), maxWords: 100)
        // 60 + 60 overflows, so the second turn starts the second chunk
        // rather than being split across the boundary.
        #expect(chunks.map(\.wordCount) == [60, 60, 60])
        #expect(chunks.map(\.start) == [0, 10, 20])
        #expect(chunks[1].text.hasPrefix("Noam: n0 "))
    }

    @Test func aMonologueLongerThanTheBudgetIsCut() {
        let chunks = SummaryChunker.chunks(of: transcript([("Dana", 0, words(250))]), maxWords: 100)
        #expect(chunks.map(\.wordCount) == [100, 100, 50])
        // Every piece still says who is speaking.
        #expect(chunks.allSatisfy { $0.text.hasPrefix("Dana: ") })
        #expect(chunks[2].text.hasSuffix("w249"))
    }

    @Test func emptyTurnsAndEmptyTranscriptsProduceNoChunks() {
        #expect(SummaryChunker.chunks(of: transcript([])).isEmpty)
        #expect(SummaryChunker.chunks(of: transcript([("Dana", 0, "   ")])).isEmpty)
        #expect(SummaryChunker.wordCount(of: transcript([("Dana", 0, "one two"), ("Noam", 1, " three ")])) == 3)
    }
}

@Suite struct TranscriptSummaryTests {

    @Test func hashFollowsTheWordsAndTheNamesButNotPunctuation() {
        let base = transcript([("Dana", 0, "We need this by Wednesday."), ("Noam", 3, "Fine.")])
        var retyped = base
        retyped.turns[0].text = "we need this by wednesday"
        var renamed = base
        renamed.turns[1].speaker = "Noa"
        var reworded = base
        reworded.turns[1].text = "No."

        let summary = TranscriptSummary(model: "test", transcriptHash: TranscriptSummary.hash(of: base),
                                        overview: "Short.")
        #expect(summary.isCurrent(for: base))
        #expect(summary.isCurrent(for: retyped), "case and punctuation are not a change of meaning")
        #expect(!summary.isCurrent(for: renamed), "a renamed speaker changes what the summary should say")
        #expect(!summary.isCurrent(for: reworded))
    }

    @Test func markdownAndPlainTextSkipEmptySections() {
        let summary = TranscriptSummary(model: "test", transcriptHash: "x",
                                        overview: "  Dana and Noam agreed a date.  ",
                                        keyPoints: ["Wednesday is the deadline", "  "],
                                        decisions: [],
                                        actionItems: ["Noam sends the draft"])
        let markdown = summary.markdown
        #expect(markdown.hasPrefix("Dana and Noam agreed a date.\n\n### Key points\n\n- Wednesday is the deadline\n"))
        #expect(!markdown.contains("Decisions"))
        #expect(markdown.contains("### Action items\n\n- Noam sends the draft"))

        let plain = summary.plainText
        #expect(plain == "Dana and Noam agreed a date.\n\nKey points\n• Wednesday is the deadline\n\nAction items\n• Noam sends the draft")
    }

    @Test func rtlItemsAreIsolatedInMarkdownOnly() {
        let summary = TranscriptSummary(model: "test", transcriptHash: "x",
                                        overview: "", keyPoints: ["צריך לסיים עד Wednesday"])
        #expect(summary.markdown.contains("- \u{2067}צריך לסיים עד Wednesday\u{2069}"))
        #expect(summary.plainText == "Key points\n• צריך לסיים עד Wednesday")
    }

    @Test func emptinessAndTidying() {
        var summary = TranscriptSummary(model: "test", transcriptHash: "x",
                                        overview: " ", keyPoints: ["", " "], decisions: [], actionItems: [])
        #expect(summary.isEmpty)
        summary.actionItems = ["  call back  "]
        summary.tidy()
        #expect(!summary.isEmpty)
        #expect(summary.keyPoints.isEmpty)
        #expect(summary.actionItems == ["call back"])
        #expect(!summary.isEdited)
    }

    @Test func roundTripsThroughJSON() throws {
        let summary = TranscriptSummary(model: "apple-foundation-models/test", transcriptHash: "abc",
                                        overview: "O", keyPoints: ["k"], decisions: ["d"],
                                        actionItems: ["a"], editedAt: Date(timeIntervalSince1970: 100))
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(TranscriptSummary.self, from: data)
        #expect(decoded == summary)
        #expect(decoded.isEdited)
    }
}

@Suite struct SummaryExportTests {

    @Test func markdownExportLeadsWithTheSummaryUnderItsOwnHeading() {
        let base = transcript([("Dana", 0, "We need this by Wednesday."), ("Noam", 3, "Fine.")])
        let summary = TranscriptSummary(model: "test", transcriptHash: "x",
                                        overview: "A date was agreed.", decisions: ["Wednesday"])
        let markdown = TranscriptExporter.markdown(base, summary: summary)
        #expect(markdown.hasPrefix("## Summary\n\nA date was agreed.\n\n### Decisions\n\n- Wednesday\n\n## Transcript\n\n**Dana**"))
        // Without one, the export is exactly what it was.
        #expect(TranscriptExporter.markdown(base) == TranscriptExporter.markdown(base, summary: nil))
        #expect(!TranscriptExporter.markdown(base).contains("## Summary"))
    }

    @Test func anEmptySummaryAddsNothing() {
        let base = transcript([("Dana", 0, "Hello.")])
        let empty = TranscriptSummary(model: "test", transcriptHash: "x", overview: " ")
        #expect(TranscriptExporter.markdown(base, summary: empty) == TranscriptExporter.markdown(base))
    }

    /// The text export is what Copy Transcript and Get Transcript hand out,
    /// and a summary is not the transcript.
    @Test func textExportNeverCarriesTheSummary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-summary-export-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = JobFiles(root: directory)
        try files.createDirectory()
        let base = transcript([("Dana", 0, "We need this by Wednesday.")])
        try AtomicFile.writeJSON(TranscriptSummary(model: "test", transcriptHash: "x",
                                                   overview: "A date was agreed."), to: files.summary)

        try TranscriptExporter.writeAll(base, to: files)

        let markdown = try String(contentsOf: files.transcriptMarkdown, encoding: .utf8)
        let text = try String(contentsOf: files.transcriptText, encoding: .utf8)
        #expect(markdown.contains("## Summary"))
        #expect(!text.contains("A date was agreed."))
        #expect(text.contains("We need this by Wednesday."))
    }
}

/// The title the model writes beside the summary, made fit for a library row.
@Suite struct SummaryTitleTests {

    @Test func quotesAndAFullStopAreStripped() {
        #expect(TranscriptSummary.usableTitle("“Budget for the spring launch.”") == "Budget for the spring launch")
        #expect(TranscriptSummary.usableTitle("  Onboarding copy review ") == "Onboarding copy review")
    }

    @Test func emptyAndOverlongTitlesAreRefused() {
        #expect(TranscriptSummary.usableTitle(nil) == nil)
        #expect(TranscriptSummary.usableTitle("   ") == nil)
        #expect(TranscriptSummary.usableTitle("\"\"") == nil)
        let long = String(repeating: "word ", count: 20)
        #expect(TranscriptSummary.usableTitle(long) == nil)
    }

    @Test func onlyTheFirstLineIsATitle() {
        #expect(TranscriptSummary.usableTitle("Design review\nAbout the onboarding screen") == "Design review")
    }

    @Test func tidyAppliesTheSameRule() {
        var summary = TranscriptSummary(model: "test", transcriptHash: "x", overview: "o",
                                        title: "'Weekly sync.'")
        summary.tidy()
        #expect(summary.title == "Weekly sync")
    }

    @Test func aSummaryWrittenBeforeTitlesExistedStillDecodes() throws {
        let json = """
        {"version":1,"generatedAt":0,"model":"m","transcriptHash":"h","overview":"o",
         "keyPoints":[],"decisions":[],"actionItems":[]}
        """
        let summary = try JSONDecoder().decode(TranscriptSummary.self, from: Data(json.utf8))
        #expect(summary.title == nil)
    }
}
