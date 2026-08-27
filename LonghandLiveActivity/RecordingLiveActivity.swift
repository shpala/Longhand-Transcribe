import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LonghandLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
    }
}

/// One tap to a new recording from Control Center, the Lock Screen, or the
/// Action Button (Settings > Action Button > Controls).
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.shpala.Longhand.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Record with Longhand")
        .description("Opens Longhand and starts recording.")
    }
}

/// A take in progress on the Lock Screen and in the Dynamic Island: the clock,
/// and the same pause, mark and stop the record sheet offers.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state, title: context.attributes.title)
                .activityBackgroundTint(Brand.indigo)
                .activitySystemActionForegroundColor(Brand.cream)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusLabel(phase: context.state.phase)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Clock(state: context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Controls(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                Clock(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(context.state.phase.tint)
            }
            .keylineTint(Brand.cream)
        }
    }
}

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    StatusLabel(phase: state.phase, markerCount: state.markerCount)
                }
                Spacer()
                Clock(state: state)
                    .font(.system(size: 34, weight: .light).monospacedDigit())
            }
            Controls(state: state)
        }
        .foregroundStyle(Brand.cream)
        .padding(16)
    }
}

/// Counts on its own while recording, so the app sends nothing per second. A
/// paused or interrupted take shows the time it stopped at.
private struct Clock: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: state.clockStart...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Self.label(state.elapsed))
        }
    }

    static func label(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct StatusLabel: View {
    let phase: RecordingActivityAttributes.ContentState.Phase
    var markerCount: Int = 0

    var body: some View {
        Label(text, systemImage: phase.symbol)
            .font(.subheadline)
            .foregroundStyle(phase.tint)
    }

    private var text: String {
        let flags = markerCount == 0 ? "" : " · \(markerCount) marked"
        switch phase {
        case .recording: return "Recording" + flags
        case .paused: return "Paused" + flags
        case .interrupted: return "Interrupted, not recording"
        }
    }
}

private struct Controls: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if state.phase == .recording {
                control("Pause", "pause.fill", PauseRecordingIntent())
            } else {
                control("Resume", "record.circle", ResumeRecordingIntent())
            }
            control("Mark", "flag.fill", MarkRecordingIntent())
            control("Stop", "stop.fill", StopRecordingIntent(), tint: .red)
        }
    }

    private func control(_ title: String, _ symbol: String, _ intent: some LiveActivityIntent,
                         tint: Color = Brand.cream) -> some View {
        Button(intent: intent) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}

private extension RecordingActivityAttributes.ContentState.Phase {
    var symbol: String {
        switch self {
        case .recording: "record.circle"
        case .paused: "pause.circle"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recording: .red
        case .paused, .interrupted: .orange
        }
    }
}

/// The app's asset catalog is not visible from an extension, so the two brand
/// colors are spelled out here.
private enum Brand {
    static let indigo = Color(red: 0x1B / 255, green: 0x18 / 255, blue: 0x46 / 255)
    static let cream = Color(red: 0xF7 / 255, green: 0xF2 / 255, blue: 0xE3 / 255)
}
