import Foundation
import Testing
@testable import LonghandKit

/// §15.2 ⟨R-16⟩: the scroll/playback performance test on the 60-minute corpus.
///
/// The trap ⟨R-16⟩ names is not slow code, it is code whose cost grows with the
/// transcript while the user is scrubbing an hour-long call. So these compare a
/// 15-minute corpus with a 60-minute one and assert the *per-operation* cost is
/// flat, rather than asserting a millisecond figure that says more about the
/// machine than the code. A linear scan where there should be an index shows up
/// as a factor of four; the threshold sits at 2.5, well clear of both.
///
/// Serialized, and each pair of measurements is interleaved, so a burst of load
/// lands on both sides of the ratio instead of only the slower one.
@Suite(.serialized) struct TranscriptScrollPerformanceTests {

    static let hour = 60.0
    static let quarter = 15.0

    // MARK: - Measuring

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// Fastest of several interleaved runs. The minimum, not the mean: a run
    /// can only be slowed by interference, never sped up by it.
    private static func ratio(runs: Int = 7,
                              small: () -> Void, large: () -> Void) -> Double {
        small(); large()   // warm both, so neither pays for a cold cache
        var bestSmall = Double.greatestFiniteMagnitude
        var bestLarge = Double.greatestFiniteMagnitude
        for _ in 0..<runs {
            bestSmall = min(bestSmall, seconds(ContinuousClock().measure(small)))
            bestLarge = min(bestLarge, seconds(ContinuousClock().measure(large)))
        }
        return bestLarge / bestSmall
    }

    /// Generous enough that ordinary noise cannot trip it, tight enough that
    /// the 4x a length-dependent implementation would show cannot pass.
    static let flat = 2.5

    // MARK: - The corpus

    @Test func theCorpusIsTheScaleTheDesignNames() {
        let words = TranscriptFixture.words(minutes: Self.hour)
        let turns = TranscriptFixture.turns(minutes: Self.hour)
        #expect((9_000...11_000).contains(words.count))
        #expect((200...900).contains(turns.count), "several hundred turns")
        #expect(abs((words.last?.end ?? 0) - 3600) < 300)
        // Turns come from the words, so every word must land in exactly one.
        let index = TranscriptIndex(turns: turns, words: words)
        let claimed = (0..<turns.count).reduce(0) { $0 + index.words(forTurnAt: $1).count }
        #expect(claimed == words.count)
    }

    // MARK: - Playback

    /// What `PlaybackTurnTracker` does on every tick of the 10 Hz observer.
    @Test func findingTheCurrentTurnCostsTheSameInAnHourAsInAQuarter() {
        let short = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.quarter),
                                    words: TranscriptFixture.words(minutes: Self.quarter))
        let long = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour),
                                   words: TranscriptFixture.words(minutes: Self.hour))

        func sweep(_ index: TranscriptIndex, duration: TimeInterval) -> () -> Void {
            {
                var hint: Int?
                let ticks = 20_000
                for tick in 0..<ticks {
                    let time = duration * Double(tick) / Double(ticks)
                    hint = index.turnIndex(at: time, from: hint)
                }
            }
        }

        let factor = Self.ratio(small: sweep(short, duration: Self.quarter * 60),
                                large: sweep(long, duration: Self.hour * 60))
        #expect(factor < Self.flat,
                "per-tick turn lookup grew with the transcript (x\(String(format: "%.2f", factor)))")
    }

    /// The karaoke highlight's lookup. It scans one turn's words, so a turn in
    /// an hour-long transcript must cost what the same turn costs in a short one.
    @Test func findingTheCurrentWordCostsTheSameInAnHourAsInAQuarter() {
        let short = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.quarter),
                                    words: TranscriptFixture.words(minutes: Self.quarter))
        let long = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour),
                                   words: TranscriptFixture.words(minutes: Self.hour))

        func sweep(_ index: TranscriptIndex) -> () -> Void {
            {
                for call in 0..<20_000 {
                    let turn = call % index.turns.count
                    let bounds = index.turns[turn]
                    _ = index.wordIndex(at: (bounds.start + bounds.end) / 2, inTurnAt: turn)
                }
            }
        }

        let factor = Self.ratio(small: sweep(short), large: sweep(long))
        #expect(factor < Self.flat,
                "per-word lookup grew with the transcript (x\(String(format: "%.2f", factor)))")
    }

    /// Scrubbing lands nowhere near the hint, so every seek falls back to the
    /// search. That search is the one ⟨R-16⟩ is about: a scan here is what makes
    /// dragging through an hour feel worse than dragging through a minute.
    @Test func seekingCostsTheSameInAnHourAsInAQuarter() {
        let short = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.quarter))
        let long = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour))

        // A fixed jumble rather than a random one: both sides must seek to the
        // same fractions of their own timeline, or the ratio measures the seeks.
        let fractions = (0..<20_000).map { Double(($0 * 7919) % 10_000) / 10_000 }

        func drag(_ index: TranscriptIndex, duration: TimeInterval) -> () -> Void {
            { for fraction in fractions { _ = index.turnIndex(at: fraction * duration) } }
        }

        let factor = Self.ratio(small: drag(short, duration: Self.quarter * 60),
                                large: drag(long, duration: Self.hour * 60))
        #expect(factor < Self.flat,
                "seeking grew with the transcript (x\(String(format: "%.2f", factor)))")
    }

    /// The cursor form is what actually runs during playback; the search form is
    /// what it has to agree with. A fast path that drifts lights the wrong turn.
    @Test func theCursorAgreesWithTheSearchOverAWholeHour() {
        let index = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour),
                                    words: TranscriptFixture.words(minutes: Self.hour))
        var hint: Int?
        for tick in 0..<36_000 {          // an hour at 10 Hz
            let time = Double(tick) / 10
            let cursor = index.turnIndex(at: time, from: hint)
            #expect(cursor == index.turnIndex(at: time))
            hint = cursor
        }
    }

    /// Scrubbing, which is where ⟨R-16⟩ says the product feels broken. The hint
    /// is far behind or far ahead on every one of these.
    @Test func theCursorSurvivesScrubbingBackAndForth() {
        let index = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour),
                                    words: TranscriptFixture.words(minutes: Self.hour))
        var hint: Int? = 0
        for time in stride(from: 3590.0, through: 0, by: -7) {
            hint = index.turnIndex(at: time, from: hint)
            #expect(hint == index.turnIndex(at: time))
        }
    }

    // MARK: - The list body

    /// Drawn once per turn, so a `filter` behind it is the O(n squared) the
    /// source comment warns about: flat per call here, quadratic in the list.
    @Test func theRenameChipCountIsPrecomputedRatherThanCounted() {
        let short = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.quarter))
        let long = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour))

        func ask(_ index: TranscriptIndex) -> () -> Void {
            { for call in 0..<50_000 { _ = index.passageCount(forCluster: "SPEAKER_0\(call % 2)") } }
        }

        let factor = Self.ratio(small: ask(short), large: ask(long))
        #expect(factor < Self.flat,
                "passage counting grew with the transcript (x\(String(format: "%.2f", factor)))")
    }

    /// Paid once when the screen opens. Linear is 4x for a 4x corpus; the
    /// nested-loop join it replaced would be 16x.
    @Test func buildingTheIndexIsOnePassOverBothSequences() {
        let shortTurns = TranscriptFixture.turns(minutes: Self.quarter)
        let shortWords = TranscriptFixture.words(minutes: Self.quarter)
        let longTurns = TranscriptFixture.turns(minutes: Self.hour)
        let longWords = TranscriptFixture.words(minutes: Self.hour)

        let factor = Self.ratio(
            small: { _ = TranscriptIndex(turns: shortTurns, words: shortWords) },
            large: { _ = TranscriptIndex(turns: longTurns, words: longWords) })
        #expect(factor < 8, "index build is superlinear (x\(String(format: "%.2f", factor)))")
    }

    /// Both forms are logarithmic, so no size ratio can tell them apart: the
    /// cursor is a constant factor, and this is the only test that would notice
    /// it being dropped. Measured at ~1.9x; asserted well below that.
    @Test func thePlaybackCursorIsWorthKeeping() {
        let index = TranscriptIndex(turns: TranscriptFixture.turns(minutes: Self.hour))
        let ticks = 20_000
        func time(_ tick: Int) -> TimeInterval { 3600 * Double(tick) / Double(ticks) }

        let factor = Self.ratio(
            small: { var hint: Int?
                     for tick in 0..<ticks { hint = index.turnIndex(at: time(tick), from: hint) } },
            large: { for tick in 0..<ticks { _ = index.turnIndex(at: time(tick)) } })
        #expect(factor > 1.4,
                "the cursor no longer beats a fresh search (x\(String(format: "%.2f", factor)))")
    }

    // MARK: - Anchoring

    /// §15.2 requires scroll anchoring that survives a speaker rename. The list
    /// anchors on `turn.id`, so a rename must not move one: the rows would jump
    /// under a reader who has scrolled away from playback.
    @Test func renamingASpeakerMovesNoAnchor() {
        let words = TranscriptFixture.words(minutes: Self.hour)
        let raw = TurnBuilder.buildTurns(words: words)
        let before = TurnBuilder.transcriptTurns(from: raw, speakers: [:])
        let after = TurnBuilder.transcriptTurns(from: raw, speakers: [
            "SPEAKER_00": .init(displayName: "Pavel", confirmedByUser: true),
            "SPEAKER_01": .init(displayName: "Emilia", confirmedByUser: true),
        ])

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.start) == after.map(\.start))
        #expect(before.map(\.text) == after.map(\.text))
        #expect(after.contains { $0.speaker == "Pavel" }, "the rename did apply")
    }
}
