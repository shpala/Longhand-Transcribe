import Foundation

/// Parameters recorded per transcript so a re-merge is reproducible (§13.1).
public struct MergeParams: Codable, Sendable, Equatable {
    /// Boundary tolerance τ (§8). Both merge inputs are approximate; word
    /// timings drift ~100-300 ms and diarization boundaries are soft.
    public var boundaryTolerance: TimeInterval
    /// Max inter-word gap inside one conversational turn (§8.1).
    public var turnGap: TimeInterval
    /// Max distance to the nearest speaker interval before a word is UNKNOWN.
    public var nearestIntervalMaxGap: TimeInterval
    /// Smooth single-word islands flanked by the same speaker (§8.1).
    public var smoothIslands: Bool

    public init(boundaryTolerance: TimeInterval = 0.250,
                turnGap: TimeInterval = 1.0,
                nearestIntervalMaxGap: TimeInterval = 2.0,
                smoothIslands: Bool = true) {
        self.boundaryTolerance = boundaryTolerance
        self.turnGap = turnGap
        self.nearestIntervalMaxGap = nearestIntervalMaxGap
        self.smoothIslands = smoothIslands
    }

    public var record: Transcript.MergeParamsRecord {
        .init(boundaryToleranceMs: Int((boundaryTolerance * 1000).rounded()),
              turnGapSeconds: turnGap)
    }
}

/// Word-level attribution, always retained in 30_merged_words.json even when
/// the decision was made at segment level, so the merge can re-run with a
/// different τ without re-running inference (§8).
public struct MergedWord: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable {
        case segmentVote      // whole-segment winner (§8 step 1)
        case boundarySplit    // diarization boundary inside segment (§8 step 2)
        case hysteresis       // within τ of a change; inherited from run (§8 step 3)
        case wordOverlap      // largest raw temporal overlap (fallback)
        case midpoint         // speaker active at word midpoint
        case nearest          // closest interval within gap threshold
        case unknown          // no defensible attribution; never guess
    }

    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// nil means UNKNOWN.
    public var speaker: String?
    public var decision: Decision
    public var overlapped: Bool

    public init(text: String, start: TimeInterval, end: TimeInterval,
                speaker: String?, decision: Decision, overlapped: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.decision = decision
        self.overlapped = overlapped
    }
}

public struct MergeOutput: Codable, Sendable, Equatable {
    public var params: MergeParams
    public var words: [MergedWord]

    public init(params: MergeParams, words: [MergedWord]) {
        self.params = params
        self.words = words
    }
}

/// Deterministic word-to-speaker merge (§8): segment-first attribution with
/// word-level refinement and boundary hysteresis. Tested in MergeEngineTests,
/// including the ±300 ms jitter requirement (§18.2).
public enum MergeEngine {

    public static func merge(asr: ASRResult,
                             diarization: DiarizationResult,
                             params: MergeParams = MergeParams()) -> MergeOutput {
        let intervals = diarization.intervals.sorted { $0.start < $1.start }
        let overlapRegions = diarization.overlappedRegions()
        var out: [MergedWord] = []

        for segment in asr.segments {
            let attributed = attribute(segment: segment,
                                       intervals: intervals,
                                       params: params)
            for w in attributed {
                var w = w
                w.overlapped = isOverlapped(start: w.start, end: w.end, regions: overlapRegions)
                out.append(w)
            }
        }
        return MergeOutput(params: params, words: out)
    }

    // MARK: - Segment attribution

    private static func attribute(segment: ASRSegment,
                                  intervals: [SpeakerInterval],
                                  params: MergeParams) -> [MergedWord] {
        let τ = params.boundaryTolerance

        guard let segmentSpeaker = dominantSpeaker(start: segment.start, end: segment.end, intervals: intervals) else {
            // No diarization coverage of this segment at all: word-level fallbacks.
            return segment.words.map { word in
                fallbackAttribution(word: word, intervals: intervals, params: params)
            }
        }

        // Speaker-change boundaries strictly inside the segment with margin > τ
        // on both sides (§8: refine within a segment only on evidence).
        let boundaries = speakerChangeBoundaries(intervals: intervals)
            .filter { $0 > segment.start + τ && $0 < segment.end - τ }
            .sorted()

        if boundaries.isEmpty {
            return segment.words.map {
                MergedWord(text: $0.text, start: $0.start, end: $0.end,
                           speaker: segmentSpeaker, decision: .segmentVote, overlapped: false)
            }
        }

        // Sub-ranges between boundaries, each with its own dominant speaker.
        var edges = [segment.start]
        edges.append(contentsOf: boundaries)
        edges.append(segment.end)
        var subSpeakers: [String?] = []
        for i in 0..<(edges.count - 1) {
            subSpeakers.append(dominantSpeaker(start: edges[i], end: edges[i + 1], intervals: intervals) ?? segmentSpeaker)
        }

        var result: [MergedWord] = []
        for word in segment.words {
            let mid = word.midpoint
            var idx = 0
            while idx < boundaries.count && mid >= boundaries[idx] { idx += 1 }
            let nominal = subSpeakers[idx] ?? segmentSpeaker

            let nearBoundary = boundaries.contains { abs(mid - $0) < τ }
            if nearBoundary {
                // Hysteresis (§8): a word within τ of a change inherits from
                // the run it is contiguous with, or the segment vote, never the
                // raw overlap winner.
                let inherited: String
                if let previous = result.last, let prevSpeaker = previous.speaker,
                   word.start - previous.end <= τ {
                    inherited = prevSpeaker
                } else {
                    inherited = segmentSpeaker
                }
                result.append(MergedWord(text: word.text, start: word.start, end: word.end,
                                         speaker: inherited, decision: .hysteresis, overlapped: false))
            } else {
                result.append(MergedWord(text: word.text, start: word.start, end: word.end,
                                         speaker: nominal, decision: .boundarySplit, overlapped: false))
            }
        }
        return result
    }

    // MARK: - Word-level fallbacks (§8 remaining steps)

    private static func fallbackAttribution(word: ASRWord,
                                            intervals: [SpeakerInterval],
                                            params: MergeParams) -> MergedWord {
        // Largest raw temporal overlap.
        if let s = dominantSpeaker(start: word.start, end: word.end, intervals: intervals) {
            return MergedWord(text: word.text, start: word.start, end: word.end,
                              speaker: s, decision: .wordOverlap, overlapped: false)
        }
        // Speaker active at word midpoint.
        let mid = word.midpoint
        if let active = intervals.first(where: { $0.start <= mid && mid <= $0.end }) {
            return MergedWord(text: word.text, start: word.start, end: word.end,
                              speaker: active.speaker, decision: .midpoint, overlapped: false)
        }
        // Closest interval, only within a conservative gap threshold.
        var best: (speaker: String, gap: TimeInterval)?
        for interval in intervals {
            let gap: TimeInterval
            if interval.end < word.start { gap = word.start - interval.end }
            else if interval.start > word.end { gap = interval.start - word.end }
            else { gap = 0 }
            if best == nil || gap < best!.gap { best = (interval.speaker, gap) }
        }
        if let best, best.gap <= params.nearestIntervalMaxGap {
            return MergedWord(text: word.text, start: word.start, end: word.end,
                              speaker: best.speaker, decision: .nearest, overlapped: false)
        }
        // Otherwise UNKNOWN rather than guessing.
        return MergedWord(text: word.text, start: word.start, end: word.end,
                          speaker: nil, decision: .unknown, overlapped: false)
    }

    // MARK: - Helpers

    static func dominantSpeaker(start: TimeInterval, end: TimeInterval,
                                intervals: [SpeakerInterval]) -> String? {
        var totals: [String: TimeInterval] = [:]
        for interval in intervals {
            let lo = max(start, interval.start)
            let hi = min(end, interval.end)
            if hi > lo { totals[interval.speaker, default: 0] += hi - lo }
        }
        // Deterministic tie-break by speaker label.
        return totals.max { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key > b.key
        }?.key
    }

    /// Times where the set of active speakers changes from one dominant speaker
    /// to another, derived from interval edges.
    static func speakerChangeBoundaries(intervals: [SpeakerInterval]) -> [TimeInterval] {
        let edges = Set(intervals.flatMap { [$0.start, $0.end] }).sorted()
        var boundaries: [TimeInterval] = []
        var previousSpeaker: String?
        for i in 0..<max(0, edges.count - 1) {
            let mid = (edges[i] + edges[i + 1]) / 2
            let active = intervals
                .filter { $0.start <= mid && mid <= $0.end }
                .map(\.speaker)
                .sorted()
                .first
            if let active, let prev = previousSpeaker, active != prev {
                boundaries.append(edges[i])
            }
            if active != nil { previousSpeaker = active }
        }
        return boundaries
    }

    static func isOverlapped(start: TimeInterval, end: TimeInterval,
                             regions: [ClosedRange<TimeInterval>]) -> Bool {
        let dur = max(0.001, end - start)
        for region in regions {
            let lo = max(start, region.lowerBound)
            let hi = min(end, region.upperBound)
            let overlap = hi - lo
            if overlap > 0.05 || overlap > dur / 2 { return true }
        }
        return false
    }
}
