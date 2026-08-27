import Foundation

/// Finding words in a transcript (§15.4).
///
/// Matching runs on `TextFold`, so a Hebrew query works whether or not it
/// carries nikkud, whether it uses final or medial letter forms, and whether
/// it was pasted back from an export with directional isolates in it. Ranges
/// come back pointing into the *original* text, which is what lets the UI
/// highlight without re-rendering a folded copy.
public enum TranscriptSearch {

    public struct Hit: Sendable, Equatable, Identifiable {
        /// Position in `transcript.turns`, for scrolling and word lookup.
        public let turnIndex: Int
        public let turnID: Int
        public let start: TimeInterval
        public let range: Range<String.Index>
        /// A short window of the turn around the match, for a results list.
        public let snippet: String

        init(turnIndex: Int, turnID: Int, start: TimeInterval,
             range: Range<String.Index>, snippet: String, occurrence: Int) {
            self.turnIndex = turnIndex
            self.turnID = turnID
            self.start = start
            self.range = range
            self.snippet = snippet
            self.id = "\(turnID)-\(occurrence)"
        }

        /// Identity for SwiftUI lists. Deliberately not derived from `range`:
        /// measuring an index taken from the turn's text against the snippet
        /// traps at runtime whenever the snippet is the shorter string.
        public let id: String
    }

    /// Characters of context shown on each side of a match in a snippet.
    static let snippetPadding = 32

    public static func matches(query: String, in transcript: Transcript) -> [Hit] {
        matches(query: query, in: transcript.turns)
    }

    public static func matches(query: String, in turns: [Transcript.Turn]) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var hits: [Hit] = []
        for (index, turn) in turns.enumerated() {
            for (occurrence, range) in TextFold.ranges(of: trimmed, in: turn.text).enumerated() {
                hits.append(Hit(turnIndex: index,
                                turnID: turn.id,
                                start: turn.start,
                                range: range,
                                snippet: snippet(around: range, in: turn.text),
                                occurrence: occurrence))
            }
        }
        return hits
    }

    /// Whether any turn matches, cheaper than collecting hits when a library
    /// row only needs to know "does this recording mention it".
    public static func containsMatch(query: String, in turns: [Transcript.Turn]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return turns.contains { TextFold.contains(trimmed, in: $0.text) }
    }

    static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -snippetPadding,
                               limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: snippetPadding,
                               limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > text.startIndex { snippet = "…" + snippet }
        if upper < text.endIndex { snippet += "…" }
        return snippet
    }
}
