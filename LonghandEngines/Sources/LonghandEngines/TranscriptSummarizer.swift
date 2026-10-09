import Foundation
import FoundationModels
import LonghandKit

/// A summary from the system's on-device language model (the Foundation
/// Models framework). Nothing leaves the device: the model is Apple's, runs
/// in a system process, and needs no download of its own. The app's earlier
/// attempt at this (an MLX build of Qwen inside the process, 26 Aug 2026)
/// was removed on cost; this one costs the app no memory and no package.
///
/// What it cannot do is the same as what the system cannot do: the model
/// speaks a fixed set of languages, and a Hebrew or Russian transcript is
/// refused up front with a reason rather than summarised into the wrong
/// language, which is what the small models did.
public nonisolated enum TranscriptSummarizer {

    public static let settingsKey = "summarizeAutomatically"
    public static let modelIdentifier = "apple-foundation-models"

    /// Below this there is nothing to summarise, and the model fills the gap:
    /// a simulator take whose only word was "Papa!" came back as "A man calls
    /// his father and has a conversation with him."
    public static let minimumWords = 25

    public static func isLongEnough(_ transcript: LonghandKit.Transcript) -> Bool {
        SummaryChunker.wordCount(of: transcript) >= minimumWords
    }

    /// The Settings toggle: write a summary when a transcript completes.
    /// **On by default** where the model is available, since it is free,
    /// local and silent, and off is one tap.
    public static var isAutomatic: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    public enum Availability: Equatable, Sendable {
        case available
        /// The model runs here but not in this language; the transcript's
        /// language tag is carried so the message can name it.
        case unsupportedLanguage(String)
        /// No model on this device, or Apple Intelligence is off, or the
        /// model is still downloading. The message is for a Settings footer.
        case unavailable(String)

        public var isAvailable: Bool { self == .available }

        /// One sentence for a footer or a button's reason for being disabled.
        public var explanation: String? {
            switch self {
            case .available: nil
            case let .unsupportedLanguage(language):
                "Apple's on-device model doesn't write \(Self.languageName(language)) yet, so this transcript can't be summarized."
            case let .unavailable(reason): reason
            }
        }

        static func languageName(_ tag: String) -> String {
            Locale.current.localizedString(forLanguageCode: tag) ?? tag
        }
    }

    /// Whether the device can summarise at all, before any language question.
    public static var deviceAvailability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("Summaries need a device that supports Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Summaries need Apple Intelligence, which is turned off in Settings.")
            case .modelNotReady:
                return .unavailable("Apple Intelligence is still preparing its model. Summaries will work once it's ready.")
            @unknown default:
                return .unavailable("Apple's on-device model isn't available right now.")
            }
        }
    }

    /// `language` is the transcript's BCP-47 tag. `nil` means unknown, which
    /// is left to the model: it refuses what it cannot read, and that refusal
    /// is reported like any other failure.
    public static func availability(for language: String?) -> Availability {
        let device = deviceAvailability
        guard device.isAvailable else { return device }
        guard let language, !language.isEmpty, language != JobPipeline.autoDetectLanguage else {
            return .available
        }
        return SystemLanguageModel.default.supportsLocale(Locale(identifier: language))
            ? .available
            : .unsupportedLanguage(language)
    }

    // MARK: - Generation

    /// One chunk's notes, in the model's own structure. Bullet lists rather
    /// than prose, so the final pass has facts to work from rather than a
    /// paragraph to paraphrase again.
    @Generable(description: "Notes on one part of a transcript")
    struct ChunkNotes {
        @Guide(description: "The main points discussed, as short bullet points, in the language of the transcript")
        var points: [String]
        @Guide(description: "Decisions that were made, as short bullet points; empty if none")
        var decisions: [String]
        @Guide(description: "Tasks someone agreed to do, naming who, as short bullet points; empty if none")
        var actionItems: [String]
    }

    @Generable(description: "A summary of a conversation")
    struct SummaryDraft {
        @Guide(description: "Two to four sentences saying what the conversation was about and how it ended, in the language of the transcript")
        var overview: String
        @Guide(description: "The most important points, as short bullet points, at most eight")
        var keyPoints: [String]
        @Guide(description: "Decisions that were made, as short bullet points; empty if none")
        var decisions: [String]
        @Guide(description: "Tasks someone agreed to do, naming who, as short bullet points; empty if none")
        var actionItems: [String]
    }

    static let instructions = """
        You summarize transcripts of recorded conversations and meetings. \
        The transcript is given as lines of "Name: words". Use only what is \
        in the transcript; never invent names, numbers or outcomes. Write in \
        the same language as the transcript. Be brief and concrete. Refer to \
        speakers by the names used in the transcript.
        """

    /// Summarises a transcript. Short transcripts take one pass; longer ones
    /// are read chunk by chunk and the chunk notes are summarised together,
    /// because the model's window is a few thousand tokens.
    ///
    /// Throws `LonghandError.summaryUnavailable` with a sentence a person can
    /// read; the framework's own errors are translated here so the UI never
    /// prints a debug description.
    public static func summarize(_ transcript: LonghandKit.Transcript, title: String) async throws -> TranscriptSummary {
        let availability = availability(for: transcript.language)
        if let explanation = availability.explanation {
            throw LonghandError.summaryUnavailable(reason: explanation)
        }
        let chunks = SummaryChunker.chunks(of: transcript)
        guard !chunks.isEmpty else {
            throw LonghandError.summaryUnavailable(reason: "There is no speech to summarize.")
        }
        guard isLongEnough(transcript) else {
            throw LonghandError.summaryUnavailable(reason: "This transcript is too short to summarize.")
        }
        let hash = TranscriptSummary.hash(of: transcript)
        do {
            let draft: SummaryDraft
            if chunks.count == 1 {
                draft = try await summarizeWhole(chunks[0].text, title: title)
            } else {
                var partNotes: [String] = []
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    let part = try await notes(for: chunk, index: index, of: chunks.count, title: title)
                    partNotes.append(render(part, index: index, start: chunk.start))
                }
                try Task.checkCancellation()
                draft = try await combine(partNotes, title: title)
            }
            var summary = TranscriptSummary(model: "\(modelIdentifier)/\(osTag)",
                                            transcriptHash: hash,
                                            overview: draft.overview,
                                            keyPoints: draft.keyPoints,
                                            decisions: draft.decisions,
                                            actionItems: draft.actionItems)
            summary.tidy()
            guard !summary.isEmpty else {
                throw LonghandError.summaryUnavailable(reason: "The model returned nothing for this transcript.")
            }
            return summary
        } catch let error as LonghandError {
            throw error
        } catch is CancellationError {
            throw LonghandError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw LonghandError.summaryUnavailable(reason: describe(error))
        } catch {
            throw LonghandError.summaryUnavailable(reason: error.localizedDescription)
        }
    }

    private static func summarizeWhole(_ text: String, title: String) async throws -> SummaryDraft {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(generating: SummaryDraft.self) {
            "Summarize this conversation, titled “\(title)”.\n\n\(text)"
        }
        return response.content
    }

    private static func notes(for chunk: SummaryChunker.Chunk, index: Int, of total: Int,
                              title: String) async throws -> ChunkNotes {
        // A fresh session per chunk: the window must hold the chunk, not the
        // conversation so far.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(generating: ChunkNotes.self) {
            "This is part \(index + 1) of \(total) of a conversation titled “\(title)”, starting at \(TranscriptClock.label(chunk.start)). Take notes on this part only.\n\n\(chunk.text)"
        }
        return response.content
    }

    private static func combine(_ notes: [String], title: String) async throws -> SummaryDraft {
        let session = LanguageModelSession(instructions: """
            \(instructions) You are given notes taken on consecutive parts of \
            one conversation. Combine them into one summary of the whole \
            conversation, merging repeated points and keeping the order of \
            events.
            """)
        let response = try await session.respond(generating: SummaryDraft.self) {
            "Notes on the conversation “\(title)”, in order:\n\n\(notes.joined(separator: "\n\n"))"
        }
        return response.content
    }

    /// Chunk notes as text for the combining pass.
    static func render(_ notes: ChunkNotes, index: Int, start: TimeInterval) -> String {
        var lines = ["Part \(index + 1), from \(TranscriptClock.label(start)):"]
        for point in TranscriptSummary.cleaned(notes.points) { lines.append("- \(point)") }
        for decision in TranscriptSummary.cleaned(notes.decisions) { lines.append("- Decision: \(decision)") }
        for item in TranscriptSummary.cleaned(notes.actionItems) { lines.append("- Action: \(item)") }
        return lines.joined(separator: "\n")
    }

    /// The framework's errors, in a sentence. `exceededContextWindowSize`
    /// should not happen behind the chunker; if it does, the budget is wrong
    /// and the message says to report it rather than pretending otherwise.
    static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .unsupportedLanguageOrLocale:
            "Apple's on-device model doesn't write this transcript's language yet."
        case .exceededContextWindowSize:
            "This transcript was too long for the model in one piece. Please report this."
        case .guardrailViolation:
            "Apple's on-device model declined to summarize this conversation."
        case .refusal:
            "Apple's on-device model declined to summarize this conversation."
        case .assetsUnavailable:
            "Apple Intelligence's model isn't ready on this device yet."
        case .rateLimited:
            "Apple's on-device model is busy. Try again in a moment."
        case .concurrentRequests:
            "Another summary is already being written."
        case .decodingFailure:
            "The model's answer couldn't be read. Try again."
        @unknown default:
            error.localizedDescription
        }
    }

    private static var osTag: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "macos\(version.majorVersion)"
        #else
        return "ios\(version.majorVersion)"
        #endif
    }
}
