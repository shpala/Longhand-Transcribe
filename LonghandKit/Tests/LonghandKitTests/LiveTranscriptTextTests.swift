import Foundation
import Testing
@testable import LonghandKit

@Suite struct LiveTranscriptTextTests {

    @Test func provisionalResultsReplaceEachOther() {
        var live = LiveTranscriptText()
        live.apply("we said", isFinal: false)
        live.apply("we said we would", isFinal: false)
        #expect(live.confirmed == "")
        #expect(live.pending == "we said we would")
        #expect(live.text == "we said we would")
    }

    @Test func aFinalResultIsAppendedAndClearsTheGuess() {
        var live = LiveTranscriptText()
        live.apply("we said we would", isFinal: false)
        live.apply("We said we would come back.", isFinal: true)
        #expect(live.confirmed == "We said we would come back.")
        #expect(live.pending == "")
        live.apply("so let", isFinal: false)
        #expect(live.text == "We said we would come back. so let")
    }

    @Test func settlingKeepsTheLastGuess() {
        var live = LiveTranscriptText()
        live.apply("First sentence.", isFinal: true)
        live.apply("and a half", isFinal: false)
        live.settle()
        #expect(live.confirmed == "First sentence. and a half")
        #expect(live.pending.isEmpty)
    }

    @Test func blankResultsChangeNothing() {
        var live = LiveTranscriptText()
        live.apply("   ", isFinal: true)
        live.apply("", isFinal: false)
        #expect(live.isEmpty)
    }

    @Test func trimmingKeepsTheNewestWords() {
        var live = LiveTranscriptText()
        live.apply((1...10).map { "w\($0)" }.joined(separator: " "), isFinal: true)
        live.trimConfirmed(toLastWords: 4)
        #expect(live.confirmed == "w7 w8 w9 w10")
        #expect(live.confirmedWordCount == 4)
    }
}
