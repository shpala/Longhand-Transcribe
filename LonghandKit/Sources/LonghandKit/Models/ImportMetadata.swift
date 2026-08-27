import Foundation

/// Where a recording was captured. Lives in metadata.json ONLY, like
/// speaker embeddings (§14.1), location never enters transcript.json or any
/// export, so sharing a transcript cannot reveal where it was recorded.
public struct CapturedLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Meters; nil when the source (embedded file metadata) doesn't say.
    public var horizontalAccuracyMeters: Double?

    public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }

    /// Parses ISO 6709 annex-H strings as embedded by iOS in Voice Memos /
    /// camera files, e.g. "+32.0853+034.7818+000.000/" or "+3208.53-03447.8/"
    /// (degrees form only; the degrees-minutes forms are not emitted by iOS).
    public static func parseISO6709(_ string: String) -> CapturedLocation? {
        let trimmed = string.hasSuffix("/") ? String(string.dropLast()) : string
        // Signed groups: ±lat ±lon [±altitude]
        var groups: [String] = []
        var current = ""
        for ch in trimmed {
            if (ch == "+" || ch == "-") && !current.isEmpty {
                groups.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { groups.append(current) }
        guard groups.count >= 2,
              let lat = Double(groups[0]), let lon = Double(groups[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CapturedLocation(latitude: lat, longitude: lon)
    }
}

/// metadata.json, written at import (§5.2, §5.3). Channel measurements are
/// recorded but not branched on: the dual-channel diarizer bypass is deferred
/// behind the §5.3 gate, and these measurements are the evidence it needs.
public struct ImportMetadata: Codable, Sendable, Equatable {
    public var importedAt: Date
    public var sourceHash: String
    public var sourceFileSize: Int64
    public var sourceExtension: String
    /// Probe classification at ingest ("riffWave", "mpegElementaryStream", …).
    public var sourceFormat: String
    /// BCP-47; user-declared or defaulted, drives §4.2 engine routing.
    public var declaredLanguage: String?
    /// User-declared or structurally implied only, never inferred from the
    /// filename (§7.1).
    public var expectedSpeakerCount: Int?
    public var durationSeconds: TimeInterval?
    public var channelCount: Int?
    public var channelRMSEnergy: [Double]?
    public var interChannelCorrelation: Double?
    /// QuietBoost gain applied to the transient PCM at the last prepare
    /// (§5.4 addition); the retained original is never modified.
    public var appliedGainDb: Double?
    /// Capture location (one-shot at record start, or embedded metadata of
    /// an imported file). metadata.json only, never exported.
    public var location: CapturedLocation?
    /// Identifier the watch stamped on a take it sent, so the phone can report
    /// progress back for *that* take rather than "the newest job".
    public var sourceTakeID: String?

    public init(importedAt: Date, sourceHash: String, sourceFileSize: Int64,
                sourceExtension: String, sourceFormat: String,
                declaredLanguage: String? = nil, expectedSpeakerCount: Int? = nil,
                durationSeconds: TimeInterval? = nil, channelCount: Int? = nil,
                channelRMSEnergy: [Double]? = nil, interChannelCorrelation: Double? = nil,
                appliedGainDb: Double? = nil, location: CapturedLocation? = nil,
                sourceTakeID: String? = nil) {
        self.importedAt = importedAt
        self.sourceHash = sourceHash
        self.sourceFileSize = sourceFileSize
        self.sourceExtension = sourceExtension
        self.sourceFormat = sourceFormat
        self.declaredLanguage = declaredLanguage
        self.expectedSpeakerCount = expectedSpeakerCount
        self.durationSeconds = durationSeconds
        self.channelCount = channelCount
        self.channelRMSEnergy = channelRMSEnergy
        self.interChannelCorrelation = interChannelCorrelation
        self.appliedGainDb = appliedGainDb
        self.location = location
        self.sourceTakeID = sourceTakeID
    }
}
