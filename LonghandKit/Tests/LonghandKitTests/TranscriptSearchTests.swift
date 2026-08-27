import Foundation
import Testing
@testable import LonghandKit

private func searchTurn(_ id: Int, _ start: TimeInterval, _ text: String) -> Transcript.Turn {
    Transcript.Turn(id: id, cluster: "SPEAKER_00", speaker: "Speaker 1",
                    start: start, end: start + 4, overlapped: false, text: text)
}

@Suite struct TranscriptSearchTests {

    private let turns = [
        searchTurn(0, 0, "We need to get this done before Wednesday."),
        searchTurn(1, 12, "שלום, זו היא בדיקת תמלול קצרה."),
        searchTurn(2, 30, "Wednesday works, or Thursday if that's easier."),
    ]

    @Test func findsEveryOccurrenceInOrder() {
        let hits = TranscriptSearch.matches(query: "Wednesday", in: turns)
        #expect(hits.count == 2)
        #expect(hits.map(\.turnID) == [0, 2])
        #expect(hits.first?.start == 0)
        #expect(hits.last?.start == 30)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(TranscriptSearch.matches(query: "wednesday", in: turns).count == 2)
    }

    /// The Hebrew promise from §15.4, at the level a user experiences it.
    @Test func findsHebrewTypedWithoutNikkud() {
        let pointed = [searchTurn(0, 0, "אָמַר שָׁלוֹם לְכֻלָּם")]
        #expect(TranscriptSearch.matches(query: "שלום", in: pointed).count == 1)
    }

    /// The clitic fallback, at the level a user experiences it: you search the
    /// word the way you heard it said, and the transcript wrote it bare.
    @Test func findsHebrewTypedWithItsCliticPrefix() {
        let spoken = [searchTurn(0, 0, "הרופא אמר שהתוצאות בסדר"),
                      searchTurn(1, 8, "חתמנו על חוזה השכירות")]
        let doctor = TranscriptSearch.matches(query: "לרופא", in: spoken)
        #expect(doctor.count == 1)
        #expect(doctor.first?.turnID == 0)
        // The range still points into the untouched turn, so highlighting works.
        #expect(spoken[0].text[doctor[0].range] == "רופא")

        let contract = TranscriptSearch.matches(query: "בחוזה", in: spoken)
        #expect(contract.count == 1)
        #expect(contract.first?.turnID == 1)
    }

    @Test func hitsCarryRangesIntoTheOriginalText() {
        let hits = TranscriptSearch.matches(query: "done", in: turns)
        #expect(hits.count == 1)
        #expect(turns[0].text[hits[0].range] == "done")
    }

    @Test func snippetsShowContextAroundTheMatch() {
        let long = [searchTurn(0, 0, String(repeating: "filler words here. ", count: 8) + "the needle appears late in this turn")]
        let hit = TranscriptSearch.matches(query: "needle", in: long).first
        #expect(hit?.snippet.contains("needle") == true)
        #expect(hit?.snippet.hasPrefix("…") == true, "a mid-turn match is shown as an excerpt")
        #expect((hit?.snippet.count ?? 999) < long[0].text.count)
    }

    @Test func aQueryThatMatchesNothingReturnsNothing() {
        #expect(TranscriptSearch.matches(query: "kangaroo", in: turns).isEmpty)
        #expect(TranscriptSearch.matches(query: "   ", in: turns).isEmpty)
    }

    @Test func containsMatchAgreesWithTheFullSearch() {
        #expect(TranscriptSearch.containsMatch(query: "תמלול", in: turns))
        #expect(!TranscriptSearch.containsMatch(query: "kangaroo", in: turns))
    }

    @Test func searchesAcrossAWholeTranscript() {
        let transcript = Transcript(recordingID: "R", sourceHash: "H", duration: 40, language: "en",
                                    pipelineVersion: Transcript.currentPipelineVersion,
                                    models: .init(asr: "test", diarization: nil, speakerID: nil),
                                    mergeParams: .init(boundaryToleranceMs: 250, turnGapSeconds: 1),
                                    speakers: ["SPEAKER_00": .init(displayName: "Speaker 1")],
                                    turns: turns)
        #expect(TranscriptSearch.matches(query: "Thursday", in: transcript).first?.turnIndex == 2)
    }
}
