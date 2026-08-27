import Foundation

/// Bidirectional-text helpers shared by UI and exporters (§15.4). Hebrew is a
/// first-class requirement; per-turn direction derives from content, never
/// from the app locale.
public enum BidiText {

    public enum Direction: String, Sendable {
        case ltr, rtl, neutral
    }

    static let isolateLTR = "\u{2066}"   // LRI
    static let isolateRTL = "\u{2067}"   // RLI
    static let isolateEnd = "\u{2069}"   // PDI

    static func isRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,   // Hebrew
             0x0600...0x06FF,   // Arabic
             0x0700...0x074F,   // Syriac
             0x0750...0x077F,   // Arabic Supplement
             0x08A0...0x08FF,   // Arabic Extended-A
             0xFB1D...0xFB4F,   // Hebrew presentation forms
             0xFB50...0xFDFF,   // Arabic presentation forms A
             0xFE70...0xFEFF:   // Arabic presentation forms B
            return true
        default:
            return false
        }
    }

    static func isStrongLTRScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard !isRTLScalar(scalar) else { return false }
        return scalar.properties.isAlphabetic
    }

    /// First-strong-character base direction, per UAX #9 heuristic P2/P3.
    public static func baseDirection(of text: String) -> Direction {
        for scalar in text.unicodeScalars {
            if isRTLScalar(scalar) { return .rtl }
            if isStrongLTRScalar(scalar) { return .ltr }
        }
        return .neutral
    }

    public static func containsRTL(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isRTLScalar)
    }

    /// Wraps text in a directional isolate matching its base direction when it
    /// contains any RTL content. Mixed-direction subtitle text needs explicit
    /// directional marks to render predictably in third-party players (§15.4);
    /// pure-LTR text is returned untouched.
    public static func isolatedForExport(_ text: String) -> String {
        guard containsRTL(text) else { return text }
        let open = baseDirection(of: text) == .rtl ? isolateRTL : isolateLTR
        return open + text + isolateEnd
    }
}
