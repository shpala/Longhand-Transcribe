import Foundation

/// One diarization interval (§7.2). Intervals from different speakers may
/// overlap; the merge layer treats that as overlapped speech (§8.2).
public struct SpeakerInterval: Codable, Sendable, Equatable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public struct DiarizationResult: Codable, Sendable, Equatable {
    public var engine: String
    public var modelIdentifier: String
    public var intervals: [SpeakerInterval]
    /// Non-nil when the count was forced (§7.1); surfaced so the user can
    /// re-run without it if the audio contradicts it (§17).
    public var forcedSpeakerCount: Int?
    /// Per-cluster voice embeddings from the diarizer, when the backend
    /// exposes them. Input to §9 known-speaker identification; treated as
    /// biometric-like data (§14.1), persisted only inside the job folder and
    /// speaker profiles, never exported.
    public var centroids: [String: [Float]]?

    public init(engine: String, modelIdentifier: String, intervals: [SpeakerInterval],
                forcedSpeakerCount: Int? = nil, centroids: [String: [Float]]? = nil) {
        self.engine = engine
        self.modelIdentifier = modelIdentifier
        self.intervals = intervals
        self.forcedSpeakerCount = forcedSpeakerCount
        self.centroids = centroids
    }

    public var speakerIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for interval in intervals where seen.insert(interval.speaker).inserted {
            ordered.append(interval.speaker)
        }
        return ordered
    }

    /// Time ranges where two or more distinct speakers are active at once.
    public func overlappedRegions() -> [ClosedRange<TimeInterval>] {
        var regions: [ClosedRange<TimeInterval>] = []
        let sorted = intervals.sorted { $0.start < $1.start }
        for (i, a) in sorted.enumerated() {
            for b in sorted.dropFirst(i + 1) {
                if b.start >= a.end { break }
                guard b.speaker != a.speaker else { continue }
                let lo = max(a.start, b.start)
                let hi = min(a.end, b.end)
                if hi > lo { regions.append(lo...hi) }
            }
        }
        return Self.coalesce(regions)
    }

    static func coalesce(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<TimeInterval>] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = out[out.count - 1]
            if r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
