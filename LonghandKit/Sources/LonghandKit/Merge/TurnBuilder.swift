import Foundation

/// Builds conversational turns from attributed words (§8.1). Raw word-level
/// attribution is preserved separately in 30_merged_words.json; smoothing here
/// never rewrites it.
public enum TurnBuilder {

    public struct RawTurn: Sendable, Equatable {
        public var cluster: String?   // nil = UNKNOWN
        public var start: TimeInterval
        public var end: TimeInterval
        public var overlapped: Bool
        public var words: [MergedWord]

        public var text: String {
            words.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    public static func buildTurns(words: [MergedWord], params: MergeParams = MergeParams()) -> [RawTurn] {
        var turns: [RawTurn] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if var last = turns.last,
               last.cluster == word.speaker,
               word.start - last.end <= params.turnGap {
                last.end = max(last.end, word.end)
                last.overlapped = last.overlapped || word.overlapped
                last.words.append(word)
                turns[turns.count - 1] = last
            } else {
                turns.append(RawTurn(cluster: word.speaker, start: word.start, end: word.end,
                                     overlapped: word.overlapped, words: [word]))
            }
        }
        if params.smoothIslands {
            turns = smoothIslands(turns, params: params)
        }
        return turns
    }

    /// Conservative one-word-island smoothing (§8.1): a single short word
    /// attributed to B, flanked by A turns with small gaps, is absorbed into A.
    static func smoothIslands(_ turns: [RawTurn], params: MergeParams) -> [RawTurn] {
        guard turns.count >= 3 else { return turns }
        var result: [RawTurn] = []
        var i = 0
        while i < turns.count {
            let turn = turns[i]
            let isIsland = turn.words.count == 1
                && (turn.end - turn.start) <= 0.5
                && !turn.overlapped
                && i > 0 && i < turns.count - 1
                && turns[i - 1].cluster != nil
                && turns[i - 1].cluster == turns[i + 1].cluster
                && turns[i - 1].cluster != turn.cluster
                && (turn.start - turns[i - 1].end) <= params.turnGap
                && (turns[i + 1].start - turn.end) <= params.turnGap
            if isIsland, var prev = result.popLast() {
                let next = turns[i + 1]
                prev.end = next.end
                prev.overlapped = prev.overlapped || turn.overlapped || next.overlapped
                prev.words.append(contentsOf: turn.words)
                prev.words.append(contentsOf: next.words)
                result.append(prev)
                i += 2
            } else {
                result.append(turn)
                i += 1
            }
        }
        return result
    }

    /// Converts raw turns into canonical transcript turns, resolving display
    /// names through the speakers table (§13.1).
    public static func transcriptTurns(from raw: [RawTurn],
                                       speakers: [String: Transcript.Speaker]) -> [Transcript.Turn] {
        raw.enumerated().map { index, turn in
            let cluster = turn.cluster ?? "UNKNOWN"
            let display = speakers[cluster]?.displayName ?? (turn.cluster == nil ? "Unknown speaker" : cluster)
            return Transcript.Turn(id: index, cluster: cluster, speaker: display,
                                   start: turn.start, end: turn.end,
                                   overlapped: turn.overlapped, text: turn.text)
        }
    }
}
