import Foundation

/// Text normalization shared by search (§15.4) and by edit anchoring (§13.2).
/// Two folds, deliberately:
///
/// - `fold` is for matching. It strips nikkud and te'amim, folds final letter
///   forms, drops geresh/gershayim and removes bidi controls, which exports
///   inject, so a query pasted back from one still matches. It also falls back
///   to stripping Hebrew clitic prefixes off the query (see `ranges`).
/// - `foldForHash` is for identity, and removes only what carries no meaning.
///   Vowel points and case are meaning: an edit anchored to text differing by
///   a nikkud should read as stale rather than reattach.
public enum TextFold {

    // MARK: - Scalar classification

    /// Nikkud and te'amim. U+05BE (maqaf) and U+05C0 (paseq) are word
    /// separators, not marks, and are handled below.
    static func isHebrewMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0591...0x05BD, 0x05BF, 0x05C1...0x05C2, 0x05C4...0x05C7:
            return true
        default:
            return false
        }
    }

    /// LRM/RLM, the embedding/override run, and the isolate run. Exports inject
    /// these, so matching must ignore them.
    static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    /// Folded to their medial counterparts, so a query typed either way
    /// matches. Conflates מים and מימ, which for search is the right trade.
    static func foldedFinalForm(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.value {
        case 0x05DA: return Unicode.Scalar(0x05DB)   // ך → כ
        case 0x05DD: return Unicode.Scalar(0x05DE)   // ם → מ
        case 0x05DF: return Unicode.Scalar(0x05E0)   // ן → נ
        case 0x05E3: return Unicode.Scalar(0x05E4)   // ף → פ
        case 0x05E5: return Unicode.Scalar(0x05E6)   // ץ → צ
        default: return nil
        }
    }

    /// Geresh/gershayim and their ASCII stand-ins: ר״ה should match רה.
    static func isDroppedPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x05F3, 0x05F4, 0x0027, 0x0022, 0x2018, 0x2019, 0x201C, 0x201D:
            return true
        default:
            return false
        }
    }

    // MARK: - Hebrew clitic prefixes

    /// Hebrew has no space between a word and its one-letter clitics, so "to
    /// the doctor" is `לרופא`. A bare query already finds a prefixed occurrence
    /// by substring scan; the reverse does not, and that is the direction
    /// people type, since they search the word the way they heard it.
    ///
    /// Ordering is what makes stripping safe: the clitics attach in a fixed
    /// sequence, so `כשה` is a prefix and `הב` is the start of a word.
    static func cliticRank(_ character: Character) -> Int? {
        switch character {
        case "ו": return 0                                  // and
        case "ב", "כ", "ל", "מ": return 1                    // in / as / to / from
        case "ש": return 2                                  // that, which
        case "ה": return 3                                  // the
        default: return nil
        }
    }

    static func isHebrewLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        return (0x05D0...0x05EA).contains(Int(scalar.value))
    }

    /// The token with a leading clitic run removed, or nil when there is
    /// nothing safe to remove. Three guards, because over-stripping invents
    /// words: at most three clitics (`וכשה` is the longest run anyone writes),
    /// strictly ascending rank, and a remainder of at least three letters,
    /// which is what leaves `מים` alone rather than making it `ים`.
    static func hebrewStem(ofToken token: [Character]) -> [Character]? {
        guard token.count >= 4, token.allSatisfy(isHebrewLetter) else { return nil }
        var best: [Character]?
        var previousRank = -1
        for length in 1...min(3, token.count - 3) {
            guard let rank = cliticRank(token[length - 1]), rank > previousRank else { break }
            previousRank = rank
            best = Array(token.dropFirst(length))
        }
        return best
    }

    /// Whether `start` begins a word, allowing for a clitic run in front of it.
    /// Only the stemmed pass needs it: having claimed the query's leading
    /// letters were clitics, the match has to be a whole word under the same
    /// claim, or the fallback becomes a substring coincidence. `חלום` is not a
    /// hit for `שלום`, because `ח` is not a clitic.
    static func startsWordModuloClitics(_ folded: [Character], at start: Int) -> Bool {
        var index = start - 1
        var previousRank = Int.max
        var stripped = 0
        while index >= 0, stripped < 3 {
            let character = folded[index]
            if character == " " { return true }
            guard let rank = cliticRank(character), rank < previousRank else { return false }
            previousRank = rank
            stripped += 1
            index -= 1
        }
        return index < 0
    }

    /// Every token stemmed, or nil when none of them changed. Applied to the
    /// whole query at once: stemming only some tokens would leave a needle
    /// that no longer appears contiguously in either form.
    static func cliticStrippedNeedle(_ needle: [Character]) -> [Character]? {
        var result: [Character] = []
        var changed = false
        for token in needle.split(separator: " ", omittingEmptySubsequences: false) {
            if !result.isEmpty { result.append(" ") }
            if let stem = hebrewStem(ofToken: Array(token)) {
                result.append(contentsOf: stem)
                changed = true
            } else {
                result.append(contentsOf: token)
            }
        }
        return changed ? result : nil
    }

    // MARK: - Folding

    /// Folded characters plus, for each one, the index it came from in the
    /// original string, which is what lets `ranges(of:in:)` report positions
    /// into untouched text.
    static func foldedCharacters(of text: String) -> (folded: [Character], origin: [String.Index]) {
        var folded: [Character] = []
        var origin: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            defer { index = text.index(after: index) }

            if character.isWhitespace || character.isNewline {
                // Collapse runs; a leading space is trimmed at the end.
                if folded.last != " " {
                    folded.append(" ")
                    origin.append(index)
                }
                continue
            }

            var scalars = String.UnicodeScalarView()
            for scalar in String(character).precomposedStringWithCanonicalMapping.unicodeScalars {
                if isHebrewMark(scalar) || isBidiControl(scalar) || isDroppedPunctuation(scalar) {
                    continue
                }
                if scalar.value == 0x05BE || scalar.value == 0x05C0 {
                    // Maqaf and paseq join words; they become a separator, not
                    // nothing, so "בן־אדם" matches "בן אדם".
                    scalars.append(" ")
                    continue
                }
                scalars.append(foldedFinalForm(scalar) ?? scalar)
            }

            let piece = String(scalars).folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: nil)
            for produced in piece {
                if produced == " " && folded.last == " " { continue }
                folded.append(produced)
                origin.append(index)
            }
        }

        while folded.last == " " {
            folded.removeLast()
            origin.removeLast()
        }
        if folded.first == " " {
            folded.removeFirst()
            origin.removeFirst()
        }
        return (folded, origin)
    }

    /// Matching form: use for search, never for identity.
    public static func fold(_ text: String) -> String {
        String(foldedCharacters(of: text).folded)
    }

    /// Identity form: canonical composition, no bidi controls, whitespace
    /// normalized. Case and vowel points are preserved: they are content.
    public static func foldForHash(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if isBidiControl(scalar) { continue }
            let character = Character(scalar)
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Matching

    /// Ranges into the original string, so callers can highlight or slice
    /// without re-folding. Overlapping matches are not reported.
    ///
    /// A query carrying Hebrew clitic prefixes the text does not is retried
    /// without them, so `לרופא` finds `הרופא`. Only as a fallback: an exact hit
    /// wins, and the two result sets are never mixed.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = foldedCharacters(of: query).folded
        guard !needle.isEmpty else { return [] }
        let haystack = foldedCharacters(of: text)

        let literal = scan(needle: needle, haystack: haystack, in: text)
        if !literal.isEmpty { return literal }
        guard let stemmed = cliticStrippedNeedle(needle) else { return literal }
        return scan(needle: stemmed, haystack: haystack, in: text, atWordStart: true)
    }

    private static func scan(needle: [Character],
                             haystack: (folded: [Character], origin: [String.Index]),
                             in text: String,
                             atWordStart: Bool = false) -> [Range<String.Index>] {
        guard !needle.isEmpty, haystack.folded.count >= needle.count else { return [] }

        var results: [Range<String.Index>] = []
        var start = 0
        let limit = haystack.folded.count - needle.count
        while start <= limit {
            if atWordStart, !startsWordModuloClitics(haystack.folded, at: start) {
                start += 1
                continue
            }
            var offset = 0
            while offset < needle.count, haystack.folded[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count {
                let lower = haystack.origin[start]
                let upperOrigin = haystack.origin[start + needle.count - 1]
                results.append(lower..<text.index(after: upperOrigin))
                start += needle.count
            } else {
                start += 1
            }
        }
        return results
    }

    /// Whether `text` contains `query` under matching-fold rules.
    public static func contains(_ query: String, in text: String) -> Bool {
        !ranges(of: query, in: text).isEmpty
    }
}
