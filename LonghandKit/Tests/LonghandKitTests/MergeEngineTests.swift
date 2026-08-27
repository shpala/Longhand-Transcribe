import Foundation
import Testing
@testable import LonghandKit

private func word(_ text: String, _ start: Double, _ end: Double, lp: Double? = -0.2) -> ASRWord {
    ASRWord(text: text, start: start, end: end, avgLogprob: lp)
}

private func segment(id: Int, _ words: [ASRWord]) -> ASRSegment {
    ASRSegment(id: id, start: words.first!.start, end: words.last!.end,
               text: words.map(\.text).joined(separator: " "), words: words)
}

private func asr(_ segments: [ASRSegment]) -> ASRResult {
    ASRResult(language: "en", engine: "test", modelIdentifier: "test/fixture", segments: segments)
}

private func diar(_ intervals: [SpeakerInterval]) -> DiarizationResult {
    DiarizationResult(engine: "test", modelIdentifier: "test/fixture", intervals: intervals)
}

@Suite struct MergeEngineTests {

    @Test func segmentVoteWinsForCleanTurns() {
        let a = asr([
            segment(id: 0, [word("hello", 0.5, 0.9), word("there", 1.0, 1.4)]),
            segment(id: 1, [word("hi", 5.2, 5.5), word("back", 5.6, 6.0)]),
        ])
        let d = diar([
            SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 4.0),
            SpeakerInterval(speaker: "SPEAKER_01", start: 5.0, end: 8.0),
        ])
        let out = MergeEngine.merge(asr: a, diarization: d)
        #expect(out.words.map(\.speaker) == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01", "SPEAKER_01"])
        #expect(out.words.allSatisfy { $0.decision == .segmentVote })
    }

    @Test func segmentVoteAveragesOutPerWordJitter() {
        // One segment fully inside SPEAKER_00's interval, but with a single word
        // whose jittered timing leaks past the interval edge. Argmax-per-word
        // would flip that word; segment-first attribution must not.
        let a = asr([
            segment(id: 0, [word("we", 0.2, 0.5), word("need", 0.55, 0.9),
                            word("this", 0.95, 1.3), word("done", 3.9, 4.3)]),
        ])
        let d = diar([
            SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 4.0),
            SpeakerInterval(speaker: "SPEAKER_01", start: 4.0, end: 8.0),
        ])
        let out = MergeEngine.merge(asr: a, diarization: d)
        #expect(out.words.map(\.speaker) == Array(repeating: "SPEAKER_00", count: 4))
    }

    @Test func splitsSegmentOnlyOnClearInternalBoundary() {
        // Diarization boundary at t=5.0 falls mid-segment with > τ margin on
        // both sides: the segment must split.
        let a = asr([
            segment(id: 0, [word("yes", 3.0, 3.4), word("but", 3.5, 3.9),
                            word("no", 6.0, 6.4), word("way", 6.5, 6.9)]),
        ])
        let d = diar([
            SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 5.0),
            SpeakerInterval(speaker: "SPEAKER_01", start: 5.0, end: 10.0),
        ])
        let out = MergeEngine.merge(asr: a, diarization: d)
        #expect(out.words.map(\.speaker) == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01", "SPEAKER_01"])
    }

    @Test func boundaryJitterOf300msDoesNotFlipAttribution() {
        // §18.2: perturb ASR word timings by ±300 ms and assert attribution is
        // stable for words whose true position is well inside a turn.
        let d = diar([
            SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 10.0),
            SpeakerInterval(speaker: "SPEAKER_01", start: 10.0, end: 20.0),
        ])
        // Words at 1 s spacing; true speaker known from true midpoint.
        let trueWords: [(String, Double)] = (0..<20).map { i in
            (i < 10 ? "SPEAKER_00" : "SPEAKER_01", Double(i) + 0.5)
        }
        var generator = SplitMix64(seed: 0x10046)
        for trial in 0..<25 {
            _ = trial
            var words: [ASRWord] = []
            for (_, mid) in trueWords {
                let jitter = (Double(generator.next() % 601) - 300) / 1000.0
                let m = mid + jitter
                words.append(word("w", m - 0.15, m + 0.15))
            }
            // Two segments matching the true turns, with jittered edges.
            let seg0 = ASRSegment(id: 0, start: words[0].start, end: words[9].end,
                                  text: "", words: Array(words[0..<10]))
            let seg1 = ASRSegment(id: 1, start: words[10].start, end: words[19].end,
                                  text: "", words: Array(words[10..<20]))
            let out = MergeEngine.merge(asr: asr([seg0, seg1]), diarization: d)
            for (i, merged) in out.words.enumerated() {
                let trueMid = trueWords[i].1
                // Only assert stability for words ≥ 0.5 s from the speaker change;
                // words at the boundary itself are covered by hysteresis rules.
                if abs(trueMid - 10.0) >= 0.5 {
                    #expect(merged.speaker == trueWords[i].0,
                            "word \(i) flipped attribution under jitter")
                }
            }
        }
    }

    @Test func unknownWhenNoDiarizationNearby() {
        let a = asr([segment(id: 0, [word("orphan", 100.0, 100.4)])])
        let d = diar([SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 5.0)])
        let out = MergeEngine.merge(asr: a, diarization: d)
        #expect(out.words[0].speaker == nil)
        #expect(out.words[0].decision == .unknown)
    }

    @Test func nearestIntervalWithinGapThreshold() {
        let a = asr([segment(id: 0, [word("close", 5.5, 5.9)])])
        let d = diar([SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 5.0)])
        let out = MergeEngine.merge(asr: a, diarization: d)
        #expect(out.words[0].speaker == "SPEAKER_00")
        #expect(out.words[0].decision == .nearest)
    }

    @Test func overlappedRegionsFlagWords() {
        let a = asr([segment(id: 0, [word("talk", 2.0, 2.5), word("clear", 6.0, 6.5)])])
        let d = diar([
            SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 4.0),
            SpeakerInterval(speaker: "SPEAKER_01", start: 1.5, end: 3.0),
            SpeakerInterval(speaker: "SPEAKER_00", start: 5.0, end: 8.0),
        ])
        let out = MergeEngine.merge(asr: a, diarization: d)
        #expect(out.words[0].overlapped == true)
        #expect(out.words[1].overlapped == false)
    }

    @Test func mergeIsDeterministic() {
        let a = asr([
            segment(id: 0, [word("a", 0.1, 0.4), word("b", 0.5, 0.8), word("c", 4.9, 5.3)]),
        ])
        let d = diar([
            SpeakerInterval(speaker: "SPEAKER_00", start: 0.0, end: 5.0),
            SpeakerInterval(speaker: "SPEAKER_01", start: 5.0, end: 9.0),
        ])
        let first = MergeEngine.merge(asr: a, diarization: d)
        for _ in 0..<10 {
            #expect(MergeEngine.merge(asr: a, diarization: d) == first)
        }
    }
}

/// Deterministic PRNG for jitter tests; Foundation's default RNG is seedless.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
