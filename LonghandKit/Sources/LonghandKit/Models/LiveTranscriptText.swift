import Foundation

/// The words of a recording as a live recognizer reports them: what it has
/// settled on, and the tail it is still revising. A recognizer that streams
/// sends a run of provisional results for the span it is still listening to,
/// each replacing the last, and then one final result for that span; the
/// final text is appended and the provisional text starts again from empty.
///
/// A preview only. Nothing here reaches a checkpoint, the overlay or an
/// export: the transcript is made afterwards from the whole file.
public struct LiveTranscriptText: Equatable, Sendable {

    /// Results the recognizer will not change again.
    public private(set) var confirmed = ""
    /// The recognizer's current guess for what is being said now.
    public private(set) var pending = ""

    public init() {}

    public var isEmpty: Bool { confirmed.isEmpty && pending.isEmpty }

    /// Both parts as one string, for a label that cannot style them apart.
    public var text: String {
        Self.joined(confirmed, pending)
    }

    public mutating func apply(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !trimmed.isEmpty { confirmed = Self.joined(confirmed, trimmed) }
            pending = ""
        } else {
            pending = trimmed
        }
    }

    /// Everything so far becomes settled: the recognizer was stopped, and its
    /// last guess is better than nothing.
    public mutating func settle() {
        if !pending.isEmpty { confirmed = Self.joined(confirmed, pending) }
        pending = ""
    }

    public mutating func clear() {
        confirmed = ""
        pending = ""
    }

    /// Words in the settled text, for a cap on how much a preview keeps.
    public var confirmedWordCount: Int {
        confirmed.split { $0.isWhitespace }.count
    }

    /// Drops the oldest settled words beyond `limit`, so an hour of
    /// listening does not hold an hour of text in a label.
    public mutating func trimConfirmed(toLastWords limit: Int) {
        let words = confirmed.split { $0.isWhitespace }
        guard words.count > limit else { return }
        confirmed = words.suffix(limit).joined(separator: " ")
    }

    private static func joined(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}
