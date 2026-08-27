import Foundation
import Testing
@testable import LonghandKit

private func t(_ id: Int, _ start: TimeInterval, _ end: TimeInterval) -> Transcript.Turn {
    Transcript.Turn(id: id, cluster: "SPEAKER_00", speaker: "Speaker 1",
                    start: start, end: end, overlapped: false, text: "turn \(id)")
}

private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> MergedWord {
    MergedWord(text: text, start: start, end: end, speaker: "SPEAKER_00", decision: .segmentVote, overlapped: false)
}

@Suite struct TranscriptIndexTests {

    private let turns = [t(0, 0, 5), t(1, 5, 9), t(2, 20, 25)]

    @Test func findsTheTurnThatHasStarted() {
        let index = TranscriptIndex(turns: turns)
        #expect(index.turnIndex(at: 0) == 0)
        #expect(index.turnIndex(at: 4.9) == 0)
        #expect(index.turnIndex(at: 5) == 1)
        #expect(index.turnIndex(at: 21) == 2)
    }

    /// Lyrics-app rule: a gap between turns keeps the previous one lit rather
    /// than going dark, which is what long silences would otherwise do.
    @Test func staysOnTheLastTurnThroughASilence() {
        #expect(TranscriptIndex(turns: turns).turnIndex(at: 14) == 1)
    }

    @Test func nothingIsLitBeforeTheFirstTurn() {
        #expect(TranscriptIndex(turns: [t(0, 3, 6)]).turnIndex(at: 1) == nil)
        #expect(TranscriptIndex(turns: []).turnIndex(at: 5) == nil)
    }

    @Test func theCursorFormAgreesWithTheSearchForm() {
        let index = TranscriptIndex(turns: turns)
        var hint: Int?
        for time in stride(from: 0.0, through: 26.0, by: 0.1) {
            let cursored = index.turnIndex(at: time, from: hint)
            #expect(cursored == index.turnIndex(at: time))
            hint = cursored
        }
    }

    @Test func theCursorFormHandlesASeekBackwards() {
        let index = TranscriptIndex(turns: turns)
        #expect(index.turnIndex(at: 1.0, from: 2) == 0, "scrubbing back must not stick")
    }

    // MARK: - Word joining

    /// The inline version both shells used matched `start >= turn.start - 0.001
    /// && start < turn.end`, so a word landing exactly on an abutting boundary
    /// belonged to two turns at once.
    @Test func eachWordBelongsToExactlyOneTurnWhenTurnsAbut() {
        let index = TranscriptIndex(turns: [t(0, 0, 5), t(1, 5, 9)],
                                    words: [w("a", 0, 1), w("b", 4.9, 5.0), w("c", 5.0, 5.5)])
        #expect(index.words(forTurnAt: 0).map(\.text) == ["a", "b"])
        #expect(index.words(forTurnAt: 1).map(\.text) == ["c"])
    }

    @Test func wordsInAGapBelongToNoTurn() {
        let index = TranscriptIndex(turns: [t(0, 0, 5), t(1, 20, 25)],
                                    words: [w("a", 1, 2), w("stray", 10, 11), w("b", 21, 22)])
        #expect(index.words(forTurnAt: 0).map(\.text) == ["a"])
        #expect(index.words(forTurnAt: 1).map(\.text) == ["b"])
    }

    @Test func findsTheActiveWordWithinATurn() {
        let index = TranscriptIndex(turns: [t(0, 0, 5)],
                                    words: [w("one", 0, 1), w("two", 1.5, 2), w("three", 3, 4)])
        #expect(index.wordIndex(at: 0.5, inTurnAt: 0) == 0)
        #expect(index.wordIndex(at: 1.7, inTurnAt: 0) == 1)
        // Between words the last one that started stays active: the sticky
        // rule that keeps the sweep from stalling in Whisper's timing gaps.
        #expect(index.wordIndex(at: 2.5, inTurnAt: 0) == 1)
        #expect(index.wordIndex(at: 3.9, inTurnAt: 0) == 2)
    }

    @Test func aTranscriptWithoutWordTimingsStillIndexesTurns() {
        let index = TranscriptIndex(turns: turns)
        #expect(index.words(forTurnAt: 0).isEmpty)
        #expect(index.wordIndex(at: 1, inTurnAt: 0) == nil)
        #expect(index.turnIndex(at: 6) == 1)
    }
}
