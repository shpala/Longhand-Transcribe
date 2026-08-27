import Foundation
import Testing
@testable import LonghandKit

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> MergedWord {
    MergedWord(text: text, start: start, end: end, speaker: "SPEAKER_00",
               decision: .segmentVote, overlapped: false)
}

/// A flag is a moment, and the moment is the whole value: rendering it at the
/// nearest turn boundary can move it several sentences from what someone was
/// reacting to.
@Suite struct MarkerPlacementTests {

    private let words = [
        word("we", 0, 0.4), word("need", 0.4, 0.8), word("to", 0.8, 1.0),
        word("sign", 1.0, 1.5), word("before", 1.5, 2.0), word("Wednesday", 2.0, 2.8),
    ]

    @Test func placesAMarkerAtTheBoundaryItFellInto() {
        let marker = Transcript.Marker(time: 1.2, label: nil)
        let placed = MarkerPlacement.place([marker], in: words)
        #expect(placed.count == 1)
        // 1.2 s is inside "sign", so the flag belongs before "before".
        #expect(placed.first?.beforeWord == 4)
    }

    @Test func aFlagInsideTheLastWordLandsAfterIt() {
        let placed = MarkerPlacement.place([Transcript.Marker(time: 2.5)], in: words)
        #expect(placed.first?.beforeWord == words.count)
    }

    @Test func aFlagBeforeTheFirstWordIsStillThisTurnsIfItIsInSpan() {
        let placed = MarkerPlacement.place([Transcript.Marker(time: 0.0)], in: words)
        #expect(placed.first?.beforeWord == 1, "0.0 is inside the first word")
    }

    @Test func markersOutsideTheWordSpanAreNotPlacedHere() {
        // Belongs to a neighbouring turn; placing it anyway would show a flag
        // where nobody put one.
        #expect(MarkerPlacement.place([Transcript.Marker(time: 9)], in: words).isEmpty)
        #expect(MarkerPlacement.place([Transcript.Marker(time: -1)], in: words).isEmpty)
    }

    @Test func noWordsMeansNoPlacement() {
        // The caller's signal to fall back to a marker row: an edited turn's
        // words no longer describe its text, and older jobs have none.
        #expect(MarkerPlacement.place([Transcript.Marker(time: 1)], in: []).isEmpty)
    }

    @Test func placementIsOrderedByTime() {
        let markers = [Transcript.Marker(time: 2.2), Transcript.Marker(time: 0.5)]
        let placed = MarkerPlacement.place(markers, in: words)
        #expect(placed.map(\.beforeWord) == [2, 6])
    }

    @Test func contextQuotesWhatWasBeingSaid() {
        let quote = MarkerPlacement.context(around: Transcript.Marker(time: 1.2),
                                            in: words, radius: 2)
        #expect(quote == "to sign before Wednesday")
        #expect(MarkerPlacement.context(around: Transcript.Marker(time: 1.2), in: []) == nil)
    }
}
