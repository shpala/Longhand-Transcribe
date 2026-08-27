import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// §6.4 says filtered speech is never silently discarded, and §17 says a
/// degraded transcript is never silent. Both were only half true: the span was
/// written to `10_asr.json`, and the note was raised only when the filter had
/// taken *everything*. A transcript that came back with words in it, minus a
/// passage, said nothing at all. The owner's library has one of those.
@Suite struct SuppressedSpeechTests {

    private func span(_ start: TimeInterval, _ text: String,
                      _ reason: SuppressedSpan.Reason = .verbatimRepeat) -> SuppressedSpan {
        SuppressedSpan(start: start, end: start + 0.4, reason: reason, text: text)
    }

    private func run(_ files: JobFiles) async throws -> JobRecord {
        try await JobPipeline.run(files: files, engines: stubEngines(), progress: { _ in })
    }

    /// The regression this suite exists for.
    @Test func aPassageFilteredOutOfAGoodTranscriptIsReported() async throws {
        let files = try seededJob(suppressed: [span(12.88, "איפה נד?")])
        defer { try? FileManager.default.removeItem(at: files.root) }

        let record = try await run(files)
        #expect(record.state == .complete)
        // The transcript is fine, which is exactly why this used to go unsaid.
        #expect(try transcript(files).turns.count == 2)
        #expect(record.degradations.contains(kind: .speechFilteredAsHallucination))
        #expect(record.degradations.contains { $0.message.contains("left out of this transcript") })
        // Not the other one: speech was detected, some of it was dropped.
        #expect(!record.degradations.contains(kind: .noSpeechDetected))
    }

    /// The case that already worked, kept so fixing the one above cannot break
    /// it: nothing survived, and the reason was the filter.
    @Test func aTranscriptEmptiedByTheFilterStillSaysSo() async throws {
        let files = try seededJob(words: [], suppressed: [span(1.0, "thanks for watching",
                                                              .boilerplateInSilence)])
        defer { try? FileManager.default.removeItem(at: files.root) }

        let record = try await run(files)
        #expect(try transcript(files).turns.isEmpty)
        #expect(record.degradations.contains(kind: .speechFilteredAsHallucination))
        #expect(record.degradations.contains { $0.message.hasPrefix("No speech kept") })
    }

    /// A silent room is a different fact from a filtered one, and answering
    /// with the wrong one sends the owner looking for the wrong problem.
    @Test func anEmptyTranscriptWithNothingFilteredIsASilentRoom() async throws {
        let files = try seededJob(words: [])
        defer { try? FileManager.default.removeItem(at: files.root) }

        let record = try await run(files)
        #expect(record.degradations.contains(kind: .noSpeechDetected))
        #expect(!record.degradations.contains(kind: .speechFilteredAsHallucination))
    }

    /// The far more common case. A note on every clean transcript would train
    /// the owner to ignore the notes.
    @Test func anUntouchedTranscriptCarriesNoNote() async throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }

        let record = try await run(files)
        #expect(!record.degradations.contains(kind: .speechFilteredAsHallucination))
        #expect(!record.degradations.contains(kind: .noSpeechDetected))
    }

    @Test func theCountIsReportedAndReadsAsEnglish() async throws {
        let one = try seededJob(suppressed: [span(1, "a")])
        defer { try? FileManager.default.removeItem(at: one.root) }
        let single = try await run(one)
        #expect(single.degradations.contains { $0.message.hasPrefix("1 passage was") })

        let many = try seededJob(suppressed: [span(1, "a"), span(2, "b"), span(3, "c")])
        defer { try? FileManager.default.removeItem(at: many.root) }
        let plural = try await run(many)
        #expect(plural.degradations.contains { $0.message.hasPrefix("3 passages were") })
    }

    /// A run that stops and resumes re-enters the merge stage, and the same
    /// degradation reached twice is one degradation.
    @Test func rerunningDoesNotStackTheSameNote() async throws {
        let files = try seededJob(suppressed: [span(12.88, "איפה נד?")])
        defer { try? FileManager.default.removeItem(at: files.root) }

        _ = try await run(files)
        let record = try await run(files)
        #expect(record.degradations.filter { $0.kind == .speechFilteredAsHallucination }.count == 1)
    }

    /// What the transcript screen reads. The point of surfacing the spans is
    /// that the note says a passage went and this says which, so a line the
    /// filter took by mistake is recognizable as one.
    @Test func theSpansThemselvesAreReadableBack() async throws {
        let files = try seededJob(suppressed: [span(12.88, "איפה נד?"),
                                               span(30.0, "thank you", .boilerplateInSilence)])
        defer { try? FileManager.default.removeItem(at: files.root) }
        _ = try await run(files)

        let spans = SuppressedSpans.load(from: files)
        #expect(spans.count == 2)
        #expect(spans.first?.text == "איפה נד?")
        #expect(spans.first?.reason == .verbatimRepeat)
        #expect(SuppressedSpans.reasonText(.verbatimRepeat) == "repeat of the line before")
    }

    /// A footnote on a transcript must not be able to take the screen down.
    @Test func anUnreadableCheckpointYieldsNoSpansRatherThanFailing() throws {
        let files = try seededJob()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try Data("{ truncated".utf8).write(to: files.asr)
        #expect(SuppressedSpans.load(from: files).isEmpty)
    }
}
