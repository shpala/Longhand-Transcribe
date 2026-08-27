import Foundation
import Testing
@testable import LonghandKit

private func mw(_ text: String, _ start: Double, _ end: Double,
                _ speaker: String?, overlapped: Bool = false) -> MergedWord {
    MergedWord(text: text, start: start, end: end, speaker: speaker,
               decision: .segmentVote, overlapped: overlapped)
}

@Suite struct TurnBuilderTests {

    @Test func groupsBySpeakerAndGap() {
        let words = [
            mw("hi", 0.0, 0.3, "SPEAKER_00"),
            mw("there", 0.4, 0.7, "SPEAKER_00"),
            mw("hello", 2.5, 2.9, "SPEAKER_01"),   // speaker change
            mw("again", 6.0, 6.3, "SPEAKER_01"),   // gap 3.1 s > 1.0 s → new turn
        ]
        let turns = TurnBuilder.buildTurns(words: words)
        #expect(turns.count == 3)
        #expect(turns[0].cluster == "SPEAKER_00")
        #expect(turns[0].text == "hi there")
        #expect(turns[1].cluster == "SPEAKER_01")
        #expect(turns[2].cluster == "SPEAKER_01")
    }

    @Test func smoothsSingleWordIsland() {
        let words = [
            mw("so", 0.0, 0.3, "SPEAKER_00"),
            mw("we", 0.4, 0.7, "SPEAKER_00"),
            mw("uh", 0.8, 1.0, "SPEAKER_01"),      // island
            mw("should", 1.1, 1.5, "SPEAKER_00"),
            mw("go", 1.6, 1.9, "SPEAKER_00"),
        ]
        let turns = TurnBuilder.buildTurns(words: words)
        #expect(turns.count == 1)
        #expect(turns[0].cluster == "SPEAKER_00")
        #expect(turns[0].text == "so we uh should go")
        // Raw word attribution is preserved: the island word keeps SPEAKER_01.
        #expect(turns[0].words.first { $0.text == "uh" }?.speaker == "SPEAKER_01")
    }

    @Test func doesNotSmoothOverlappedIsland() {
        let words = [
            mw("so", 0.0, 0.3, "SPEAKER_00"),
            mw("no", 0.8, 1.0, "SPEAKER_01", overlapped: true),
            mw("go", 1.1, 1.5, "SPEAKER_00"),
        ]
        let turns = TurnBuilder.buildTurns(words: words)
        #expect(turns.count == 3)
    }

    @Test func unknownWordsFormUnknownTurns() {
        let words = [
            mw("mystery", 0.0, 0.5, nil),
            mw("voice", 0.6, 1.0, nil),
        ]
        let turns = TurnBuilder.buildTurns(words: words)
        #expect(turns.count == 1)
        #expect(turns[0].cluster == nil)
        let transcriptTurns = TurnBuilder.transcriptTurns(from: turns, speakers: [:])
        #expect(transcriptTurns[0].speaker == "Unknown speaker")
        #expect(transcriptTurns[0].cluster == "UNKNOWN")
    }

    @Test func overlapFlagPropagatesToTurn() {
        let words = [
            mw("both", 0.0, 0.4, "SPEAKER_00", overlapped: true),
            mw("talking", 0.5, 0.9, "SPEAKER_00"),
        ]
        let turns = TurnBuilder.buildTurns(words: words)
        #expect(turns.count == 1)
        #expect(turns[0].overlapped == true)
    }
}
