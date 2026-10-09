import Foundation

/// File names for what leaves the app. Every job's exports are written as
/// `transcript.md`, `transcript.txt` and `transcript.json` inside the job
/// folder, which is right for the folder and wrong for a share sheet: three
/// recordings sent to the same person all arrive as `transcript.md`. The
/// shared copy is named after the recording instead.
public enum ExportNaming {

    public enum Kind: Sendable {
        case markdown, text, json
        /// The retained original; keeps its own extension.
        case audio(fileExtension: String)

        var suffix: String {
            switch self {
            case .markdown: " transcript.md"
            case .text: " transcript.txt"
            case .json: " transcript.json"
            case let .audio(ext): ext.isEmpty ? "" : ".\(ext.lowercased())"
            }
        }
    }

    /// "Weekly sync transcript.md", or "Recording transcript.md" for an
    /// empty title. Characters a file system or a share target refuses are
    /// replaced, runs of space collapsed, and the stem kept under a length
    /// Mail and Files are happy with.
    public static func fileName(title: String, kind: Kind, maxStemLength: Int = 80) -> String {
        var stem = sanitized(title)
        if stem.isEmpty { stem = "Recording" }
        if stem.count > maxStemLength {
            stem = String(stem.prefix(maxStemLength)).trimmingCharacters(in: .whitespaces)
        }
        return stem + kind.suffix
    }

    /// Path separators and the characters Windows and SMB shares reject, since
    /// an AirDropped file can end up anywhere. Leading dots would hide the
    /// file; trailing dots and spaces are stripped by other systems.
    static func sanitized(_ title: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var result = ""
        var lastWasSpace = false
        for character in title {
            let mapped: Character = forbidden.contains(character) ? "-" : character
            if mapped.isWhitespace || mapped.isNewline {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                continue
            } else {
                result.append(mapped)
                lastWasSpace = false
            }
        }
        while let first = result.first, first == "." || first == " " { result.removeFirst() }
        while let last = result.last, last == "." || last == " " { result.removeLast() }
        return result
    }
}
