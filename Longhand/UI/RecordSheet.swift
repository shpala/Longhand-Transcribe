import SwiftUI
import LonghandKit
import LonghandEngines

/// Record-in-app sheet. On save the file goes through the normal import flow,
/// so a recorded take and an imported file follow the identical pipeline.
struct RecordSheet: View {

    let onSave: (URL, CapturedLocation?, [TimeInterval]) -> Void
    /// Routes the take through the same options sheet an import gets (§7.1).
    let onSaveWithOptions: (URL, CapturedLocation?, [TimeInterval]) -> Void
    let onCancel: () -> Void

    @State private var recorder = RecorderService()
    @State private var permissionDenied = false
    /// One-shot fix resolved alongside recording; nil on denial or timeout,
    /// and it never blocks the save path.
    @State private var locationCapture = LocationCapture()
    @State private var capturedLocation: CapturedLocation?
    /// `AVAudioRecorder.currentTime` excludes paused time, so these line up
    /// with the transcript's clock.
    @State private var markers: [TimeInterval] = []
    @State private var markerHaptic = 0
    @State private var showDiscardConfirm = false
    /// Fixed once, so the elapsed timer's schedule does not move when the sheet
    /// re-renders for an unrelated reason.
    @State private var timerAnchor = Date()
    /// The same take on the Lock Screen and in the Dynamic Island.
    @State private var liveActivity = RecordingActivityController()
    /// 54pt at the default text size, growing with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 54

    private let cream = Color("LonghandCream")

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if permissionDenied {
                    ContentUnavailableView {
                        Label("Microphone access needed", systemImage: "mic.slash")
                    } description: {
                        Text("Enable microphone access for Longhand in Settings to record. Audio never leaves this device.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    // `.now` here would be re-evaluated on every body pass, so
                    // each state change would restart the schedule.
                    TimelineView(.periodic(from: timerAnchor, by: 0.5)) { _ in
                        Text(elapsed)
                            .font(.system(size: timerFontSize, weight: .light).monospacedDigit())
                            .foregroundStyle(cream)
                            .accessibilityIdentifier("record-elapsed")
                    }
                    WaveformMeter(recorder: recorder)
                        .frame(height: 64)
                        .padding(.horizontal, 32)
                        .opacity(recorder.state == .paused ? 0.35 : 1)
                    VStack(spacing: 4) {
                        Label(statusText, systemImage: statusIcon)
                            .font(.subheadline)
                            .foregroundStyle(statusColor)
                            .symbolEffect(.pulse, isActive: recorder.state == .recording)
                        if recorder.state == .recording || recorder.state == .paused {
                            optionsButton
                        }
                    }
                    if let error = recorder.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Spacer()
                controls
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("LonghandIndigo").ignoresSafeArea())
            // The indigo surface is dark in both schemes, so system controls
            // (nav title, permission empty state) must render light-on-dark.
            .environment(\.colorScheme, .dark)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(cream)
            .navigationTitle("New Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if (recorder.state == .recording || recorder.state == .paused)
                            && recorder.currentTime > 0 {
                            showDiscardConfirm = true
                        } else {
                            recorder.discard()
                            onCancel()
                        }
                    }
                }
            }
        }
        .confirmationDialog("Discard this recording?",
                            isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                recorder.discard()
                onCancel()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The take so far will be thrown away. This can't be undone.")
        }
        .interactiveDismissDisabled(recorder.state == .recording || recorder.state == .paused)
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.state)
        .sensoryFeedback(.success, trigger: markerHaptic) { _, new in new > 0 }
        .onChange(of: recorder.state) { _, _ in syncLiveActivity() }
        .onChange(of: recorder.isInterrupted) { _, _ in syncLiveActivity() }
        .onChange(of: markers.count) { _, _ in syncLiveActivity() }
        .onAppear {
            LiveRecordingControls.handler = { command in await perform(command) }
        }
        .onDisappear {
            LiveRecordingControls.handler = nil
            liveActivity.end()
        }
        .task {
            if await RecorderService.requestPermission() {
                await recorder.start()
                syncLiveActivity()
                if LocationCapture.isEnabled {
                    capturedLocation = await locationCapture.capture()
                }
            } else {
                permissionDenied = true
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 32) {
            switch recorder.state {
            case .recording:
                Button {
                    recorder.pause()
                } label: {
                    Label("Pause", systemImage: "pause.circle.fill").font(.title2)
                }
                .foregroundStyle(cream)
                markButton
                stopButton
            case .paused:
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "record.circle").font(.title2)
                }
                .foregroundStyle(cream)
                // Safe while paused: `currentTime` freezes at the pause point
                // and paused time never counts, so the flag still lands on the
                // transcript's clock.
                markButton
                stopButton
            case .idle:
                // A start that has not succeeded yet is either still going or
                // over, and never a blank control row.
                if recorder.lastError != nil {
                    retryButton
                } else {
                    ProgressView().tint(cream)
                }
            case .finished:
                // Reachable only if a sheet outlives its take.
                retryButton
            }
        }
        .padding(.bottom, 12)
    }

    private var retryButton: some View {
        Button {
            Task {
                recorder.reset()
                await recorder.start()
            }
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
                .font(.title2)
        }
        .foregroundStyle(cream)
        .accessibilityIdentifier("record-retry")
    }

    private var markButton: some View {
        Button(action: mark) {
            Label("Mark", systemImage: "flag.fill").font(.title2)
        }
        .foregroundStyle(cream)
        .accessibilityIdentifier("record-mark")
        .accessibilityLabel(markers.isEmpty ? "Mark this moment"
                                            : "Mark this moment. \(markers.count) so far")
    }

    private var stopButton: some View {
        // Tap saves with the persisted defaults; long-press offers the options
        // sheet before saving.
        Menu {
            Button(action: stopAndSaveWithOptions) {
                Label("Save with Options…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label("Stop & Save", systemImage: "stop.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
        } primaryAction: {
            Task { await stopAndSave() }
        }
        .tint(.primary)
    }

    private func stopAndSave() async {
        if let url = await recorder.stop() {
            onSave(url, capturedLocation, markers)
        }
    }

    private func mark() {
        markers.append(recorder.currentTime)
        markerHaptic += 1
    }

    /// A Lock Screen or Dynamic Island button, doing what the same button in
    /// the sheet does.
    private func perform(_ command: LiveRecordingCommand) async {
        switch command {
        case .pause: recorder.pause()
        case .resume: recorder.resume()
        case .mark:
            if recorder.state == .recording || recorder.state == .paused { mark() }
        case .stop: await stopAndSave()
        }
    }

    /// Started once the microphone is actually open, kept in step with every
    /// change a person could see, and ended the moment the take is over.
    private func syncLiveActivity() {
        switch recorder.state {
        case .recording, .paused:
            let state = RecordingActivityAttributes.ContentState(recorder: recorder,
                                                                 markerCount: markers.count)
            liveActivity.start(state)
            liveActivity.update(state)
        case .idle, .finished:
            liveActivity.end()
        }
    }

    /// The same options sheet, one visible tap from the status line. Labelled
    /// as ending the take, because a bare slider glyph next to "Recording"
    /// reads as settings for the recording in progress.
    private var optionsButton: some View {
        Button(action: stopAndSaveWithOptions) {
            Label("Stop & Save with Options…", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.medium))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(cream.opacity(0.8))
        .accessibilityLabel("Stop and save with options")
        .accessibilityIdentifier("record-save-with-options")
    }

    private func stopAndSaveWithOptions() {
        Task {
            if let url = await recorder.stop() {
                onSaveWithOptions(url, capturedLocation, markers)
            }
        }
    }

    private var elapsed: String {
        let total = Int(recorder.currentTime)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private var statusText: String {
        // A flag press has to be acknowledged, or you press it twice.
        let flags = markers.isEmpty ? "" : " · \(markers.count) marked"
        switch recorder.state {
        case .idle: return recorder.lastError == nil ? "Starting…" : "Couldn't start"
        case .recording: return "Recording" + flags
        // Interrupted is not a deliberate pause: the system took the mic, and
        // nothing has been captured since.
        case .paused: return (recorder.isInterrupted ? "Interrupted, not recording" : "Paused") + flags
        case .finished: return "Saved"
        }
    }

    private var statusIcon: String {
        switch recorder.state {
        case .recording: "record.circle"
        case .paused: recorder.isInterrupted ? "exclamationmark.triangle.fill" : "pause.circle"
        case .idle: recorder.lastError == nil ? "circle" : "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .recording: .red
        case .paused: .orange
        case .idle where recorder.lastError != nil: .orange
        default: cream.opacity(0.6)
        }
    }
}

/// Input-level history as one continuous stroke rather than discrete bars.
/// A single Canvas keeps the view and accessibility trees stable while the wave
/// animates: subview churn starves accessibility snapshotting, and UI tests,
/// of quiescence.
///
/// A drawing of published state and nothing else. Owning the history in
/// `@State` and refilling it from `onChange(of: context.date)` inside a
/// `TimelineView` mutates state during a view update and ties the meter's
/// cadence to how often the whole sheet re-renders. `RecorderService` owns the
/// sampling.
private struct WaveformMeter: View {
    let recorder: RecorderService

    var body: some View {
        Canvas { graphics, size in
            let history = recorder.levelHistory
            let midY = size.height / 2
            let amplitude = size.height * 0.45
            let count = history.count
            guard count > 1 else { return }
            // Silence keeps a thin visible thread, so a dead mic and a quiet
            // room both look different from speech.
            func point(_ index: Int, _ level: Double, _ sign: CGFloat) -> CGPoint {
                CGPoint(x: CGFloat(index) / CGFloat(count - 1) * size.width,
                        y: midY - sign * CGFloat(max(0.04, level)) * amplitude)
            }
            let top = history.enumerated().map { point($0, $1, 1) }
            let bottom = history.enumerated().reversed().map { point($0, $1, -1) }
            var path = Path()
            path.addSmoothCurve(through: top)
            path.addSmoothCurve(through: bottom, continuing: true)
            path.closeSubpath()
            graphics.fill(path, with: .color(Color("LonghandCream")))
        }
        .shadow(color: Color("LonghandCream").opacity(0.45), radius: 6)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(recorder.levelBand)
    }
}

private extension Path {
    /// Catmull-Rom-ish smoothing via quad curves through segment midpoints.
    /// `continuing` appends without an initial moveTo (for the return edge).
    mutating func addSmoothCurve(through points: [CGPoint], continuing: Bool = false) {
        guard let first = points.first, points.count > 1 else { return }
        if !continuing { move(to: first) } else { addLine(to: first) }
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            addQuadCurve(to: midpoint, control: previous)
        }
        addLine(to: points[points.count - 1])
    }
}
