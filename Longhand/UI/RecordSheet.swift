import SwiftUI
import LonghandKit
import LonghandEngines

/// Record-in-app sheet. On save the file goes through the normal import flow,
/// so a recorded take and an imported file follow the identical pipeline.
/// Everything the sheet knew about a take that the audio file does not carry,
/// handed over with the file when the take is saved.
struct TakeDetails {
    var location: CapturedLocation?
    /// Flags and typed notes, on the take's own clock.
    var markers: [Transcript.Marker] = []
    var calendarEvent: CalendarEventContext?

    var title: String { RecordingTitle.forTake(event: calendarEvent) }
}

struct RecordSheet: View {

    let onSave: (URL, TakeDetails) -> Void
    /// Routes the take through the same options sheet an import gets (§7.1).
    let onSaveWithOptions: (URL, TakeDetails) -> Void
    let onCancel: () -> Void

    @State private var recorder = RecorderService()
    @State private var permissionDenied = false
    /// One-shot fix resolved alongside recording; nil on denial or timeout,
    /// and it never blocks the save path.
    @State private var locationCapture = LocationCapture()
    @State private var capturedLocation: CapturedLocation?
    /// The meeting this take is being recorded in, when calendar titles are
    /// on. Read once, like the location, and never blocks the take.
    @State private var calendarEvent: CalendarEventContext?
    /// The recorder's clock excludes paused time, so these line up with the
    /// transcript's clock. A note is a marker with a label.
    @State private var markers: [Transcript.Marker] = []
    @State private var markerHaptic = 0
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool
    @State private var showDiscardConfirm = false
    /// Fixed once, so the elapsed timer's schedule does not move when the sheet
    /// re-renders for an unrelated reason.
    @State private var timerAnchor = Date()
    /// The same take on the Lock Screen and in the Dynamic Island.
    @State private var liveActivity = RecordingActivityController()
    /// 54pt at the default text size, growing with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 54
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A continuously redrawn waveform is motion; with Reduce Motion on, the
    /// level is a bar that moves only as the level does.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    if let event = calendarEvent {
                        // The name the recording will get, visible now rather
                        // than discovered in the library.
                        Label(event.title, systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundStyle(cream.opacity(0.8))
                            .lineLimit(1)
                            .accessibilityLabel("Calendar event: \(event.title)")
                            .accessibilityIdentifier("record-calendar-event")
                    }
                    Group {
                        if reduceMotion {
                            LevelBar(recorder: recorder)
                        } else {
                            WaveformMeter(recorder: recorder)
                        }
                    }
                    .frame(height: 64)
                    .padding(.horizontal, 32)
                    .opacity(recorder.state == .paused ? 0.35 : 1)
                    VStack(spacing: 4) {
                        Label(statusText, systemImage: statusIcon)
                            .font(.subheadline)
                            .foregroundStyle(statusColor)
                            .symbolEffect(.pulse, isActive: recorder.state == .recording && !reduceMotion)
                        // Which microphone: a take through the laptop's mic
                        // when the headset was meant is better found out now.
                        if let input = recorder.inputName,
                           recorder.state == .recording || recorder.state == .paused {
                            Text(input)
                                .font(.caption)
                                .foregroundStyle(cream.opacity(0.6))
                                .accessibilityLabel("Microphone: \(input)")
                        }
                        if recorder.state == .recording || recorder.state == .paused {
                            optionsButton
                        }
                    }
                    if recorder.state == .recording || recorder.state == .paused {
                        noteField
                    }
                    if let error = recorder.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("record-error")
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
        .onChange(of: recorder.isInterrupted) { _, interrupted in
            // A call that cut in with the phone in a pocket leaves a gap the
            // transcript cannot show. A flag at the point marks where it is,
            // and a notification says so to a phone that is not looking.
            if interrupted {
                mark()
                TakeNotifier.takeStopped(.interrupted)
            } else {
                TakeNotifier.clear()
            }
            syncLiveActivity()
        }
        .onChange(of: recorder.isHalted) { _, halted in
            if halted { TakeNotifier.takeStopped(.halted(recorder.lastError)) }
            syncLiveActivity()
        }
        .onChange(of: markers.count) { _, _ in
            recorder.updateSidecar(markers: markers)
            syncLiveActivity()
        }
        .onAppear {
            LiveRecordingControls.handler = { command in await perform(command) }
        }
        .onDisappear {
            LiveRecordingControls.handler = nil
            liveActivity.end()
            TakeNotifier.clear()
        }
        .task {
            if await RecorderService.requestPermission() {
                await recorder.start()
                syncLiveActivity()
                // After the microphone is open: the take must not wait on a
                // second permission sheet.
                await TakeNotifier.requestAuthorizationIfNeeded()
                if CalendarContext.isEnabled {
                    calendarEvent = await CalendarContext.current()
                    recorder.updateSidecar(calendarEvent: calendarEvent)
                }
                if LocationCapture.isEnabled {
                    capturedLocation = await locationCapture.capture()
                    recorder.updateSidecar(location: capturedLocation)
                }
            } else {
                permissionDenied = true
            }
        }
    }

    /// A note typed now lands at this moment in the transcript, among the
    /// words being said, so "decided: ship Tuesday" sits next to the sentence
    /// that decided it. Return adds it; the field stays for the next one.
    private var noteField: some View {
        HStack(spacing: 8) {
            TextField("Add a note at this moment", text: $noteText)
                .textFieldStyle(.plain)
                .foregroundStyle(cream)
                .tint(cream)
                .submitLabel(.done)
                .focused($noteFocused)
                .onSubmit(addNote)
                .accessibilityIdentifier("record-note")
            Button(action: addNote) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .foregroundStyle(cream)
            .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Add note")
            .accessibilityIdentifier("record-note-add")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(cream.opacity(0.12), in: Capsule())
        .padding(.horizontal, 24)
    }

    private func addNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        markers.append(Transcript.Marker(time: recorder.currentTime, label: text))
        noteText = ""
        markerHaptic += 1
    }

    private var details: TakeDetails {
        TakeDetails(location: capturedLocation, markers: markers, calendarEvent: calendarEvent)
    }

    /// Three labelled buttons side by side at the default size; stacked at
    /// the accessibility sizes, where "Stop & Save" alone is wider than the
    /// row.
    @ViewBuilder private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 20) { controlButtons }
                .padding(.bottom, 12)
        } else {
            HStack(spacing: 32) { controlButtons }
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var controlButtons: some View {
        Group {
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
                // A halted take has nowhere to resume to; what it has is
                // saved by the same Stop & Save.
                if !recorder.isHalted {
                    Button {
                        Task { await recorder.resume() }
                    } label: {
                        Label("Resume", systemImage: "record.circle").font(.title2)
                    }
                    .foregroundStyle(cream)
                }
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
        // Something typed and not yet added is still a note.
        addNote()
        if let url = await recorder.stop() {
            onSave(url, details)
        }
    }

    private func mark() {
        markers.append(Transcript.Marker(time: recorder.currentTime))
        markerHaptic += 1
    }

    /// A Lock Screen or Dynamic Island button, doing what the same button in
    /// the sheet does.
    private func perform(_ command: LiveRecordingCommand) async {
        switch command {
        case .pause: recorder.pause()
        case .resume: await recorder.resume()
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
                // Wraps at the accessibility sizes rather than truncating
                // to "Stop & Save wit…".
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(cream.opacity(0.8))
        .accessibilityLabel("Stop and save with options")
        .accessibilityIdentifier("record-save-with-options")
    }

    private func stopAndSaveWithOptions() {
        addNote()
        Task {
            if let url = await recorder.stop() {
                onSaveWithOptions(url, details)
            }
        }
    }

    private var elapsed: String {
        let total = Int(recorder.currentTime)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private var statusText: String {
        // A flag press has to be acknowledged, or you press it twice; so
        // does a note, which the field has already cleared.
        let noteCount = markers.filter { $0.label != nil }.count
        let flagCount = markers.count - noteCount
        var flags = flagCount == 0 ? "" : " · \(flagCount) marked"
        if noteCount > 0 { flags += " · \(noteCount) note\(noteCount == 1 ? "" : "s")" }
        switch recorder.state {
        case .idle: return recorder.lastError == nil ? "Starting…" : "Couldn't start"
        case .recording: return "Recording" + flags
        // Interrupted is not a deliberate pause: the system took the mic, and
        // nothing has been captured since. Halted is the take stopping
        // itself, and the message under it says why.
        case .paused:
            if recorder.isHalted { return "Stopped, take so far is safe" + flags }
            return (recorder.isInterrupted ? "Interrupted, not recording" : "Paused") + flags
        case .finished: return "Saved"
        }
    }

    private var statusIcon: String {
        switch recorder.state {
        case .recording: "record.circle"
        case .paused: recorder.isInterrupted || recorder.isHalted ? "exclamationmark.triangle.fill" : "pause.circle"
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

/// The level as one bar, for Reduce Motion: the same reading as the wave,
/// without the stroke redrawing twelve times a second.
private struct LevelBar: View {
    let recorder: RecorderService

    var body: some View {
        let level = recorder.levelHistory.last ?? 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color("LonghandCream").opacity(0.15))
                Capsule().fill(Color("LonghandCream"))
                    .frame(width: max(8, geometry.size.width * max(0.04, level)))
            }
            .frame(height: 12)
            .frame(maxHeight: .infinity)
        }
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
