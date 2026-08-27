import Foundation
import Testing
@testable import LonghandKit

/// §15.4 pre-commits search to Hebrew-correct matching, "including
/// nikkud-insensitive matching if search is added". These are that promise,
/// written down.
@Suite struct TextFoldTests {

    @Test func nikkudIsIgnoredWhenMatching() {
        // "שָׁלוֹם" typed with vowel points, searched without them.
        #expect(TextFold.contains("שלום", in: "אמר שָׁלוֹם לכולם"))
        // …and the other way round: a pointed query against plain text.
        #expect(TextFold.contains("שָׁלוֹם", in: "אמר שלום לכולם"))
    }

    @Test func finalFormsMatchTheirMedialSpelling() {
        // People type the medial form mid-query; both must find the word.
        #expect(TextFold.contains("מים", in: "כוס מים על השולחן"))
        #expect(TextFold.contains("שלומ", in: "אמר שלום לכולם"))
    }

    @Test func gereshAndGershayimAreIgnored() {
        #expect(TextFold.contains("רה", in: "ערב ר״ה שמח"))
        #expect(TextFold.contains("צהל", in: "שירת בצה\"ל"))
    }

    @Test func maqafSeparatesRatherThanJoins() {
        #expect(TextFold.contains("בן אדם", in: "בן־אדם"))
    }

    /// Every export runs through `BidiText.isolatedForExport`, so text pasted
    /// back from one carries isolates. If folding didn't strip them, searching
    /// your own exported transcript would silently never match.
    @Test func bidiControlsFromExportsDoNotBlockMatching() {
        let exported = BidiText.isolatedForExport("שלום עולם")
        #expect(exported != "שלום עולם", "the fixture must actually carry isolates")
        #expect(TextFold.contains("שלום עולם", in: exported))
        #expect(TextFold.contains(exported, in: "אמר שלום עולם היום"))
    }

    @Test func latinMatchingIsCaseAndDiacriticInsensitive() {
        #expect(TextFold.contains("cafe", in: "at the Café today"))
        #expect(TextFold.contains("WEDNESDAY", in: "before wednesday"))
    }

    @Test func whitespaceRunsCollapse() {
        #expect(TextFold.contains("done before", in: "done\n  before"))
    }

    @Test func rangesPointIntoTheOriginalUnfoldedText() {
        let text = "אמר שָׁלוֹם לכולם"
        let ranges = TextFold.ranges(of: "שלום", in: text)
        #expect(ranges.count == 1)
        // The returned range must slice the *pointed* original, not a folded
        // copy, and that is what makes highlighting possible.
        #expect(text[ranges[0]] == "שָׁלוֹם")
    }

    @Test func rangesFindEveryNonOverlappingOccurrence() {
        let text = "test one, test two, test three"
        #expect(TextFold.ranges(of: "test", in: text).count == 3)
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(TextFold.ranges(of: "", in: "anything").isEmpty)
        #expect(TextFold.ranges(of: "   ", in: "anything").isEmpty)
    }

    @Test func codeSwitchedTurnMatchesInEitherScript() {
        let mixed = "אז אמרתי let's ship it מחר"
        #expect(TextFold.contains("let's ship", in: mixed))
        #expect(TextFold.contains("מחר", in: mixed))
    }

    // MARK: - Identity fold

    @Test func hashFoldKeepsMeaningAndDropsShape() {
        // Whitespace shape and bidi controls are noise…
        #expect(TextFold.foldForHash("  hello   world \n") == "hello world")
        #expect(TextFold.foldForHash(BidiText.isolatedForExport("שלום")) == "שלום")
        // …vowel points and case are content: an edit anchored to one is not
        // anchored to the other.
        #expect(TextFold.foldForHash("שָׁלוֹם") != TextFold.foldForHash("שלום"))
        #expect(TextFold.foldForHash("Hello") != TextFold.foldForHash("hello"))
    }
}

/// Hebrew writes its clitics attached, so the typed word and the transcribed
/// one often differ only by a leading letter. The substring scan covers one
/// direction already; these pin the other, and the guards on it.
@Suite struct HebrewCliticTests {

    @Test func aBareQueryStillFindsAPrefixedWord() {
        // The direction that always worked. Kept as a regression: the stemming
        // fallback must not disturb it.
        #expect(TextFold.contains("חוזה", in: "חתמנו על החוזה אתמול"))
        #expect(TextFold.contains("חוזה", in: "מדובר בחוזה השכירות"))
        #expect(TextFold.contains("רופא", in: "כשהרופא הגיע"))
    }

    @Test func aPrefixedQueryFindsTheBareWord() {
        #expect(TextFold.contains("בחוזה", in: "חתמנו על חוזה"))
        #expect(TextFold.contains("החוזה", in: "חתמנו על חוזה"))
        #expect(TextFold.contains("ולחוזה", in: "על חוזה"))
        // Three clitics is the longest run anyone writes.
        #expect(TextFold.contains("כשהחוזה", in: "החוזה נחתם"))
        // The realistic miss: you search the word the way you heard it said.
        #expect(TextFold.contains("לרופא", in: "הרופא אמר"))
    }

    @Test func stemmingNeverShortensAWordBelowThreeLetters() {
        // מים would become ים, which is a different word entirely.
        #expect(!TextFold.contains("מים", in: "הים כחול"))
        #expect(!TextFold.contains("הבן", in: "בן אדם"))
    }

    @Test func cliticsMustBeInTheOrderHebrewWritesThem() {
        // ה never precedes ב, so במב's leading ב is not strippable past it.
        #expect(!TextFold.contains("במב", in: "מב"))
    }

    @Test func aStemmedMatchMustStartAWord() {
        // שלום stems to לום, so the fallback may only land where the letters in
        // front of it are themselves clitics.
        #expect(!TextFold.contains("שלום", in: "חלום גדול"))
        #expect(!TextFold.contains("שלום", in: "תלום"))
        // The cost of that rule: כ is a clitic, so כלום stays reachable from
        // שלום, but only when the literal query found nothing at all.
        #expect(TextFold.contains("שלום", in: "כלום לא קרה"))
    }

    @Test func anExactHitAlwaysWinsOverAStemmedOne() {
        // Both forms are present; the reported range must be the literal one.
        let text = "בחוזה הזה, לא בחוזה הקודם"
        let ranges = TextFold.ranges(of: "בחוזה", in: text)
        #expect(ranges.count == 2)
        #expect(ranges.allSatisfy { String(text[$0]) == "בחוזה" })
    }

    @Test func stemmedRangesStillPointAtTheOriginalText() {
        let text = "אמרתי לרופא שהחוזה נחתם"
        #expect(TextFold.ranges(of: "בחוזה", in: text).map { String(text[$0]) } == ["חוזה"])
        #expect(TextFold.ranges(of: "לרופא", in: text).map { String(text[$0]) } == ["לרופא"])
    }

    @Test func nonHebrewIsUntouched() {
        #expect(TextFold.contains("the", in: "in the house"))
        #expect(!TextFold.contains("house", in: "in the barn"))
    }

    @Test func morphologyBeyondCliticsIsStillOutOfScope() {
        // Plurals and suffixes need a lexicon; this is prefix stripping only.
        #expect(!TextFold.contains("חוזים", in: "החוזה נחתם"))
    }
}

@Suite struct StableHashTests {

    @Test func hashIsStableAcrossCallsAndProcesses() {
        // A literal, not a recomputation: this is the value a stored anchor
        // has to keep matching after a relaunch.
        #expect(StableHash.hex("We need to get this done before Wednesday.")
                == StableHash.hex("We need to get this done before Wednesday."))
        #expect(StableHash.hex("") == "cbf29ce484222325")
        #expect(StableHash.hex("a") == "af63dc4c8601ec8c")
    }

    @Test func differentTextHashesDifferently() {
        #expect(StableHash.hex("שלום") != StableHash.hex("שלום."))
    }

    @Test func hashIsSixteenHexDigits() {
        let hash = StableHash.hex("anything at all")
        #expect(hash.count == 16)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
