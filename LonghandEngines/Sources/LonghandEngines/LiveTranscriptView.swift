import SwiftUI
import LonghandKit

/// The live preview on the record sheets, the same on iOS and the Mac:
/// a caption naming the language and the state, then the words, with the
/// recognizer's current guess dimmer than what it has settled on, and the
/// newest words kept in view.
///
/// Hidden entirely when there is nothing to show yet, so a sheet whose
/// preview is still preparing does not open with an empty box.
public struct LiveTranscriptView: View {
    let live: LiveTranscript
    /// The sheet's text colour; the view draws everything in shades of it.
    let tint: Color

    public init(live: LiveTranscript, tint: Color) {
        self.live = live
        self.tint = tint
    }

    private var caption: String {
        switch live.status {
        case .preparing: "Preparing live preview…"
        case .listening: "Live preview · \(live.languageName)"
        case .suspended: "Live preview paused"
        case .stopped: "Live preview"
        case let .failed(reason): reason
        }
    }

    public var body: some View {
        if live.text.isEmpty, case .listening = live.status {
            // Listening with nothing said yet: the caption alone, so the
            // person knows it is on.
            captionLabel
        } else if !live.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                captionLabel
                // The newest words only, sized by the text: a box that
                // reserved its full height sat mostly empty, and a scroll
                // view on a record sheet is one more thing to manage.
                (Text(recentConfirmed)
                    + Text(live.text.pending.isEmpty ? "" : " ")
                    + Text(live.text.pending).foregroundStyle(tint.opacity(0.5)))
                    .font(.body)
                    .foregroundStyle(tint.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live preview")
            .accessibilityValue(live.text.text)
            .accessibilityIdentifier("record-live-preview")
        } else if case .failed = live.status {
            captionLabel
        } else if case .preparing = live.status {
            // Assets being fetched, or the analyzer starting. Said rather
            // than hidden: a sheet that shows nothing for a minute reads as
            // the feature being off.
            captionLabel
        }
    }

    /// About five lines at the body size on a phone.
    static let shownWords = 40

    /// The tail of the settled text, with an ellipsis standing for what
    /// scrolled away. The pending guess always shows whole.
    private var recentConfirmed: String {
        let pendingWords = live.text.pending.split { $0.isWhitespace }.count
        let budget = max(Self.shownWords - pendingWords, 10)
        let words = live.text.confirmed.split { $0.isWhitespace }
        guard words.count > budget else { return live.text.confirmed }
        return "… " + words.suffix(budget).joined(separator: " ")
    }

    private var captionLabel: some View {
        Label(caption, systemImage: "waveform.and.magnifyingglass")
            .font(.caption)
            .foregroundStyle(tint.opacity(0.6))
            .lineLimit(2)
            .accessibilityIdentifier("record-live-caption")
    }
}
