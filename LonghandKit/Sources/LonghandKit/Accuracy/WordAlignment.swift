import Foundation

/// Word-level edit distance between what the machine wrote and what a person
/// corrected it to, which is the arithmetic behind every WER figure.
public enum WordAlignment {

    public struct Counts: Sendable, Equatable {
        /// Words in the reference, which is the human text: the denominator.
        public var referenceWords: Int
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int

        public init(referenceWords: Int = 0, substitutions: Int = 0,
                    deletions: Int = 0, insertions: Int = 0) {
            self.referenceWords = referenceWords
            self.substitutions = substitutions
            self.deletions = deletions
            self.insertions = insertions
        }

        public var errors: Int { substitutions + deletions + insertions }

        /// Nil rather than zero when there is no reference to divide by. A
        /// denominator of nothing is not a rate of nothing.
        public var errorRate: Double? {
            referenceWords > 0 ? Double(errors) / Double(referenceWords) : nil
        }

        public static func + (lhs: Counts, rhs: Counts) -> Counts {
            Counts(referenceWords: lhs.referenceWords + rhs.referenceWords,
                   substitutions: lhs.substitutions + rhs.substitutions,
                   deletions: lhs.deletions + rhs.deletions,
                   insertions: lhs.insertions + rhs.insertions)
        }
    }

    /// Tokens for comparison.
    ///
    /// Folded through `TextFold.fold`, the matching form, so a correction that
    /// only adds a nikkud or swaps a final letter form does not read as a
    /// substitution. Punctuation is stripped for the same reason: Whisper's
    /// commas are not what anyone is measuring, and counting them would drown
    /// the signal that matters in a language where they are largely optional.
    public static func tokens(_ text: String) -> [String] {
        TextFold.fold(text)
            .split(whereSeparator: { $0 == " " })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein over words, with the three operations counted separately
    /// because they mean different things: a deletion is the model missing
    /// speech, an insertion is it inventing some, and §6.4 exists because the
    /// second happens.
    public static func compare(machine: String, human: String) -> Counts {
        align(hypothesis: tokens(machine), reference: tokens(human))
    }

    static func align(hypothesis: [String], reference: [String]) -> Counts {
        // Full matrix rather than the two-row trick: the backtrace is what
        // separates a substitution from a deletion plus an insertion, and at a
        // turn's length the memory is irrelevant.
        let n = reference.count, m = hypothesis.count
        guard n > 0 || m > 0 else { return Counts() }
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        for i in 1...max(n, 1) where n > 0 {
            for j in 1...max(m, 1) where m > 0 {
                if reference[i - 1] == hypothesis[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                } else {
                    cost[i][j] = 1 + Swift.min(cost[i - 1][j - 1],
                                               Swift.min(cost[i - 1][j], cost[i][j - 1]))
                }
            }
        }

        var counts = Counts(referenceWords: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                counts.substitutions += 1; i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                // A reference word the machine never produced.
                counts.deletions += 1; i -= 1
            } else {
                // A word the machine produced that nobody said.
                counts.insertions += 1; j -= 1
            }
        }
        return counts
    }
}
