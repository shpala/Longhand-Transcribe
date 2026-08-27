import SwiftUI
import LonghandKit

/// The text of one turn, in whichever of its four forms applies: find marks,
/// markers among the words, the word-by-word sweep while it plays, or plain.
/// The rules are the same on every platform, so they live here once rather
/// than in two copies that had already started to drift.
public struct TurnBodyText: View {
    let turn: Transcript.Turn
    /// Set only while this turn is playing: drives the word-level sweep.
    let playbackTime: TimeInterval?
    let words: [MergedWord]?
    let placedMarkers: [MarkerPlacement.Placed]
    /// Ranges of the current find query inside `turn.text`.
    let highlights: [Range<String.Index>]
    let onSeek: () -> Void
    let onSeekToTime: ((TimeInterval) -> Void)?

    @State private var wordFrames = WordFrames()

    public init(turn: Transcript.Turn, playbackTime: TimeInterval?, words: [MergedWord]?,
                placedMarkers: [MarkerPlacement.Placed], highlights: [Range<String.Index>],
                onSeek: @escaping () -> Void, onSeekToTime: ((TimeInterval) -> Void)?) {
        self.turn = turn
        self.playbackTime = playbackTime
        self.words = words
        self.placedMarkers = placedMarkers
        self.highlights = highlights
        self.onSeek = onSeek
        self.onSeekToTime = onSeekToTime
    }

    /// Rendering from the merged words rather than string-matching into
    /// `turn.text` keeps the styling aligned in bidi text.
    private var turnWords: [MergedWord]? {
        // An edited turn's words no longer describe its text, so the sweep
        // falls back to lighting the whole turn.
        guard turn.edited != true, playbackTime != nil || !placedMarkers.isEmpty,
              let words else { return nil }
        let slice = words.filter { $0.start >= turn.start - 0.001 && $0.start < turn.end }
        return slice.isEmpty ? nil : slice
    }

    public var body: some View {
        let direction = BidiText.baseDirection(of: turn.text)
        Group {
            if !highlights.isEmpty {
                // While finding, the search marks win: two overlapping
                // highlight systems on one line is unreadable.
                Text(Self.findHighlighted(turn.text, ranges: highlights))
            } else if let turnWords, !placedMarkers.isEmpty, playbackTime == nil {
                // Marked but not playing, so it skips the tap-to-seek
                // geometry the sweep needs.
                MarkedTurnText(words: turnWords, placements: placedMarkers)
                    .onTapGesture { onSeek() }
            } else if let turnWords, let time = playbackTime, !placedMarkers.isEmpty {
                MarkedTurnText(words: turnWords, placements: placedMarkers,
                               activeWordIndex: turnWords.lastIndex { $0.start <= time })
                    .onTapGesture { onSeek() }
            } else if let turnWords, let time = playbackTime {
                // A TextRenderer reports where each word landed so a tap can
                // play from it. The words stay in one Text: separate views
                // would each lay out alone and break bidi reordering.
                let activeIndex = turnWords.lastIndex { $0.start <= time }
                wordTaggedText(turnWords, activeIndex: activeIndex, time: time)
                    .textRenderer(WordFrameRenderer(store: wordFrames, activeIndex: activeIndex))
                    .background {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { point in
                                if let index = wordFrames.word(at: point), index < turnWords.count {
                                    onSeekToTime?(turnWords[index].start)
                                } else {
                                    onSeek()
                                }
                            }
                    }
            } else {
                Text(turn.text)
            }
        }
        .font(.system(.body, design: .serif))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: direction == .rtl ? .trailing : .leading)
        .multilineTextAlignment(direction == .rtl ? .trailing : .leading)
        .environment(\.layoutDirection, direction == .rtl ? .rightToLeft : .leftToRight)
    }

    /// Attributes are applied to ranges of the original string, so bidi runs
    /// keep their shape.
    static func findHighlighted(_ text: String, ranges: [Range<String.Index>]) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = .yellow.opacity(0.35)
            attributed[lower..<upper].foregroundColor = .primary
        }
        return attributed
    }
}

/// A marker no turn could draw among its words, shown as its own row.
public struct MarkerRow: View {
    let label: String
    let onTap: () -> Void

    public init(label: String, onTap: @escaping () -> Void) {
        self.label = label
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            Label(label, systemImage: "flag.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("marker")
    }
}

/// The only view that reads the playhead at tick rate. It has no content, so
/// a tick costs a no-op body and the list is disturbed only on a turn change.
public struct PlaybackTurnTracker: View {
    let player: TranscriptPlayer
    let index: TranscriptIndex
    @Binding var currentTurn: Int?

    public init(player: TranscriptPlayer, index: TranscriptIndex, currentTurn: Binding<Int?>) {
        self.player = player
        self.index = index
        self._currentTurn = currentTurn
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: player.currentTime) { _, time in
                let next = (player.isLoaded && time > 0)
                    ? index.turnIndex(at: time, from: currentTurn)
                    : nil
                if next != currentTurn { currentTurn = next }
            }
    }
}
