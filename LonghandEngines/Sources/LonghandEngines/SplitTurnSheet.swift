import SwiftUI
import LonghandKit

/// Cutting a passage in two: the words are shown as one piece of text and a
/// tap on a word makes it the first word of the new passage. One `Text` with
/// a link per word rather than a button per word, so bidi text keeps its
/// order and the line wraps like prose.
public struct SplitTurnSheet: View {
    public let speaker: String
    public let words: [MergedWord]
    public let onSplit: (Int) -> Void
    public let onCancel: () -> Void

    @State private var cutAt: Int?

    public init(speaker: String, words: [MergedWord],
                onSplit: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.speaker = speaker
        self.words = words
        self.onSplit = onSplit
        self.onCancel = onCancel
    }

    private static let scheme = "longhand-split"

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tap the word that starts the new passage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(attributed)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: direction == .rtl ? .trailing : .leading)
                        .multilineTextAlignment(direction == .rtl ? .trailing : .leading)
                        .environment(\.layoutDirection, direction == .rtl ? .rightToLeft : .leftToRight)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == Self.scheme, let index = Int(url.host ?? "") else { return .discarded }
                            cutAt = index
                            return .handled
                        })
                        .accessibilityIdentifier("split-words")
                    if let cutAt {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(speaker) · \(TranscriptClock.label(words[0].start))", systemImage: "1.circle")
                                .font(.caption.weight(.semibold))
                            Text(words[..<cutAt].map(\.text).joined(separator: " "))
                                .font(.callout)
                            Label("\(speaker) · \(TranscriptClock.label(words[cutAt].start))", systemImage: "2.circle")
                                .font(.caption.weight(.semibold))
                                .padding(.top, 6)
                            Text(words[cutAt...].map(\.text).joined(separator: " "))
                                .font(.callout)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("split-preview")
                    }
                }
                .padding()
            }
            .navigationTitle("Split Passage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") { if let cutAt { onSplit(cutAt) } }
                        .disabled(cutAt == nil)
                        .accessibilityIdentifier("split-confirm")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private var direction: BidiText.Direction {
        BidiText.baseDirection(of: words.map(\.text).joined(separator: " "))
    }

    /// Every word a link but the first, which cannot start a second half.
    /// The chosen word and everything after it are tinted, so the cut is
    /// visible before it is made.
    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(word.text)
            if index > 0 {
                piece.link = URL(string: "\(Self.scheme)://\(index)")
                piece.foregroundColor = .primary
                piece.underlineStyle = nil
            }
            if let cutAt, index >= cutAt {
                piece.foregroundColor = .accentColor
                piece.font = .system(.body, design: .serif).weight(.semibold)
            }
            result += piece
            if index < words.count - 1 {
                // The boundary itself is the tap target's gap: a plain space,
                // so a tap between words lands on one of them.
                result += AttributedString(" ")
            }
        }
        return result
    }
}
