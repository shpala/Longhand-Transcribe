import Foundation

/// Time → turn and time → word lookups for playback-synced rendering (§15.2),
/// built once at load. Done inline, per tick, over a 60-minute transcript's
/// several hundred turns and ten thousand words, this is the performance trap
/// ⟨R-16⟩ names. The join is also exact: a word belongs to one turn, where a
/// naive `start >= turn.start && start < turn.end` claims it for two when
/// turns abut.
public struct TranscriptIndex: Sendable {

    public let turns: [Transcript.Turn]
    /// Parallel to `turns`; empty when the job has no word-level timings
    /// (older jobs, or a degraded run).
    private let wordRanges: [Range<Int>]
    private let words: [MergedWord]
    private let turnStarts: [TimeInterval]
    private let passageCounts: [String: Int]

    public init(turns: [Transcript.Turn], words: [MergedWord] = []) {
        self.turns = turns
        self.words = words
        self.turnStarts = turns.map(\.start)
        self.passageCounts = turns.reduce(into: [:]) { $0[$1.effectiveCluster, default: 0] += 1 }

        // One pass over both sorted sequences: a word joins the last turn whose
        // start is at or before it and whose end is after it, and never two.
        var ranges = [Range<Int>](repeating: 0..<0, count: turns.count)
        var wordCursor = 0
        for (turnIndex, turn) in turns.enumerated() {
            while wordCursor < words.count, words[wordCursor].start < turn.start - 0.001 {
                wordCursor += 1   // word sits in a gap before this turn
            }
            let lower = wordCursor
            // Bounded by the next turn's start as well as this turn's end:
            // diarization intervals can overlap (§8.2), and a word inside the
            // overlap would otherwise go to whichever turn came first.
            let boundary = turnIndex + 1 < turns.count
                ? Swift.min(turn.end, turns[turnIndex + 1].start)
                : turn.end
            while wordCursor < words.count, words[wordCursor].start < boundary {
                wordCursor += 1
            }
            ranges[turnIndex] = lower..<wordCursor
        }
        self.wordRanges = ranges
    }

    public init(transcript: Transcript, words: [MergedWord] = []) {
        self.init(turns: transcript.turns, words: words)
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// What a rename would touch. Counted once at load: the chip is drawn for
    /// every turn, and a `filter` per chip is the same O(n²) trap ⟨R-16⟩ names.
    public func passageCount(forCluster cluster: String) -> Int {
        passageCounts[cluster] ?? 0
    }

    /// The most recent turn to have started, not the turn containing this
    /// instant: a transcript with long silences would otherwise flicker dark
    /// for most of playback.
    public func turnIndex(at time: TimeInterval) -> Int? {
        guard !turns.isEmpty, time >= turnStarts[0] else { return nil }
        var low = 0, high = turnStarts.count - 1, result = 0
        while low <= high {
            let mid = (low + high) / 2
            if turnStarts[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    public func turn(at time: TimeInterval) -> Transcript.Turn? {
        turnIndex(at: time).map { turns[$0] }
    }

    /// Same answer as `turnIndex(at:)`, from where playback was a moment ago,
    /// so it is O(1) while time moves forward slowly.
    public func turnIndex(at time: TimeInterval, from hint: Int?) -> Int? {
        guard let hint, hint >= 0, hint < turns.count, turnStarts[hint] <= time else {
            return turnIndex(at: time)
        }
        var index = hint
        while index + 1 < turns.count, turnStarts[index + 1] <= time {
            index += 1
            // More than a couple of turns behind means a seek, not playback.
            if index - hint > 2 { return turnIndex(at: time) }
        }
        return index
    }

    public func words(forTurnAt index: Int) -> ArraySlice<MergedWord> {
        guard index >= 0, index < wordRanges.count else { return [] }
        return words[wordRanges[index]]
    }

    /// Index within the turn's slice, or nil when no word has started yet.
    public func wordIndex(at time: TimeInterval, inTurnAt turnIndex: Int) -> Int? {
        let slice = words(forTurnAt: turnIndex)
        guard !slice.isEmpty else { return nil }
        var result: Int?
        for (offset, word) in slice.enumerated() {
            if word.start <= time { result = offset } else { break }
        }
        return result
    }
}
