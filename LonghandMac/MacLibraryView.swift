import SwiftUI
import UniformTypeIdentifiers
import LonghandKit
import LonghandEngines

/// Mac shell: sidebar of day-grouped recordings, transcript detail, and the
/// Mac-native ingest paths (drag-and-drop anywhere on the window, an Open
/// panel). Same pipeline underneath as every other platform.
struct MacLibraryView: View {

    @State private var model = MacLibrary.model
    @State private var selection: UUID?
    /// Siri and Shortcuts.
    @State private var requests = AppRequests.shared
    @State private var showImporter = false
    @State private var showRecorder = false
    @State private var renameTarget: JobRecord?
    @State private var renameText = ""
    @State private var deleteTarget: JobRecord?
    @State private var pendingImport: PendingImport?
    @State private var search = LibrarySearch()
    @State private var query = ""
    @State private var sidebarError: RetryableError?
    /// Lets the bare-Return Rename shortcut tell "a recording is selected"
    /// from "you are typing somewhere".
    @FocusState private var sidebarFocused: Bool
    /// `sidebarFocused` covers the whole searchable sidebar, so it is true in
    /// the search field too, where Return has to stay a plain Return.
    @FocusState private var searchFieldFocused: Bool
    @State private var showOnboarding = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("defaultImportLanguage") private var declaredLanguage = "system"
    @AppStorage("defaultSpeakerCount") private var speakerCount = 0

    struct PendingImport: Identifiable {
        var urls: [URL]
        /// A recorded take carries what a chosen file does not: a temp
        /// location, no security scope, and a known title, flags and fix.
        var securityScoped = true
        var deleteAfterImport = false
        var title: String?
        var markers: [TimeInterval] = []
        var location: CapturedLocation?
        var id: String { urls.map(\.absoluteString).joined() }
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        if let hda = UTType(filenameExtension: "hda") { types.append(hda) }
        if let hta = UTType(filenameExtension: "hta") { types.append(hta) }
        types.append(.data)
        return types
    }()

    private var searchResults: [UUID: LibrarySearch.Result]? {
        guard let results = search.results(for: query, in: model.jobs) else { return nil }
        return Dictionary(uniqueKeysWithValues: results.map { ($0.jobID, $0) })
    }

    private var groupedJobs: [(day: String, jobs: [JobRecord])] {
        let calendar = Calendar.current
        let visible = searchResults.map { hits in model.jobs.filter { hits[$0.id] != nil } } ?? model.jobs
        let byDay = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.createdAt) }
        return byDay.sorted { $0.key > $1.key }
            .map { (day: Self.dayLabel(for: $0.key), jobs: $0.value) }
    }

    private static func dayLabel(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// The Return-renames gate.
    private var listHasKeyboardFocus: Bool { sidebarFocused && !searchFieldFocused }

    /// ⌘↑/⌘↓ walk the visible (search-filtered) list in display order.
    private func moveSelection(by delta: Int) {
        let jobs = groupedJobs.flatMap(\.jobs)
        guard !jobs.isEmpty else { return }
        guard let selection, let index = jobs.firstIndex(where: { $0.id == selection }) else {
            selection = delta > 0 ? jobs.first?.id : jobs.last?.id
            return
        }
        let target = index + delta
        if jobs.indices.contains(target) { self.selection = jobs[target].id }
    }

    /// A new take asked for by Siri or a shortcut. A sheet already up would
    /// stop the recorder appearing; onboarding steps aside, and an import
    /// waiting on its options is left alone rather than decided for someone.
    private func startRecordingFromRequest() {
        requests.startRecording = false
        guard !showRecorder, pendingImport == nil else { return }
        let covered = showOnboarding || showImporter
        showOnboarding = false
        showImporter = false
        if covered {
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                showRecorder = true
            }
        } else {
            showRecorder = true
        }
    }

    private func reidentify(_ job: JobRecord) {
        do {
            try model.reidentify(jobID: job.id)
        } catch {
            sidebarError = RetryableError(message: JobLibraryModel.describe(error),
                                          retry: { reidentify(job) })
        }
    }

    // Broken out of `body`, whose modifier chain outgrew the type-checker.
    @ViewBuilder private var detailColumn: some View {
        if let selection {
            MacTranscriptView(jobID: selection)
                .environment(model)
        } else {
            ContentUnavailableView {
                VStack(spacing: 16) {
                    BrandMarkTile(size: 96)
                    Text("No recording selected").font(.title2.weight(.semibold))
                }
            } description: {
                Text("Drop an audio file anywhere in this window to transcribe it. Everything runs on this Mac.")
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detailColumn
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                model.importRecording(from: url, securityScoped: true,
                                      declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
                                      expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount)
            }
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showRecorder = true
                } label: {
                    Label("Record", systemImage: "mic")
                }
            }
            ToolbarItem {
                Button {
                    showImporter = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            let urls = (try? result.get()) ?? []
            if !urls.isEmpty { pendingImport = PendingImport(urls: urls) }
        }
        .sheet(isPresented: $showRecorder) {
            MacRecordSheet { url, location, markers in
                showRecorder = false
                model.importRecording(from: url, securityScoped: false,
                                      deleteSourceAfterImport: true,
                                      declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
                                      expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount,
                                      location: location,
                                      title: RecordingTitle.forTake(),
                                      markers: markers)
            } onSaveWithOptions: { url, location, markers in
                showRecorder = false
                pendingImport = PendingImport(urls: [url], securityScoped: false,
                                              deleteAfterImport: true,
                                              title: RecordingTitle.forTake(),
                                              markers: markers, location: location)
            } onCancel: {
                showRecorder = false
            }
        }
        .onChange(of: listHasKeyboardFocus) { _, focused in
            MacLibrary.commands.sidebarFocused = focused
        }
        // `initial`, because Siri can launch the app with the request already made.
        .onChange(of: requests.startRecording, initial: true) { _, start in
            if start { startRecordingFromRequest() }
        }
        .onChange(of: requests.openRecording, initial: true) { _, id in
            guard let id else { return }
            requests.openRecording = nil
            selection = id
        }
        .sheet(isPresented: $showOnboarding) {
            MacOnboardingView { showRecorder = true }
        }
        .onAppear {
            model.refresh()
            model.resumeUnfinished()
            if !hasSeenOnboarding, model.jobs.isEmpty {
                hasSeenOnboarding = true
                showOnboarding = true
            }
            MacLibrary.commands.sidebarFocused = listHasKeyboardFocus
            MacLibrary.commands.startRecording = { showRecorder = true }
            MacLibrary.commands.importFiles = { showImporter = true }
            MacLibrary.commands.renameSelection = {
                guard let job = model.jobs.first(where: { $0.id == selection }) else { return }
                renameTarget = job
                renameText = job.title
            }
            MacLibrary.commands.deleteSelection = {
                deleteTarget = model.jobs.first { $0.id == selection }
            }
            MacLibrary.commands.selectPrevious = { moveSelection(by: -1) }
            MacLibrary.commands.selectNext = { moveSelection(by: 1) }
        }
        .onChange(of: selection) { _, newValue in
            MacLibrary.commands.hasSelection = newValue != nil
        }
        .onDisappear {
            // The menu bar outlives the window; stale targets leave Rename and
            // Delete enabled and pointing at a dead view.
            MacLibrary.commands.hasSelection = false
            MacLibrary.commands.sidebarFocused = false
            MacLibrary.commands.startRecording = nil
            MacLibrary.commands.importFiles = nil
            MacLibrary.commands.renameSelection = nil
            MacLibrary.commands.deleteSelection = nil
            MacLibrary.commands.selectPrevious = nil
            MacLibrary.commands.selectNext = nil
        }
        .modifier(LibraryPresentations(renameTarget: $renameTarget, renameText: $renameText,
                                       deleteTarget: $deleteTarget, selection: $selection,
                                       sidebarError: $sidebarError, pendingImport: $pendingImport,
                                       declaredLanguage: $declaredLanguage, speakerCount: $speakerCount,
                                       model: model))
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groupedJobs, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.jobs) { job in
                        MacJobRow(job: job, progress: model.progressByJob[job.id],
                                  hit: searchResults?[job.id])
                            .tag(job.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renameTarget = job
                                    renameText = job.title
                                }
                                if model.runningJobs.contains(job.id) {
                                    Button("Pause") { model.pause(jobID: job.id) }
                                }
                                if job.isPaused {
                                    Button("Resume") { model.resume(jobID: job.id) }
                                } else if job.state == .failed || job.state == .interrupted {
                                    Button("Retry") { model.start(jobID: job.id) }
                                }
                                if job.state == .complete {
                                    Button("Re-identify Speakers") { reidentify(job) }
                                }
                                if job.state == .complete || job.state == .failed || job.state == .interrupted {
                                    Menu("Re-transcribe") {
                                        RetranscribeLanguageItems { language in
                                            model.retranscribe(jobID: job.id, language: language)
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete…", role: .destructive) { deleteTarget = job }
                            }
                    }
                }
            }
        }
        .focused($sidebarFocused)
        .searchable(text: $query, placement: .sidebar, prompt: "Search transcripts")
        .searchFocused($searchFieldFocused)
    }
}

/// Every alert, dialog and import sheet the library window can raise, kept out
/// of `body` so the type-checker sees one small expression.
private struct LibraryPresentations: ViewModifier {
    @Binding var renameTarget: JobRecord?
    @Binding var renameText: String
    @Binding var deleteTarget: JobRecord?
    @Binding var selection: UUID?
    @Binding var sidebarError: RetryableError?
    @Binding var pendingImport: MacLibraryView.PendingImport?
    @Binding var declaredLanguage: String
    @Binding var speakerCount: Int
    let model: JobLibraryModel

    func body(content: Content) -> some View {
        content
            .alert("Rename Recording",
                   isPresented: Binding(get: { renameTarget != nil },
                                        set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let target = renameTarget { model.rename(jobID: target.id, to: renameText) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Only the name shown in your library changes; the recording and transcript are untouched.")
            }
            .confirmationDialog("Delete “\(deleteTarget?.title ?? "Recording")”?",
                                isPresented: Binding(get: { deleteTarget != nil },
                                                     set: { if !$0 { deleteTarget = nil } })) {
                Button("Delete", role: .destructive) {
                    if let target = deleteTarget {
                        if selection == target.id { selection = nil }
                        model.delete(jobID: target.id)
                    }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("This also deletes the original audio and the transcript. This can't be undone.")
            }
            .alert(item: Binding(get: { model.errorAlert }, set: { model.errorAlert = $0 })) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message),
                      dismissButton: .default(Text("OK")))
            }
            .retryableErrorAlert($sidebarError)
            // §5.5: an unrecognized file may be raw PCM, and only the user can
            // say so.
            .confirmationDialog("Unrecognized format",
                                isPresented: Binding(get: { model.pendingRawPCMJob != nil },
                                                     set: { if !$0 { model.pendingRawPCMJob = nil } }),
                                titleVisibility: .visible) {
                if let job = model.pendingRawPCMJob {
                    Button("Import as raw PCM (16 kHz mono)") { model.confirmRawPCM(jobID: job.id) }
                    Button("Cancel", role: .cancel) { model.pendingRawPCMJob = nil }
                }
            } message: {
                Text("This file has no recognizable container or MPEG frame sync. If you know it is raw 16 kHz mono 16-bit PCM, you can import it as such. Otherwise it will be rejected.")
            }
            .confirmationDialog("Download required",
                                isPresented: Binding(get: { model.pendingModelDownload != nil },
                                                     set: { if !$0 { model.cancelModelDownload() } }),
                                titleVisibility: .visible) {
                if let pending = model.pendingModelDownload {
                    // The value goes with the call: the dialog's own dismissal
                    // clears `pendingModelDownload` and can win the race.
                    Button("Download \(pending.sizeText)") { model.confirmModelDownload(pending) }
                    Button("Not now", role: .cancel) { model.cancelModelDownload(pending) }
                }
            } message: {
                if let pending = model.pendingModelDownload {
                    Text("\(pending.asset) needs a one-time \(pending.sizeText) download before this recording can be processed. It runs on this Mac afterwards and is never downloaded again.")
                }
            }
            // An Open-panel import is deliberate, so it gets the options; a
            // drop is quick and uses the saved defaults, like a recorded take.
            .sheet(item: $pendingImport) { pending in
                MacImportOptionsSheet(fileNames: pending.title.map { [$0] }
                                          ?? pending.urls.map(\.lastPathComponent),
                                      declaredLanguage: $declaredLanguage,
                                      speakerCount: $speakerCount) {
                    for url in pending.urls {
                        model.importRecording(from: url,
                                              securityScoped: pending.securityScoped,
                                              deleteSourceAfterImport: pending.deleteAfterImport,
                                              declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
                                              expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount,
                                              location: pending.location,
                                              title: pending.title,
                                              markers: pending.markers)
                    }
                    pendingImport = nil
                } onCancel: {
                    pendingImport = nil
                }
            }
    }
}

private struct MacJobRow: View {
    let job: JobRecord
    let progress: PipelineProgress?
    var hit: LibrarySearch.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(job.title).font(.headline).lineLimit(1)
                Spacer()
                if let duration = job.duration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            statusLine
            if let hit, let snippet = hit.snippet {
                Text(snippet)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if hit.hitCount > 1 {
                    Text("\(hit.hitCount) matches").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusLine: some View {
        switch job.state {
        case .complete:
            Label("Complete", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed:
            Label(job.errorDescription ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        case .interrupted:
            Label(job.isPaused ? "Paused" : "Interrupted, will resume",
                  systemImage: job.isPaused ? "pause.circle.fill" : "pause.circle")
                .font(.caption).foregroundStyle(.orange)
        default:
            if job.pausedByUser == true {
                Label("Stopping…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let progress {
                VStack(alignment: .leading, spacing: 2) {
                    if progress.isDeterminate {
                        ProgressView(value: max(0, min(1, progress.fraction)))
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let processed = progress.processedSeconds, let total = progress.totalSeconds, total > 0 {
                        Text("Transcribing \(Duration.seconds(processed).formatted(.time(pattern: .minuteSecond))) of \(Duration.seconds(total).formatted(.time(pattern: .minuteSecond)))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(progress.stage == .loadingModel && progress.isFirstModelLoad
                             ? "Preparing speech model for this Mac (one-time, a few minutes)"
                             : JobPipeline.stageDisplayName(progress.stage))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(job.state.rawValue.capitalized, systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The signature indigo record surface, Mac-sized.
struct MacRecordSheet: View {
    let onSave: (URL, CapturedLocation?, [TimeInterval]) -> Void
    /// Routes the take through the same options an import gets (§7.1) rather
    /// than committing it to the saved defaults.
    let onSaveWithOptions: (URL, CapturedLocation?, [TimeInterval]) -> Void
    let onCancel: () -> Void

    @State private var recorder = MacRecorderService()
    @State private var permissionDenied = false
    /// One-shot fix resolved alongside recording; nil on denial or timeout,
    /// and it never blocks the save path.
    @State private var locationCapture = LocationCapture()
    @State private var capturedLocation: CapturedLocation?
    @State private var markers: [TimeInterval] = []
    @State private var showDiscardConfirm = false
    /// Fixed once: `.now` here would be re-evaluated on every body pass, so
    /// each state change would restart the timer's schedule.
    @State private var timerAnchor = Date()
    private let cream = Color("LonghandCream")
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 20) {
            if permissionDenied {
                Text("Enable microphone access for Longhand in System Settings → Privacy & Security.")
                    .foregroundStyle(cream)
                    .multilineTextAlignment(.center)
            } else if let error = recorder.lastError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text(error).multilineTextAlignment(.center)
                    Button {
                        recorder.reset()
                        recorder.start()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .tint(cream)
                    .padding(.top, 4)
                }
                .foregroundStyle(cream)
            } else {
                TimelineView(.periodic(from: timerAnchor, by: 0.5)) { _ in
                    Text(elapsed)
                        .font(.system(size: timerFontSize, weight: .light).monospacedDigit())
                        .foregroundStyle(cream)
                }
                if !markers.isEmpty {
                    Text("\(markers.count) marked")
                        .font(.caption).foregroundStyle(cream.opacity(0.7))
                }
                MacWaveformMeter(recorder: recorder)
                    .frame(height: 52)
                    .padding(.horizontal, 24)
                    .opacity(recorder.state == .paused ? 0.35 : 1)
                HStack(spacing: 24) {
                    Button(recorder.state == .paused ? "Resume" : "Pause") {
                        if recorder.state == .recording { recorder.pause() } else { recorder.resume() }
                    }
                    .tint(cream)
                    // Safe while paused: `currentTime` freezes at the pause
                    // point and paused time never counts.
                    Button("Mark") { markers.append(recorder.currentTime) }
                        .tint(cream)
                        .disabled(recorder.state != .recording && recorder.state != .paused)
                    Button {
                        if let url = recorder.stop() { onSave(url, capturedLocation, markers) }
                    } label: {
                        Label("Stop & Save", systemImage: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                // Labelled as ending the take, because it does.
                Button {
                    if let url = recorder.stop() {
                        onSaveWithOptions(url, capturedLocation, markers)
                    }
                } label: {
                    Label("Stop & Save with Options…", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(cream.opacity(0.8))
            }
            Button("Cancel") {
                if isCapturing && recorder.currentTime > 0 {
                    showDiscardConfirm = true
                } else {
                    recorder.discard()
                    onCancel()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(cream.opacity(0.6))
        }
        .padding(32)
        .frame(width: 420, height: 300)
        .background(Color("LonghandIndigo"))
        .environment(\.colorScheme, .dark)
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
        // Escape would tear the view down without running `discard()` or
        // `onCancel()`, orphaning the take in the container's temp directory.
        .interactiveDismissDisabled(isCapturing)
        // Siri and Shortcuts reach the take through this, as the Lock Screen
        // does on iOS.
        .onAppear {
            LiveRecordingControls.handler = { command in perform(command) }
        }
        .onDisappear { LiveRecordingControls.handler = nil }
        .task {
            if await MacRecorderService.requestPermission() {
                recorder.start()
                if LocationCapture.isEnabled {
                    capturedLocation = await locationCapture.capture()
                }
            } else {
                permissionDenied = true
            }
        }
    }

    private var isCapturing: Bool {
        recorder.state == .recording || recorder.state == .paused
    }

    /// The same as the sheet's own buttons, for Siri and Shortcuts.
    private func perform(_ command: LiveRecordingCommand) {
        switch command {
        case .pause: if recorder.state == .recording { recorder.pause() }
        case .resume: if recorder.state == .paused { recorder.resume() }
        case .mark: if isCapturing { markers.append(recorder.currentTime) }
        case .stop:
            if let url = recorder.stop() { onSave(url, capturedLocation, markers) }
        }
    }

    private var elapsed: String {
        let total = Int(recorder.currentTime)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct MacWaveformMeter: View {
    let recorder: MacRecorderService
    @State private var history: [Double] = Array(repeating: 0, count: 48)
    private let release = 0.78

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            Canvas { graphics, size in
                let midY = size.height / 2
                let amplitude = size.height * 0.45
                let count = history.count
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
            .onChange(of: context.date) {
                let previous = history.last ?? 0
                history.removeFirst()
                history.append(max(recorder.currentLevel(), previous * release))
            }
        }
        .accessibilityLabel("Microphone level")
    }
}

struct BrandMarkTile: View {
    var size: CGFloat = 84

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .shadow(color: Color("LonghandIndigo").opacity(0.35), radius: size * 0.08, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

private extension Path {
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
