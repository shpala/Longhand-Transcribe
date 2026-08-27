import SwiftUI
import LonghandKit

/// Turn text with a flag drawn at each marker's own place in the words, rather
/// than as a row above the paragraph, which puts a flag pressed mid-sentence
/// seconds away from what it was reacting to.
///
/// Built from the merged words rather than by string-matching into `turn.text`,
/// for the same reason the sweep is: the attributes ride on the words, so bidi
/// runs keep their shape. §15.2 ⟨R-16⟩ rations per-word rendering to the
/// playing row, and this is affordable because only marked turns use it.
public struct MarkedTurnText: View {
    public let words: [MergedWord]
    public let placements: [MarkerPlacement.Placed]
    /// Highlighted while playing, so the flag reads as part of the sweep.
    public var activeWordIndex: Int?

    public init(words: [MergedWord],
                placements: [MarkerPlacement.Placed],
                activeWordIndex: Int? = nil) {
        self.words = words
        self.placements = placements
        self.activeWordIndex = activeWordIndex
    }

    /// U+2068 FIRST STRONG ISOLATE / U+2069 POP. The flag is a neutral glyph,
    /// so without isolation the surrounding Hebrew drags it to the wrong end
    /// of the run.
    private static let isolate = "\u{2068}"
    private static let popIsolate = "\u{2069}"

    private var attributed: AttributedString {
        var result = AttributedString()
        for index in 0...words.count {
            for placed in placements where placed.beforeWord == index {
                // Non-breaking space: a label alone on the next line reads as
                // stray orange text rather than as this marker's.
                let text = placed.marker.label.map { "⚑\u{00A0}\($0)" } ?? "⚑"
                var flag = AttributedString("\(Self.isolate)\(text)\(Self.popIsolate)")
                flag.foregroundColor = .orange
                flag.font = .callout.weight(.medium)
                result += flag
                result += AttributedString(" ")
            }
            guard index < words.count else { break }
            var piece = AttributedString(words[index].text)
            if let activeWordIndex, index == activeWordIndex {
                piece.foregroundColor = .accentColor
                piece.font = .body.weight(.semibold)
            }
            result += piece
            if index < words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    public var body: some View {
        Text(attributed)
            .accessibilityLabel(accessibilityDescription)
    }

    /// So VoiceOver hears the flags in reading order rather than as a separate
    /// element after the paragraph.
    private var accessibilityDescription: String {
        var parts: [String] = []
        for index in 0...words.count {
            for placed in placements where placed.beforeWord == index {
                parts.append(placed.marker.label.map { "Marked: \($0)." } ?? "Marked.")
            }
            if index < words.count { parts.append(words[index].text) }
        }
        return parts.joined(separator: " ")
    }
}

/// Marker positions on the playback scrubber, which is also the only way to
/// reach the next flag without scrolling the transcript for it.
public struct MarkerTrack: View {
    public let markers: [Transcript.Marker]
    public let duration: TimeInterval
    public let seek: (TimeInterval) -> Void

    public init(markers: [Transcript.Marker],
                duration: TimeInterval,
                seek: @escaping (TimeInterval) -> Void) {
        self.markers = markers
        self.duration = duration
        self.seek = seek
    }

    public var body: some View {
        GeometryReader { geometry in
            ForEach(markers) { marker in
                let fraction = duration > 0 ? min(1, max(0, marker.time / duration)) : 0
                Capsule()
                    .fill(.orange)
                    .frame(width: 2, height: 8)
                    .position(x: geometry.size.width * fraction,
                              y: geometry.size.height / 2)
                    // A 2 pt tick is not a tap target.
                    .contentShape(Rectangle().size(width: 24, height: 24))
                    .onTapGesture { seek(marker.time) }
                    .accessibilityLabel(marker.label ?? "Marker")
            }
        }
        .frame(height: 8)
        .accessibilityIdentifier("marker-track")
    }
}
