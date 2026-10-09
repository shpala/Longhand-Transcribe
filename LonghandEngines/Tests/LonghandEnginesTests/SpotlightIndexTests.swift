import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// What a recording contributes to the device's search index, and what it
/// keeps out of it.
@Suite struct SpotlightIndexTests {

    private func record(title: String = "Weekly sync") -> JobRecord {
        JobRecord(id: UUID(), title: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                  state: .complete, lastCheckpointState: .complete, duration: 125, language: "en")
    }

    private func transcript(turns: [(String, String)]) -> Transcript {
        Transcript(recordingID: "r", sourceHash: "h", duration: 125, language: "en",
                   pipelineVersion: "test", models: .init(asr: "test"),
                   mergeParams: .init(boundaryToleranceMs: 250, turnGapSeconds: 1),
                   speakers: [:],
                   turns: turns.enumerated().map { index, pair in
                       Transcript.Turn(id: index, cluster: pair.0, speaker: pair.0,
                                       start: Double(index), end: Double(index + 1),
                                       overlapped: false, text: pair.1)
                   })
    }

    @Test func wordsAndSpeakersGoInWithTheTitle() {
        let record = record()
        let entry = SpotlightIndex.entry(for: record, transcript: transcript(turns: [
            ("Noa", "We ship on Tuesday."),
            ("Dan", "Agreed, I will write the notes."),
        ]))
        #expect(entry.jobID == record.id)
        #expect(entry.title == "Weekly sync")
        #expect(entry.text == "Noa: We ship on Tuesday.\nDan: Agreed, I will write the notes.")
        #expect(entry.speakers == ["Noa", "Dan"])
        #expect(entry.snippet == "We ship on Tuesday. Agreed, I will write the notes.")
        #expect(entry.duration == 125)
        #expect(entry.createdAt == record.createdAt)
    }

    @Test func aJobWithoutATranscriptIsFoundByTitleAlone() {
        let entry = SpotlightIndex.entry(for: record(title: "Still transcribing"), transcript: nil)
        #expect(entry.title == "Still transcribing")
        #expect(entry.text.isEmpty)
        #expect(entry.snippet.isEmpty)
        #expect(entry.speakers.isEmpty)
    }

    @Test func theSnippetEndsOnAWord() {
        let long = Array(repeating: "alpha beta gamma", count: 40).joined(separator: " ")
        let entry = SpotlightIndex.entry(for: record(), transcript: transcript(turns: [("A", long)]))
        #expect(entry.snippet.count <= SpotlightIndex.snippetLength + 1)
        #expect(entry.snippet.hasSuffix("…"))
        #expect(!entry.snippet.hasSuffix(" …"))
        let body = entry.snippet.dropLast()
        #expect(body.hasSuffix("alpha") || body.hasSuffix("beta") || body.hasSuffix("gamma"))
    }

    @Test func theTestHostNeverIndexes() {
        // The package tests run in a test host, not the app: nothing here
        // may reach the Mac's Spotlight.
        #expect(!SpotlightIndex.hostIsApp)
    }
}
