import SwiftUI
import LonghandKit

/// Marks a run of text as belonging to one spoken word, so the renderer can
/// report where that word ended up on screen.
public struct WordIndexAttribute: TextAttribute {
    public let index: Int
    public init(index: Int) { self.index = index }
}

/// Collects per-word rectangles during rendering. A lock rather than actor
/// isolation: `TextRenderer.draw` runs on the render pass, off the main actor,
/// while the tap handler reads on it. It also cannot mutate view state, so it
/// deposits geometry here for the gesture to consult afterwards.
public final class WordFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: CGRect] = [:]
    private var pending: [Int: CGRect] = [:]

    public init() {}

    public func record(_ index: Int, _ rect: CGRect) {
        lock.lock()
        pending[index] = rect
        lock.unlock()
    }

    /// Swap in the frames from the pass that just finished.
    public func commit() {
        lock.lock()
        if !pending.isEmpty {
            frames = pending
            pending = [:]
        }
        lock.unlock()
    }

    /// The word under a point, if any.
    public func word(at point: CGPoint) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        // Vertical slop: typographic bounds are tight to the glyphs.
        return frames.first { $0.value.insetBy(dx: 0, dy: -6).contains(point) }?.key
    }
}

/// Draws the turn normally while noting each word's frame. The words stay
/// inside a single `Text`: splitting them into separate views would give each
/// its own layout and break bidi reordering, so a Hebrew line with an English
/// phrase in it would come out in the wrong visual order.
public struct WordFrameRenderer: TextRenderer {
    let store: WordFrames
    /// Drawn with the accent wash behind it. Done in the renderer, so the
    /// highlight is a property of where the word actually landed.
    var activeIndex: Int?
    var accent: Color = .accentColor

    public init(store: WordFrames, activeIndex: Int? = nil, accent: Color = .accentColor) {
        self.store = store
        self.activeIndex = activeIndex
        self.accent = accent
    }

    public func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let index = run[WordIndexAttribute.self]?.index
                if let index {
                    store.record(index, run.typographicBounds.rect)
                }
                if let index, index == activeIndex {
                    let rect = run.typographicBounds.rect.insetBy(dx: -2, dy: -1)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4),
                                 with: .color(accent.opacity(0.18)))
                }
                context.draw(run)
            }
        }
        store.commit()
    }
}

/// Builds `Text` for a turn from its merged words, tagging each with its
/// index and applying the karaoke styling.
public func wordTaggedText(_ words: [MergedWord], activeIndex: Int?, time: TimeInterval) -> Text {
    var result = Text("")
    for (index, word) in words.enumerated() {
        var piece = Text(word.text).customAttribute(WordIndexAttribute(index: index))
        if index == activeIndex, time < word.end + 1.0 {
            piece = piece.foregroundColor(.accentColor).fontWeight(.semibold)
        } else if activeIndex == nil || index > (activeIndex ?? -1) {
            piece = piece.foregroundColor(.primary.opacity(0.35))
        }
        result = result + piece
        if index < words.count - 1 { result = result + Text(" ") }
    }
    return result
}
