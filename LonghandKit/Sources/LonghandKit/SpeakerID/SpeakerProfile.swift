import Foundation

/// An enrolled person (§9.2). Multiple embeddings per person are preferred
/// over a single clip; each embedding is tagged with the model that produced
/// it, because embeddings from different models are not comparable (§13.2).
/// Profiles are sensitive biometric-like data: stored locally only, complete
/// deletion supported, never included in any export (§14.1).
public struct SpeakerProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    /// Engine-qualified identifier of the embedder, e.g.
    /// "speakerkit/pyannote-community-1".
    public var modelIdentifier: String
    /// One entry per enrollment (§9.2: prefer samples from different
    /// acoustic conditions).
    public var embeddings: [[Float]]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), displayName: String, modelIdentifier: String,
                embeddings: [[Float]], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 40_identity.json checkpoint: which clusters matched which enrolled people,
/// under which parameters, so re-identification is reproducible (§13.2) and
/// auditable. Absence of a cluster here means "no claim": labels stay generic.
public struct IdentityResult: Codable, Sendable, Equatable {
    public var engine: String
    public var modelIdentifier: String
    public var scoreFloor: Double
    public var margin: Double
    /// Keyed by cluster ID ("SPEAKER_00").
    public var matches: [String: IdentityMatch]

    public init(engine: String, modelIdentifier: String,
                scoreFloor: Double, margin: Double,
                matches: [String: IdentityMatch]) {
        self.engine = engine
        self.modelIdentifier = modelIdentifier
        self.scoreFloor = scoreFloor
        self.margin = margin
        self.matches = matches
    }
}
