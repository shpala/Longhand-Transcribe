import Foundation
import Testing
@testable import LonghandKit

@Suite struct WordAlignmentTests {

    @Test func identicalTextHasNoErrors() {
        let counts = WordAlignment.compare(machine: "we need this before wednesday",
                                           human: "we need this before wednesday")
        #expect(counts.errors == 0)
        #expect(counts.errorRate == 0)
        #expect(counts.referenceWords == 5)
    }

    /// The three operations are counted apart because they mean different
    /// things: a deletion is speech the model missed, an insertion is speech it
    /// invented, and §6.4 exists because the second happens.
    @Test func theThreeOperationsAreDistinguished() {
        #expect(WordAlignment.compare(machine: "meet me at eight",
                                      human: "meet me at night").substitutions == 1)
        #expect(WordAlignment.compare(machine: "meet me eight",
                                      human: "meet me at eight").deletions == 1)
        #expect(WordAlignment.compare(machine: "meet me at at eight",
                                      human: "meet me at eight").insertions == 1)
    }

    /// A rate needs a denominator. An empty reference has none, and reporting
    /// zero would read as a perfect transcript.
    @Test func anEmptyReferenceHasNoRate() {
        #expect(WordAlignment.compare(machine: "anything", human: "").errorRate == nil)
        #expect(WordAlignment.compare(machine: "", human: "").errors == 0)
    }

    /// Everything the machine produced was wrong, and there is nothing to
    /// divide by, so this is counted rather than rated.
    @Test func aTurnCorrectedToNothingCountsAsDeletions() {
        let counts = WordAlignment.compare(machine: "", human: "three real words")
        #expect(counts.deletions == 3)
        #expect(counts.errorRate == 1)
    }

    /// Matching-fold tokens, so a correction that only restores vowel points or
    /// a final letter form is not counted as the model getting a word wrong.
    @Test func hebrewFoldingIsAppliedBeforeComparing() {
        #expect(WordAlignment.compare(machine: "שלום עולם", human: "שָׁלוֹם עוֹלָם").errors == 0)
    }

    /// Whisper's commas are not what anyone is measuring, and in a language
    /// where punctuation is largely optional they would drown the signal.
    @Test func punctuationOnlyChangesAreNotErrors() {
        #expect(WordAlignment.compare(machine: "we need this, before wednesday.",
                                      human: "we need this before wednesday").errors == 0)
    }

    @Test func countsAddUpAcrossTurns() {
        let a = WordAlignment.compare(machine: "one two three", human: "one two four")
        let b = WordAlignment.compare(machine: "five six", human: "five seven")
        let total = a + b
        #expect(total.referenceWords == 5)
        #expect(total.substitutions == 2)
        #expect(total.errorRate == 0.4)
    }
}

/// The corrections in the library are the corpus. These pin what it can be
/// trusted to say, and what it must refuse to.
@Suite struct AccuracyCorpusTests {

    private func makeJob(words: [(String, TimeInterval, TimeInterval)],
                         edits: [(TimeInterval, String, String)] = [],
                         language: String = "he") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accuracy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = JobFiles(root: root)

        let merged = words.map {
            MergedWord(text: $0.0, start: $0.1, end: $0.2, speaker: "SPEAKER_00",
                       decision: .segmentVote, overlapped: false)
        }
        try AtomicFile.writeJSON(MergeOutput(params: MergeParams(), words: merged),
                                 to: files.mergedWords)
        var record = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                               state: .complete, lastCheckpointState: .complete)
        record.language = language
        try AtomicFile.writeJSON(record, to: files.job)

        // Rebuild exactly as the harness will, so an edit anchors to real text.
        let turns = TurnBuilder.transcriptTurns(
            from: TurnBuilder.buildTurns(words: merged, params: MergeParams()), speakers: [:])
        var overlay = UserOverlay()
        for (start, base, corrected) in edits {
            let turn = turns.first { abs($0.start - start) < 0.01 }
            overlay.turnEdits.append(UserOverlay.TurnEdit(
                start: start, cluster: "SPEAKER_00",
                baseTextHash: UserOverlay.TurnEdit.hash(of: base.isEmpty ? (turn?.text ?? "") : base),
                newText: corrected))
        }
        if !overlay.isEmpty { try AtomicFile.writeJSON(overlay, to: files.overlay) }
        return root
    }

    @Test func aCorrectionBecomesAMeasuredPair() throws {
        let root = try makeJob(
            words: [("meet", 0, 0.4), ("me", 0.4, 0.7), ("at", 0.7, 0.9), ("eight", 0.9, 1.4)],
            edits: [(0, "", "meet me at night")])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(AccuracyCorpus.pairs(inJobAt: root))
        #expect(result.pairs.count == 1)
        #expect(result.pairs[0].machine == "meet me at eight")
        #expect(result.pairs[0].human == "meet me at night")
        #expect(result.counts.substitutions == 1)
        #expect(result.language == "he")
        #expect(result.totalMachineWords == 4)
        // One word of four was wrong, and the floor says so.
        #expect(result.errorFloor == 0.25)
    }

    /// The machine words moved under the edit, so the hash no longer proves
    /// what was corrected. Counted rather than guessed at.
    @Test func anEditWhoseMachineTextChangedIsSkipped() throws {
        let root = try makeJob(
            words: [("meet", 0, 0.4), ("me", 0.4, 0.7), ("at", 0.7, 0.9), ("eight", 0.9, 1.4)],
            edits: [(0, "something else entirely", "meet me at night")])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(AccuracyCorpus.pairs(inJobAt: root))
        #expect(result.pairs.isEmpty)
        #expect(result.skipped[.machineTextChanged] == 1)
    }

    @Test func anEditAnchoredToNoSurvivingTurnIsSkipped() throws {
        let root = try makeJob(words: [("hello", 0, 0.5)],
                               edits: [(90, "gone", "whatever")])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try #require(AccuracyCorpus.pairs(inJobAt: root))
        #expect(result.skipped[.noMatchingTurn] == 1)
    }

    /// A punctuation-only correction is a real edit and not a transcription
    /// error, so it must not inflate the measurement.
    @Test func aCorrectionWithNoMeasurableDifferenceIsSkipped() throws {
        let root = try makeJob(words: [("hello", 0, 0.4), ("world", 0.4, 0.9)],
                               edits: [(0, "", "hello, world.")])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try #require(AccuracyCorpus.pairs(inJobAt: root))
        #expect(result.pairs.isEmpty)
        #expect(result.skipped[.noMeasurableDifference] == 1)
        #expect(result.counts.errors == 0)
    }

    /// A job nobody corrected contributes its word count and no errors, which
    /// is what keeps the floor a floor rather than a rate over hard passages.
    @Test func anUncorrectedJobStillContributesItsDenominator() throws {
        let root = try makeJob(words: [("one", 0, 0.3), ("two", 0.3, 0.6)])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try #require(AccuracyCorpus.pairs(inJobAt: root))
        #expect(result.pairs.isEmpty)
        #expect(result.totalMachineWords == 2)
        #expect(result.errorFloor == 0)
        #expect(result.correctedTurnShare == 0)
    }

    /// A job with no merge checkpoint cannot be measured and is not counted as
    /// a perfect one.
    @Test func aJobWithNoMergeCheckpointIsNotAResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accuracy-empty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AccuracyCorpus.pairs(inJobAt: root) == nil)
    }

    /// Comparison is the only thing these numbers support, so grouping is the
    /// primary operation.
    @Test func resultsGroupForComparison() throws {
        let a = try makeJob(words: [("one", 0, 0.3), ("two", 0.3, 0.6)],
                            edits: [(0, "", "one three")], language: "he")
        let b = try makeJob(words: [("four", 0, 0.3), ("five", 0.3, 0.6)], language: "ru")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let results = [AccuracyCorpus.pairs(inJobAt: a), AccuracyCorpus.pairs(inJobAt: b)].compactMap { $0 }
        let groups = AccuracyCorpus.grouped(results) { $0.language ?? "unknown" }
        #expect(groups.map(\.key) == ["he", "ru"])
        #expect(groups[0].counts.errors == 1)
        #expect(groups[1].counts.errors == 0)
        #expect(groups[0].correctedTurns == 1)
    }

    @Test func scanningALibraryFindsEveryMeasurableJob() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("accuracy-lib-\(UUID())")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        for _ in 0..<2 {
            let job = try makeJob(words: [("one", 0, 0.3)])
            try FileManager.default.moveItem(
                at: job, to: library.appendingPathComponent(job.lastPathComponent))
        }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("not-a-job"), withIntermediateDirectories: true)
        #expect(AccuracyCorpus.scan(libraryAt: library).count == 2)
    }
}
