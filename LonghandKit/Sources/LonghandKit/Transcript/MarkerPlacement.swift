import Foundation

/// Where a marker belongs inside a turn's words. Placement is between words
/// rather than on one: a marker does not mean "this word matters", it means
/// "here", the way a text cursor sits between characters.
public enum MarkerPlacement {

    /// A marker and the word index it precedes.
    public struct Placed: Equatable, Sendable {
        public let marker: Transcript.Marker
        /// In `0...words.count`, where `words.count` means after the last word.
        public let beforeWord: Int

        public init(marker: Transcript.Marker, beforeWord: Int) {
            self.marker = marker
            self.beforeWord = beforeWord
        }
    }

    /// The span comes from the words, not `turn.start...turn.end`: a turn's
    /// declared end can sit past its last word, and a flag pressed in that gap
    /// reads better at the end of the turn it followed.
    ///
    /// Empty when there are no words to place against, which is the caller's
    /// signal to fall back to a marker row.
    public static func place(_ markers: [Transcript.Marker],
                             in words: [MergedWord]) -> [Placed] {
        guard let first = words.first, let last = words.last else { return [] }
        return markers
            .filter { $0.time >= first.start && $0.time <= last.end }
            .sorted { $0.time < $1.time }
            .map { marker in
                // The first word that has not started yet is the boundary the
                // moment fell into; none means inside or after the last word.
                let index = words.firstIndex { $0.start > marker.time } ?? words.count
                return Placed(marker: marker, beforeWord: index)
            }
    }

    /// The words either side of a marker, for a row label that quotes what was
    /// being said where an inline flag cannot be drawn.
    public static func context(around marker: Transcript.Marker,
                               in words: [MergedWord],
                               radius: Int = 3) -> String? {
        let placed = place([marker], in: words)
        guard let position = placed.first?.beforeWord else { return nil }
        let lower = max(0, position - radius)
        let upper = min(words.count, position + radius)
        guard lower < upper else { return nil }
        return words[lower..<upper].map(\.text).joined(separator: " ")
    }
}
