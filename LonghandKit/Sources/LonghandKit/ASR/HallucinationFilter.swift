import Foundation

/// Whisper hallucination / non-speech mitigations (§6.4). VAD gating upstream
/// is the primary defense; these are the backstops. Nothing is silently
/// discarded: every suppression is recorded with a reason.
public enum HallucinationFilter {

    public struct Config: Sendable {
        /// Mean avgLogprob floor; only applied inside VAD-silent regions,
        /// low logprob alone also occurs on genuinely difficult speech.
        public var logprobFloor: Double
        /// Fraction of a segment that must intersect speech regions for the
        /// segment to count as "in speech".
        public var minSpeechOverlapFraction: Double
        /// Known hallucination artifacts, suppressed only in non-speech regions.
        public var boilerplate: [String]
        /// Minimum number of trailing repeats of a token block to trim.
        public var minRepeats: Int

        public init(logprobFloor: Double = -1.0,
                    minSpeechOverlapFraction: Double = 0.2,
                    boilerplate: [String] = Config.defaultBoilerplate,
                    minRepeats: Int = 3) {
            self.logprobFloor = logprobFloor
            self.minSpeechOverlapFraction = minSpeechOverlapFraction
            self.boilerplate = boilerplate
            self.minRepeats = minRepeats
        }

        public static let defaultBoilerplate: [String] = [
            "thanks for watching",
            "thank you for watching",
            "please subscribe",
            "subtitles by the amara.org community",
            "subtitles by",
            "www.mooji.org",
            "כתוביות על ידי",
            "תודה שצפיתם",
        ]
    }

    /// - Parameter speechRegions: VAD speech regions. `nil` means no VAD signal
    ///   is available, which disables the silence-conditioned rules.
    public static func filter(segments: [ASRSegment],
                              speechRegions: [ClosedRange<TimeInterval>]?,
                              config: Config = Config()) -> (kept: [ASRSegment], suppressed: [SuppressedSpan]) {
        var kept: [ASRSegment] = []
        var suppressed: [SuppressedSpan] = []
        var previousKeptText: String?

        for segment in segments {
            let inSilence = isInSilence(segment: segment, speechRegions: speechRegions,
                                        minOverlap: config.minSpeechOverlapFraction)
            let normalized = normalize(segment.text)

            // Boilerplate, only in non-speech regions.
            if inSilence, config.boilerplate.contains(where: { normalized.contains(normalize($0)) }) {
                suppressed.append(SuppressedSpan(start: segment.start, end: segment.end,
                                                 reason: .boilerplateInSilence, text: segment.text))
                continue
            }

            // Logprob suppression requires BOTH low logprob and VAD silence (§6.4).
            if inSilence, let lp = meanLogprob(segment), lp < config.logprobFloor {
                suppressed.append(SuppressedSpan(start: segment.start, end: segment.end,
                                                 reason: .lowLogprobInSilence, text: segment.text))
                continue
            }

            // Verbatim repeat of the previous segment's text.
            if let prev = previousKeptText, !normalized.isEmpty, normalized == prev {
                suppressed.append(SuppressedSpan(start: segment.start, end: segment.end,
                                                 reason: .verbatimRepeat, text: segment.text))
                continue
            }

            // Within-segment repetition loop: drop the repeated tail, not the segment.
            var segment = segment
            if let trimmed = trimRepeatedTail(segment, minRepeats: config.minRepeats) {
                suppressed.append(trimmed.span)
                segment = trimmed.segment
            }

            previousKeptText = normalize(segment.text)
            kept.append(segment)
        }
        return (kept, suppressed)
    }

    // MARK: - Internals

    static func isInSilence(segment: ASRSegment,
                            speechRegions: [ClosedRange<TimeInterval>]?,
                            minOverlap: Double) -> Bool {
        guard let regions = speechRegions else { return false }
        let duration = max(0.001, segment.end - segment.start)
        var overlap: TimeInterval = 0
        for r in regions {
            let lo = max(segment.start, r.lowerBound)
            let hi = min(segment.end, r.upperBound)
            if hi > lo { overlap += hi - lo }
        }
        return overlap / duration < minOverlap
    }

    static func meanLogprob(_ segment: ASRSegment) -> Double? {
        if let lp = segment.avgLogprob { return lp }
        let values = segment.words.compactMap(\.avgLogprob)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Finds a trailing cycle of `period` words repeated ≥ minRepeats times and
    /// trims all but the first occurrence.
    static func trimRepeatedTail(_ segment: ASRSegment, minRepeats: Int) -> (segment: ASRSegment, span: SuppressedSpan)? {
        let words = segment.words
        guard words.count >= minRepeats * 2 else { return nil }
        let tokens = words.map { normalize($0.text) }

        for period in 1...max(1, tokens.count / minRepeats) {
            var repeats = 1
            // Count trailing repetitions of the final `period`-token block.
            var i = tokens.count - period
            while i - period >= 0, Array(tokens[(i - period)..<i]) == Array(tokens[i..<(i + period)]) {
                repeats += 1
                i -= period
            }
            if repeats >= minRepeats {
                let keepCount = i + period   // first occurrence of the block stays
                let dropped = Array(words[keepCount...])
                guard let first = dropped.first, let last = dropped.last else { return nil }
                var trimmed = segment
                trimmed.words = Array(words[..<keepCount])
                trimmed.text = trimmed.words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                trimmed.end = trimmed.words.last?.end ?? segment.start
                let span = SuppressedSpan(start: first.start, end: last.end,
                                          reason: .repetitionTail,
                                          text: dropped.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
                return (trimmed, span)
            }
        }
        return nil
    }
}
