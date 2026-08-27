import Foundation

/// Canonical transcript JSON (§13.1). This is the product's source of truth;
/// Markdown and TXT are derived exports.
public struct Transcript: Codable, Sendable, Equatable {
    public struct Models: Codable, Sendable, Equatable {
        /// Engine-qualified, e.g. "apple-speechtranscriber/ios26" or
        /// "whisperkit/large-v3-v20240930_626MB" (§4.2). Records substitutions (§17).
        public var asr: String
        public var diarization: String?
        public var speakerID: String?

        public init(asr: String, diarization: String? = nil, speakerID: String? = nil) {
            self.asr = asr
            self.diarization = diarization
            self.speakerID = speakerID
        }
    }

    public struct MergeParamsRecord: Codable, Sendable, Equatable {
        public var boundaryToleranceMs: Int
        public var turnGapSeconds: Double

        public init(boundaryToleranceMs: Int, turnGapSeconds: Double) {
            self.boundaryToleranceMs = boundaryToleranceMs
            self.turnGapSeconds = turnGapSeconds
        }
    }

    /// `matchScore` is the raw similarity from speaker ID; `confirmedByUser`
    /// distinguishes "the model thinks" from "the user said" (§9.3, §13.1).
    public struct Speaker: Codable, Sendable, Equatable {
        public var displayName: String
        public var matchScore: Double?
        public var confirmedByUser: Bool?

        public init(displayName: String, matchScore: Double? = nil, confirmedByUser: Bool? = nil) {
            self.displayName = displayName
            self.matchScore = matchScore
            self.confirmedByUser = confirmedByUser
        }
    }

    public struct Turn: Codable, Sendable, Equatable, Identifiable {
        /// Positional at build time, not a durable identity: anything
        /// persisted across a re-merge anchors on time + cluster instead
        /// (see `UserOverlay`).
        public var id: Int
        /// Diarization cluster key ("SPEAKER_00"), stable across renames (§15.3).
        public var cluster: String
        /// Resolved display name at export time.
        public var speaker: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var overlapped: Bool
        public var text: String
        /// Set when the user reassigned this turn. `cluster` keeps the
        /// diarizer's own claim, so centroid lookup and enrollment eligibility
        /// still read unmodified machine output (§9.2).
        public var assignedCluster: String?
        /// The word timings no longer describe the text, so the playback
        /// highlight falls back to turn level.
        public var edited: Bool?

        public init(id: Int, cluster: String, speaker: String, start: TimeInterval, end: TimeInterval,
                    overlapped: Bool, text: String,
                    assignedCluster: String? = nil, edited: Bool? = nil) {
            self.id = id
            self.cluster = cluster
            self.speaker = speaker
            self.start = start
            self.end = end
            self.overlapped = overlapped
            self.text = text
            self.assignedCluster = assignedCluster
            self.edited = edited
        }

        /// The cluster whose display name this turn should carry: the user's
        /// reassignment when there is one, the diarizer's otherwise.
        public var effectiveCluster: String { assignedCluster ?? cluster }
    }

    /// A moment the user flagged. Times are audio-timeline facts, so they need
    /// no anchoring.
    public struct Marker: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var time: TimeInterval
        public var label: String?

        public init(id: UUID = UUID(), time: TimeInterval, label: String? = nil) {
            self.id = id
            self.time = time
            self.label = label
        }
    }

    public var recordingID: String
    public var sourceHash: String
    public var duration: TimeInterval
    public var language: String
    public var pipelineVersion: String
    public var models: Models
    public var mergeParams: MergeParamsRecord
    public var speakers: [String: Speaker]
    public var turns: [Turn]
    /// User-flagged moments (§ addition). Optional so existing transcripts
    /// keep decoding and unmarked jobs add no key to the canonical JSON.
    public var markers: [Marker]?

    public init(recordingID: String, sourceHash: String, duration: TimeInterval, language: String,
                pipelineVersion: String, models: Models, mergeParams: MergeParamsRecord,
                speakers: [String: Speaker], turns: [Turn], markers: [Marker]? = nil) {
        self.recordingID = recordingID
        self.sourceHash = sourceHash
        self.duration = duration
        self.language = language
        self.pipelineVersion = pipelineVersion
        self.models = models
        self.mergeParams = mergeParams
        self.speakers = speakers
        self.turns = turns
        self.markers = markers
    }

    public static let currentPipelineVersion = "1.1.0"

    /// Falls back to the cluster key rather than inventing a claim (§9.3).
    public func displayName(forCluster cluster: String) -> String {
        speakers[cluster]?.displayName ?? cluster
    }
}
