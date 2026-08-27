import Foundation

/// One recognized word with timing. Per §6.3 the score is a token log-probability,
/// not a calibrated confidence, so it must never be shown as a percentage. Engines
/// that cannot supply it omit the field; all consumers tolerate `nil`.
public struct ASRWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var avgLogprob: Double?

    public init(text: String, start: TimeInterval, end: TimeInterval, avgLogprob: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.avgLogprob = avgLogprob
    }

    public var midpoint: TimeInterval { (start + end) / 2 }
    public var duration: TimeInterval { max(0, end - start) }
}

/// A decoder segment: the stable unit the merge attributes first (§8).
public struct ASRSegment: Codable, Sendable, Equatable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [ASRWord]
    public var avgLogprob: Double?

    public init(id: Int, start: TimeInterval, end: TimeInterval, text: String, words: [ASRWord], avgLogprob: Double? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.avgLogprob = avgLogprob
    }
}

/// A span the hallucination filter removed, retained in 10_asr.json so the
/// behavior is auditable and thresholds tunable (§6.4 "never silently discard").
public struct SuppressedSpan: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case lowLogprobInSilence
        case boilerplateInSilence
        case verbatimRepeat
        case repetitionTail
    }

    public var start: TimeInterval
    public var end: TimeInterval
    public var reason: Reason
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, reason: Reason, text: String) {
        self.start = start
        self.end = end
        self.reason = reason
        self.text = text
    }
}

/// ASR output contract (§6.3). `engine` is required so a transcript can be
/// reproduced with the engine that produced it (§4.2, §13.1).
public struct ASRResult: Codable, Sendable, Equatable {
    public var language: String
    public var engine: String
    public var modelIdentifier: String
    public var segments: [ASRSegment]
    public var suppressedSpans: [SuppressedSpan]

    public init(language: String, engine: String, modelIdentifier: String, segments: [ASRSegment], suppressedSpans: [SuppressedSpan] = []) {
        self.language = language
        self.engine = engine
        self.modelIdentifier = modelIdentifier
        self.segments = segments
        self.suppressedSpans = suppressedSpans
    }

    public var words: [ASRWord] { segments.flatMap(\.words) }
}
