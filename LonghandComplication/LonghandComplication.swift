import SwiftUI
import WidgetKit

/// Watch-face complication: the Longhand mark, and one tap to a running
/// recording. It carries `longhand://record` and `WatchRecordView` starts the
/// take on arrival.
///
/// The art is the app mark as a template image (`BrandGlyph`). Accessory
/// families render inside the face's own tint and vibrancy, so a full-colour
/// tile flattens to a grey square.
///
/// The timeline is static. Live recording state would need a shared app-group
/// container plus `WidgetCenter.reloadTimelines` pushed from the recorder, and
/// a complication that lies about whether you are recording is worse than one
/// that never claims to.
enum ComplicationLink {
    /// A URL rather than an AppIntent because starting the microphone needs the
    /// app foregrounded, which a launch does and a background intent does not.
    static let record = URL(string: "longhand://record")!
}

private struct ComplicationEntry: TimelineEntry {
    let date: Date
}

private struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry { ComplicationEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        // One entry, never expiring: the glyph does not change.
        completion(Timeline(entries: [ComplicationEntry(date: .now)], policy: .never))
    }
}

/// `widgetAccentable` opts the mark into the face's accent colour on tinted
/// faces rather than dimming it as background furniture.
///
/// Two constraints, both of which make the slot render nothing at all when
/// broken. WidgetKit archives complication content and the archiver refuses an
/// asset larger than 122.4 points (`imageTooLarge`), failing the whole render
/// rather than degrading, so `BrandGlyph` is 56/112 px. And the explicit `side`
/// is required because a `resizable()` image with no frame has no size to
/// archive; a circular slot is ~51 pt, so 112 px is ample.
private struct BrandGlyph: View {
    var side: CGFloat

    var body: some View {
        Image("BrandGlyph")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: side, height: side)
            .widgetAccentable()
    }
}

private struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                BrandGlyph(side: 34)
            }
        case .accessoryCorner:
            BrandGlyph(side: 22)
                .widgetLabel { Text("Record") }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                BrandGlyph(side: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Longhand").font(.headline)
                    Text("Tap to record").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            BrandGlyph(side: 26)
        }
    }
}

private struct LonghandComplication: Widget {
    let kind = "com.shpala.Longhand.watch.complication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { _ in
            ComplicationView()
                .widgetURL(ComplicationLink.record)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Longhand")
        .description("Start a recording.")
        // Inline renders text and an SF Symbol only, so the mark cannot appear.
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}

@main
struct LonghandComplicationBundle: WidgetBundle {
    var body: some Widget {
        LonghandComplication()
    }
}

// The only way to inspect a complication from here: watchOS simulators do not
// let a script add one to a face.
#Preview("Circular", as: .accessoryCircular) {
    LonghandComplication()
} timeline: {
    ComplicationEntry(date: .now)
}

#Preview("Corner", as: .accessoryCorner) {
    LonghandComplication()
} timeline: {
    ComplicationEntry(date: .now)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    LonghandComplication()
} timeline: {
    ComplicationEntry(date: .now)
}
