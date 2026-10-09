import Foundation

/// A summary of a finished transcript, written by a language model on the
/// device and kept beside the transcript in `summary.json`.
///
/// Neither a checkpoint nor overlay content. It is derived from the transcript
/// the way the exports are, but by a model whose output is not reproducible,
/// so it is cached rather than rebuilt on every rerender. A person may edit
/// it, and the edit replaces the text rather than layering over it: there is
/// no machine text to un-edit back to, only another generation.
///
/// `transcriptHash` records what the summary described. The transcript
/// changes under it on every correction, and most corrections (a name, a
/// mistyped word) do not change what the summary should say, so a stale
/// summary stays and is labelled, never dropped. A re-transcribe deletes it:
/// the words it summarised are gone.
public struct TranscriptSummary: Codable, Sendable, Equatable {

    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    /// Who wrote it, e.g. "apple-foundation-models/ios26", or "user" after an
    /// edit replaced the generated text.
    public var model: String
    /// Hash of the transcript text this summary was written for.
    public var transcriptHash: String
    /// A short paragraph.
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    /// Set once a person has changed the text, so regeneration can warn
    /// before overwriting it.
    public var editedAt: Date?

    public init(version: Int = TranscriptSummary.currentVersion,
                generatedAt: Date = Date(),
                model: String,
                transcriptHash: String,
                overview: String,
                keyPoints: [String] = [],
                decisions: [String] = [],
                actionItems: [String] = [],
                editedAt: Date? = nil) {
        self.version = version
        self.generatedAt = generatedAt
        self.model = model
        self.transcriptHash = transcriptHash
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.editedAt = editedAt
    }

    public var isEdited: Bool { editedAt != nil }

    /// Nothing at all to show: a model that returned empty fields, or an edit
    /// that cleared everything.
    public var isEmpty: Bool {
        overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.cleaned(keyPoints).isEmpty && Self.cleaned(decisions).isEmpty
            && Self.cleaned(actionItems).isEmpty
    }

    // MARK: - Staleness

    /// Over the words and who said them, folded so a change of punctuation
    /// or case does not count. Speaker names are included: renaming "Speaker
    /// 2" to "Dana" changes what a summary should say.
    public static func hash(of transcript: Transcript) -> String {
        let text = transcript.turns
            .map { "\(wordsOnly($0.speaker)): \(wordsOnly($0.text))" }
            .joined(separator: "\n")
        return StableHash.hex(text)
    }

    /// Letters and digits, lowercased, one space between words. Looser than
    /// `TextFold.foldForHash`, which keeps case and punctuation because an
    /// edit anchor must notice them; a summary need not.
    static func wordsOnly(_ text: String) -> String {
        TextFold.fold(text).lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: " ")
    }

    public func isCurrent(for transcript: Transcript) -> Bool {
        transcriptHash == Self.hash(of: transcript)
    }

    // MARK: - Text forms

    /// Markdown, for the transcript export and the clipboard. Headings sit one
    /// level under the export's own title.
    public var markdown: String {
        var lines: [String] = []
        let overview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty {
            lines.append(BidiText.isolatedForExport(overview))
            lines.append("")
        }
        func section(_ title: String, _ items: [String]) {
            let items = Self.cleaned(items)
            guard !items.isEmpty else { return }
            lines.append("### \(title)")
            lines.append("")
            for item in items { lines.append("- \(BidiText.isolatedForExport(item))") }
            lines.append("")
        }
        section("Key points", keyPoints)
        section("Decisions", decisions)
        section("Action items", actionItems)
        return lines.joined(separator: "\n")
    }

    /// The same content without markup, for copying into a message.
    public var plainText: String {
        var lines: [String] = []
        let overview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty {
            lines.append(overview)
            lines.append("")
        }
        func section(_ title: String, _ items: [String]) {
            let items = Self.cleaned(items)
            guard !items.isEmpty else { return }
            lines.append(title)
            for item in items { lines.append("• \(item)") }
            lines.append("")
        }
        section("Key points", keyPoints)
        section("Decisions", decisions)
        section("Action items", actionItems)
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Trimmed, with blank entries dropped: a model, and a person editing in a
    /// text field, both produce them.
    public static func cleaned(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Normalises the lists in place, the way `cleaned` reads them.
    public mutating func tidy() {
        overview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        keyPoints = Self.cleaned(keyPoints)
        decisions = Self.cleaned(decisions)
        actionItems = Self.cleaned(actionItems)
    }
}

/// Cuts a transcript into pieces a small on-device model can read in one
/// prompt. The model's context is a few thousand tokens, and an hour of
/// conversation is several times that, so a long transcript is summarised
/// chunk by chunk and the chunk summaries are then summarised together.
///
/// Pure, so it is tested here rather than against a model.
public enum SummaryChunker {

    /// One piece of the transcript as the model will read it: "Name: words"
    /// lines, in order.
    public struct Chunk: Equatable, Sendable {
        public var text: String
        public var wordCount: Int
        /// Where in the recording the chunk starts, for the model's benefit
        /// and for anyone reading the prompt.
        public var start: TimeInterval

        public init(text: String, wordCount: Int, start: TimeInterval) {
            self.text = text
            self.wordCount = wordCount
            self.start = start
        }
    }

    /// Words, not tokens: the tokenizer is the model's business, and Hebrew
    /// or Russian cost more tokens per word than English. The default leaves
    /// room for the instructions and the answer inside a 4096-token window at
    /// the worst ratio seen.
    public static let defaultMaxWords = 1100

    public static func chunks(of transcript: Transcript,
                              maxWords: Int = defaultMaxWords) -> [Chunk] {
        var chunks: [Chunk] = []
        var lines: [String] = []
        var words = 0
        var chunkStart: TimeInterval?

        func flush() {
            guard !lines.isEmpty else { return }
            chunks.append(Chunk(text: lines.joined(separator: "\n"), wordCount: words,
                                start: chunkStart ?? 0))
            lines = []
            words = 0
            chunkStart = nil
        }

        for turn in transcript.turns {
            let turnWords = turn.text.split { $0.isWhitespace || $0.isNewline }
            guard !turnWords.isEmpty else { continue }
            // A turn is kept whole when the next chunk has room for it.
            if words > 0, words + turnWords.count > maxWords { flush() }
            // A single turn longer than the budget is cut, so a monologue
            // cannot produce a chunk nothing can read.
            var offset = 0
            while offset < turnWords.count {
                let room = max(1, maxWords - words)
                let piece = turnWords[offset..<min(turnWords.count, offset + room)]
                if chunkStart == nil { chunkStart = turn.start }
                lines.append("\(turn.speaker): \(piece.joined(separator: " "))")
                words += piece.count
                offset += piece.count
                if words >= maxWords { flush() }
            }
        }
        flush()
        return chunks
    }

    /// The whole transcript's word count, which decides whether one pass is
    /// enough.
    public static func wordCount(of transcript: Transcript) -> Int {
        transcript.turns.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count }
    }
}
