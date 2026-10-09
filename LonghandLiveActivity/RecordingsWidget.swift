import SwiftUI
import WidgetKit

/// The library on the Home Screen: a Record button at every size, and the
/// latest recordings at the sizes with room for them. Tapping a recording
/// opens its transcript; tapping Record opens the app already recording.
/// Everything shown comes from the snapshot the app writes; the widget never
/// reads a transcript.
struct RecentRecordingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: SnapshotProvider()) { entry in
            RecentRecordingsView(entry: entry)
                .containerBackground(Brand.indigo, for: .widget)
        }
        .configurationDisplayName("Recordings")
        .description("Start a recording, and open your latest transcripts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let recordings: [WidgetSnapshot.Recording]
}

/// One entry, refreshed when the app says the library changed. Relative
/// dates keep themselves current.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), recordings: [
            .init(id: UUID(), title: "Weekly sync", date: Date().addingTimeInterval(-3600),
                  status: .complete, duration: 1850),
            .init(id: UUID(), title: "Voice note", date: Date().addingTimeInterval(-86_400),
                  status: .complete, duration: 95),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> SnapshotEntry {
        SnapshotEntry(date: Date(), recordings: WidgetSnapshot.read()?.recordings ?? [])
    }
}

struct RecentRecordingsView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            // The Lock Screen: one glyph, one tap.
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title2)
            }
            .widgetURL(WidgetSnapshot.recordURL)
            .widgetAccentable()
            .accessibilityLabel("Record with Longhand")
        case .systemSmall:
            recordTile
                .widgetURL(WidgetSnapshot.recordURL)
        default:
            VStack(alignment: .leading, spacing: 10) {
                header
                if entry.recordings.isEmpty {
                    Spacer()
                    Text("No recordings yet. Tap Record to make one.")
                        .font(.footnote)
                        .foregroundStyle(Brand.cream.opacity(0.7))
                    Spacer()
                } else {
                    ForEach(entry.recordings.prefix(rowLimit)) { recording in
                        Link(destination: WidgetSnapshot.url(opening: recording.id)) {
                            row(recording)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(Brand.cream)
        }
    }

    private var rowLimit: Int { family == .systemLarge ? WidgetSnapshot.limit : 2 }

    private var recordTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.red)
            Spacer(minLength: 0)
            Text("Record")
                .font(.headline)
            Text("Transcribed on this device")
                .font(.caption2)
                .foregroundStyle(Brand.cream.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Brand.cream)
    }

    private var header: some View {
        HStack {
            Text("Longhand")
                .font(.headline)
            Spacer()
            Link(destination: WidgetSnapshot.recordURL) {
                Label("Record", systemImage: "mic.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private func row(_ recording: WidgetSnapshot.Recording) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: recording.status))
                .font(.caption)
                .foregroundStyle(tint(for: recording.status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(recording.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(for: recording))
                    .font(.caption2)
                    .foregroundStyle(Brand.cream.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func subtitle(for recording: WidgetSnapshot.Recording) -> String {
        var parts: [String] = []
        switch recording.status {
        case .working: parts.append("Transcribing")
        case .paused: parts.append("Paused")
        case .failed: parts.append("Failed")
        case .complete:
            if let duration = recording.duration {
                parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
            }
        }
        parts.append(recording.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private func symbol(for status: WidgetSnapshot.Status) -> String {
        switch status {
        case .complete: "waveform"
        case .working: "hourglass"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func tint(for status: WidgetSnapshot.Status) -> Color {
        switch status {
        case .complete: Brand.cream.opacity(0.8)
        case .working: .orange
        case .paused: .orange
        case .failed: .red
        }
    }
}
