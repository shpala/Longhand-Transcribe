import Foundation

/// A synthetic transcript at the scale §15.2 ⟨R-16⟩ names: an hour is on the
/// order of 10,000 words over several hundred turns.
///
/// It generates words only, and lets `TurnBuilder` produce the turns from them.
/// Fabricating turns directly would let the fixture's word-to-turn join drift
/// from the pipeline's, and the join is exactly what the playback lookups are
/// measured against.
///
/// Shipped rather than test-local because the UI-test seeder needs the same
/// corpus as the unit test; a second generator would measure a second thing.
public enum TranscriptFixture {

    /// Roughly natural speech, and it lands an hour on ~10,000 words.
    public static let wordsPerMinute = 167.0

    private static let vocabulary = [
        "the", "meeting", "started", "late", "again", "because", "nobody",
        "checked", "the", "calendar", "before", "booking", "another", "room",
        "and", "we", "lost", "twenty", "minutes", "arguing", "about", "it",
    ]

    /// Alternating speakers, one turn per run of words, with a silence every
    /// eighth turn so the "stays lit through a gap" path is exercised too.
    public static func words(minutes: Double, speakers: Int = 2) -> [MergedWord] {
        let total = max(1, Int(minutes * wordsPerMinute))
        let step = (minutes * 60) / Double(total)

        var result: [MergedWord] = []
        result.reserveCapacity(total)
        var time: TimeInterval = 0
        var turn = 0

        while result.count < total {
            // 12 to 28 words, cycling: a fixed spread beats a random one, since
            // a performance comparison across two sizes needs the same shape.
            let length = 12 + (turn * 7) % 17
            let cluster = String(format: "SPEAKER_%02d", turn % speakers)
            for _ in 0..<length where result.count < total {
                let text = vocabulary[result.count % vocabulary.count]
                result.append(MergedWord(text: text, start: time, end: time + step * 0.8,
                                         speaker: cluster, decision: .segmentVote,
                                         overlapped: false))
                time += step
            }
            if turn % 8 == 7 { time += 4 }   // a pause in the conversation
            turn += 1
        }
        return result
    }

    /// The turns the pipeline would build from `words(minutes:speakers:)`.
    public static func turns(minutes: Double, speakers: Int = 2,
                            speakerNames: [String: Transcript.Speaker] = [:]) -> [Transcript.Turn] {
        TurnBuilder.transcriptTurns(
            from: TurnBuilder.buildTurns(words: words(minutes: minutes, speakers: speakers)),
            speakers: speakerNames)
    }
}
