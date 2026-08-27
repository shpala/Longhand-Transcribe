import Foundation

/// A §17 degradation: something the pipeline could not do, named rather than
/// silently absorbed.
///
/// The `kind` exists so behaviour can key off it. The message alone used to
/// carry that job: the transcript screen decided whether to offer the speaker
/// models by testing `hasPrefix("Diarization unavailable")` against prose
/// written three modules away, so rewording a user-facing sentence silently
/// removed a button. Prose is for reading; the kind is for switching on.
public struct Degradation: Codable, Sendable, Equatable, Hashable {

    public enum Kind: String, Codable, Sendable, Equatable {
        /// A transcript with timestamps and no speaker labels (§17).
        case diarizationUnavailable
        /// The take was quiet enough that the working copy was boosted (§5.4).
        case quietBoostApplied
        /// §4.2 routing could not honour the declared language and substituted
        /// another engine.
        case engineSubstituted
        /// A finished job with no turns, and a silent room behind it.
        case noSpeechDetected
        /// A finished job with no turns because the §6.4 filter took them.
        case speechFilteredAsHallucination
        /// Corrections that no longer fit the text after it changed (§13.2).
        case editsNotReattached
        /// Written by a version that knew a kind this one does not. Decoding
        /// keeps the message, so an unknown degradation is still shown.
        case unspecified
    }

    public var kind: Kind
    /// What the user reads. One sentence, already localized at the call site.
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case kind, message }

    /// Accepts the bare strings written before degradations were typed, so an
    /// existing `job.json` keeps decoding. This is the only place a degradation
    /// is identified by its prose, and it runs once per legacy record rather
    /// than on every render.
    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            kind = Degradation.inferKind(fromLegacy: legacy)
            message = legacy
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognized kind keeps its message rather than failing the whole
        // record: a job that cannot decode is worse than one whose note is
        // merely uncategorized.
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unspecified
        message = try container.decode(String.self, forKey: .message)
    }

    static func inferKind(fromLegacy message: String) -> Kind {
        switch true {
        case message.hasPrefix("Diarization unavailable"): .diarizationUnavailable
        case message.hasPrefix("Recording was very quiet"): .quietBoostApplied
        case message.hasPrefix("No engine"): .engineSubstituted
        case message.hasPrefix("No speech detected"): .noSpeechDetected
        case message.hasPrefix("No speech kept"): .speechFilteredAsHallucination
        case message.contains("could not be reattached"): .editsNotReattached
        default: .unspecified
        }
    }
}

public extension Array where Element == Degradation {
    /// Appends unless an identical note is already present. Stages re-run on
    /// resume, and the same degradation reached twice is one degradation.
    mutating func appendIfNew(_ degradation: Degradation) {
        guard !contains(degradation) else { return }
        append(degradation)
    }

    func contains(kind: Degradation.Kind) -> Bool {
        contains { $0.kind == kind }
    }
}
