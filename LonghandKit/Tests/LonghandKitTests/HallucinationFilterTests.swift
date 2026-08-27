import Foundation
import Testing
@testable import LonghandKit

private func seg(_ id: Int, _ text: String, _ start: Double, _ end: Double,
                 lp: Double? = -0.2) -> ASRSegment {
    let tokens = text.split(separator: " ").map(String.init)
    let dur = (end - start) / Double(max(1, tokens.count))
    let words = tokens.enumerated().map { i, t in
        ASRWord(text: t, start: start + Double(i) * dur, end: start + Double(i + 1) * dur, avgLogprob: lp)
    }
    return ASRSegment(id: id, start: start, end: end, text: text, words: words, avgLogprob: lp)
}

@Suite struct HallucinationFilterTests {

    let speech: [ClosedRange<Double>] = [0.0...60.0]          // speech in the first minute
    // 60-300 s is silence.

    @Test func suppressesLowLogprobSegmentInSilence() {
        let segments = [
            seg(0, "real speech here", 10, 13, lp: -0.3),
            seg(1, "ghost words", 120, 123, lp: -1.8),
        ]
        let (kept, suppressed) = HallucinationFilter.filter(segments: segments, speechRegions: speech)
        #expect(kept.map(\.id) == [0])
        #expect(suppressed.count == 1)
        #expect(suppressed[0].reason == .lowLogprobInSilence)
    }

    @Test func keepsLowLogprobSegmentInSpeech() {
        // Low logprob alone also occurs on genuinely difficult speech (§6.4);
        // silently dropping hard audio is worse than the hallucination.
        let segments = [seg(0, "mumbled difficult audio", 10, 13, lp: -1.8)]
        let (kept, suppressed) = HallucinationFilter.filter(segments: segments, speechRegions: speech)
        #expect(kept.count == 1)
        #expect(suppressed.isEmpty)
    }

    @Test func suppressesBoilerplateOnlyInSilence() {
        let segments = [
            seg(0, "Thanks for watching", 20, 22, lp: -0.4),    // in speech → kept
            seg(1, "Thanks for watching", 200, 202, lp: -0.4),  // in silence → suppressed
        ]
        let (kept, suppressed) = HallucinationFilter.filter(segments: segments, speechRegions: speech)
        #expect(kept.map(\.id) == [0])
        #expect(suppressed.count == 1)
        #expect(suppressed[0].reason == .boilerplateInSilence)
    }

    @Test func suppressesVerbatimRepeatOfPreviousSegment() {
        let segments = [
            seg(0, "we should ship on Wednesday", 10, 13),
            seg(1, "we should ship on Wednesday", 13, 16),
            seg(2, "agreed", 16, 17),
        ]
        let (kept, suppressed) = HallucinationFilter.filter(segments: segments, speechRegions: speech)
        #expect(kept.map(\.id) == [0, 2])
        #expect(suppressed.count == 1)
        #expect(suppressed[0].reason == .verbatimRepeat)
    }

    @Test func trimsRepeatedTailNotWholeSegment() {
        let segments = [seg(0, "the plan is go go go go go go", 10, 17)]
        let (kept, suppressed) = HallucinationFilter.filter(segments: segments, speechRegions: speech)
        #expect(kept.count == 1)
        #expect(kept[0].text == "the plan is go")
        #expect(suppressed.count == 1)
        #expect(suppressed[0].reason == .repetitionTail)
        #expect(suppressed[0].text.split(separator: " ").allSatisfy { $0 == "go" })
    }

    @Test func noVADSignalDisablesSilenceRules() {
        let segments = [seg(0, "quiet ghost", 120, 122, lp: -1.9)]
        let (kept, suppressed) = HallucinationFilter.filter(segments: segments, speechRegions: nil)
        #expect(kept.count == 1)
        #expect(suppressed.isEmpty)
    }

    @Test func longSilenceCorpusEmitsNoWordsInSilentRegions() {
        // §18.2 hallucination test in miniature: everything inside VAD-silent
        // regions with hallucination markers is suppressed; real speech survives.
        let segments = [
            seg(0, "hello this is a real call", 5, 8, lp: -0.25),
            seg(1, "Subtitles by the Amara.org community", 90, 93, lp: -0.6),
            seg(2, "ghostly murmur", 150, 152, lp: -1.4),
            seg(3, "and we are back", 30, 32, lp: -0.3),
        ]
        let (kept, _) = HallucinationFilter.filter(segments: segments, speechRegions: speech)
        for segment in kept {
            #expect(segment.start < 60.0, "no emitted words in VAD-silent regions")
        }
        #expect(kept.count == 2)
    }
}
