import SwiftUI
import UniformTypeIdentifiers
import LonghandKit
import LonghandEngines

/// Library screen (§15.1): import entry point plus per-job state.
struct LibraryView: View {

    @State private var model = AppLibrary.model
    @State private var showImporter = false
    @State private var showRecorder = false
    @State private var showVoices = false
    @State private var showSettings = false
    @State private var pendingImport: PendingImport?
    @State private var deleteTarget: JobRecord?
    @State private var renameTarget: JobRecord?
    /// Cleared by Import or Cancel, so a leftover value means the sheet was
    /// swiped away.
    @State private var dismissedImport: PendingImport?
    @State private var search = LibrarySearch()
    @State private var query = ""
    /// Held rather than computed: as a computed property this reran the whole
    /// corpus scan for every row SwiftUI laid out, on every keystroke.
    @State private var searchResults: [UUID: LibrarySearch.Result]?
    @State private var deleteHaptic = 0
    /// Opens the voices sheet once Settings has finished dismissing.
    @State private var openVoicesAfterSettings = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    /// Pushed by hand: a `NavigationLink` row makes the whole cell the link's
    /// tap target, so the row's Retry/Resume control never sees its own tap.
    @State private var path: [UUID] = []
    /// The iPad's detail column, driven by the same row taps for the same
    /// reason a selection-driven `List` is not used.
    @State private var selection: UUID?
    /// Siri, Shortcuts, the Action Button and the Control Center control.
    @State private var requests = AppRequests.shared

    /// The idiom, not the size class: it cannot change while the app runs, so
    /// the navigation container is fixed for the process. Branching on
    /// `horizontalSizeClass` would swap the whole tree when a Stage Manager
    /// window is resized, tearing down a running record sheet with it.
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    /// Opens the record sheet once onboarding has finished dismissing.
    @State private var openRecorderAfterOnboarding = false
    @AppStorage("defaultImportLanguage") private var declaredLanguage = "system"
    @AppStorage("defaultSpeakerCount") private var speakerCount = 0

    /// Files waiting for the options sheet: picked (security-scoped) or just
    /// recorded in-app (temp file, deleted once the protected copy is made).
    /// A batch, since the picker takes several at once and they all import
    /// with the options the sheet was raised to ask about.
    struct PendingImport: Identifiable {
        var urls: [URL]
        var securityScoped: Bool
        var deleteAfterImport: Bool
        /// Set for in-app takes, which have no meaningful filename.
        var title: String?
        var markers: [TimeInterval] = []
        /// In-app takes only; picked files fall back to embedded metadata.
        var location: CapturedLocation?
        var id: String { urls.map(\.absoluteString).joined() }
    }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .movie, .mpeg4Movie, .wav, .mp3]
        // HiDock .hda / .hta headerless streams (§5.5) arrive as generic data.
        if let hda = UTType(filenameExtension: "hda") { types.append(hda) }
        if let hta = UTType(filenameExtension: "hta") { types.append(hta) }
        types.append(.data)
        return types
    }()

    private func recomputeSearch() {
        guard let results = search.results(for: query, in: model.jobs) else {
            searchResults = nil
            return
        }
        searchResults = Dictionary(uniqueKeysWithValues: results.map { ($0.jobID, $0) })
    }

    private var visibleJobs: [JobRecord] {
        guard let searchResults else { return model.jobs }
        return model.jobs.filter { searchResults[$0.id] != nil }
    }

    /// Jobs grouped by calendar day, newest first (§15.1 mock: "Today"…).
    private var groupedJobs: [(day: String, jobs: [JobRecord])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: visibleJobs) { calendar.startOfDay(for: $0.createdAt) }
        let sortedDays = byDay.sorted { $0.key > $1.key }
        return sortedDays.map { (day: Self.dayLabel(for: $0.key), jobs: $0.value) }
    }

    private static func dayLabel(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        container.dropDestination(for: URL.self) { urls, _ in
            // A drop uses the saved defaults rather than raising the options
            // sheet. The picker is the deliberate path, and it still asks.
            for url in urls {
                model.importRecording(
                    from: url,
                    securityScoped: true,
                    declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
                    expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount)
            }
            return !urls.isEmpty
        }
    }

    @ViewBuilder
    private var container: some View {
        if Self.isPad {
            NavigationSplitView {
                presented(rootContent)
            } detail: {
                // Its own stack, so the detail column's toolbar and title land
                // in the right place.
                NavigationStack { detailColumn }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $path) {
                presented(rootContent)
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        // A deleted recording leaves its id behind in `selection`, and a
        // transcript view for a job that no longer exists never resolves.
        if let selection, model.jobs.contains(where: { $0.id == selection }) {
            TranscriptView(jobID: selection)
                .environment(model)
                // Without this SwiftUI reuses the view across a selection
                // change, `onAppear` does not fire, and `load()` never runs.
                .id(selection)
        } else {
            ContentUnavailableView {
                VStack(spacing: 16) {
                    BrandMarkTile(size: 96)
                    Text("No recording selected").font(.title2.weight(.semibold))
                }
            } description: {
                Text("Choose a recording, or drop an audio file anywhere in this window. Everything is processed on this device.")
            }
            .background(Color("LonghandBackground").ignoresSafeArea())
        }
    }

    private func open(_ job: JobRecord) {
        if Self.isPad { selection = job.id } else { path.append(job.id) }
    }

    /// A new take asked for from outside the app. A sheet already on screen
    /// would stop the record sheet appearing, so Settings and the like close
    /// first; an import waiting on its options is left alone rather than
    /// imported or thrown away on someone else's behalf.
    private func startRecordingFromRequest() {
        requests.startRecording = false
        guard !showRecorder, pendingImport == nil else { return }
        if showOnboarding {
            openRecorderAfterOnboarding = true
            return
        }
        let covered = showSettings || showVoices || renameTarget != nil || showImporter
        showSettings = false
        showVoices = false
        renameTarget = nil
        showImporter = false
        if covered {
            // The dismissal has to finish before another sheet can present.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                showRecorder = true
            }
        } else {
            showRecorder = true
        }
    }

    private func openFromRequest(_ id: UUID) {
        requests.openRecording = nil
        if Self.isPad { selection = id } else { path = [id] }
    }

    // MARK: - Root content

    private var rootContent: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView {
                    VStack(spacing: 16) {
                        BrandMarkTile(size: 96)
                        Text("No recordings yet").font(.title2.weight(.semibold))
                    }
                } description: {
                    Text("Import a call or meeting recording. Everything is processed on this device.")
                } actions: {
                    Button("Record") { showRecorder = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import File") { showImporter = true }
                }
            } else if visibleJobs.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                jobList
            }
        }
        // Pinned on iPad: left automatic it collapses into a toolbar the
        // sidebar has no room for, and the field never appears.
        .searchable(text: $query,
                    placement: Self.isPad ? .navigationBarDrawer(displayMode: .always) : .automatic,
                    prompt: "Search transcripts")
        .onChange(of: query) { _, _ in recomputeSearch() }
        .onChange(of: model.jobs.count) { _, _ in recomputeSearch() }
        .background(Color("LonghandBackground").ignoresSafeArea())
        .navigationTitle("Longhand")
        .navigationDestination(for: UUID.self) { jobID in
            TranscriptView(jobID: jobID)
                .environment(model)
        }
        .toolbar { toolbarContent }
        .onAppear {
            model.refresh()
            model.resumeUnfinished()
            model.runUITestSynthImportIfRequested()
            AppCommandTargets.shared.startRecording = { showRecorder = true }
            AppCommandTargets.shared.importFiles = { showImporter = true }
            // Suppressed under UI tests, where a modal over the library eats
            // every toolbar tap the suites make.
            if !hasSeenOnboarding, model.jobs.isEmpty, !UITestSupport.isUITestRun {
                // Committed when the sheet is raised, so a kill while the
                // welcome is up does not replay it on the next launch.
                hasSeenOnboarding = true
                showOnboarding = true
            }
        }
        // Handoff from the watch: arriving here is the destination, but the
        // activity still has to be accepted or the icon does nothing.
        .onContinueUserActivity("com.shpala.Longhand.library") { _ in
            model.refresh()
        }
        .onDisappear {
            AppCommandTargets.shared.startRecording = nil
            AppCommandTargets.shared.importFiles = nil
        }
    }

    private var jobList: some View {
        List {
            ForEach(groupedJobs, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.jobs) { job in
                        jobRow(job, hit: searchResults?[job.id])
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sensoryFeedback(.error, trigger: model.jobs.filter { $0.state == .failed }.count) { old, new in
            new > old
        }
        .sensoryFeedback(.warning, trigger: deleteHaptic) { _, new in new > 0 }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showRecorder = true
            } label: {
                Label("Record Audio", systemImage: "mic")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showImporter = true
                } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private func jobRow(_ job: JobRecord, hit: LibrarySearch.Result? = nil) -> some View {
        HStack(spacing: 8) {
            Button {
                open(job)
            } label: {
                HStack(spacing: 8) {
                    JobRow(job: job, progress: model.progressByJob[job.id], hit: hit)
                    Spacer(minLength: 0)
                    // No chevron on iPad: nothing is being pushed.
                    if !Self.isPad {
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onResume = resumeAction(for: job) {
                Button(action: onResume) {
                    Label(job.isPaused ? "Resume" : "Retry",
                          systemImage: job.isPaused ? "play.circle.fill" : "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(job.isPaused ? Color.orange : Color.accentColor)
                .accessibilityLabel(job.isPaused ? "Resume \(job.title)" : "Retry \(job.title)")
                .accessibilityIdentifier(job.isPaused ? "row-resume" : "row-retry")
            }
        }
        .listRowBackground(Self.isPad && selection == job.id
                           ? AnyView(Color.accentColor.opacity(0.14))
                           : AnyView(Color.clear))
        .swipeActions {
            Button(role: .destructive) {
                deleteTarget = job
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if job.state == .failed || job.isPaused || job.state == .interrupted {
                Button {
                    job.isPaused ? model.resume(jobID: job.id) : model.start(jobID: job.id)
                } label: {
                    Label(job.isPaused ? "Resume" : "Retry", systemImage: "arrow.clockwise")
                }
            }
            if model.runningJobs.contains(job.id) {
                Button {
                    model.pause(jobID: job.id)
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                renameTarget = job
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button {
                renameTarget = job
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            if model.runningJobs.contains(job.id) {
                Button {
                    model.pause(jobID: job.id)
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
            if job.isPaused {
                Button {
                    model.resume(jobID: job.id)
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
            }
            if job.state == .complete {
                Button {
                    do {
                        try model.reidentify(jobID: job.id)
                    } catch {
                        model.errorAlert = JobLibraryModel.ErrorAlert(
                            title: "Couldn't Re-identify Speakers",
                            message: JobLibraryModel.describe(error))
                    }
                } label: {
                    Label("Re-identify Speakers", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            if job.state == .complete || job.state == .failed || job.state == .interrupted {
                RetranscribeMenu { language in
                    model.retranscribe(jobID: job.id, language: language)
                }
            }
            Button(role: .destructive) {
                deleteTarget = job
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The same calls the swipe actions make, without the swipe.
    private func resumeAction(for job: JobRecord) -> (() -> Void)? {
        if job.isPaused {
            return { model.resume(jobID: job.id) }
        }
        if job.state == .failed {
            return { model.start(jobID: job.id) }
        }
        return nil
    }

    // MARK: - Sheets, dialogs, alerts

    /// Kept out of `body` so the type checker sees one small expression.
    @ViewBuilder
    private func presented(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showOnboarding) {
                OnboardingView {
                    openRecorderAfterOnboarding = true
                }
            }
            .onChange(of: showOnboarding) { _, nowShowing in
                if !nowShowing, openRecorderAfterOnboarding {
                    openRecorderAfterOnboarding = false
                    showRecorder = true
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(declaredLanguage: $declaredLanguage,
                              speakerCount: $speakerCount) {
                    openVoicesAfterSettings = true
                }
            }
            .onChange(of: showSettings) { _, nowShowing in
                if !nowShowing, openVoicesAfterSettings {
                    openVoicesAfterSettings = false
                    showVoices = true
                }
            }
            .sheet(isPresented: $showVoices) {
                EnrolledVoicesView(onReidentifyAll: { await model.reidentifyAll() })
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.importTypes,
                          allowsMultipleSelection: true) { result in
                let urls = (try? result.get()) ?? []
                if !urls.isEmpty {
                    pendingImport = PendingImport(urls: urls, securityScoped: true,
                                                  deleteAfterImport: false)
                }
            }
            .onOpenURL(perform: receiveShared)
            // `initial`, because a cold launch from Siri sets the request
            // before this view exists.
            .onChange(of: requests.startRecording, initial: true) { _, start in
                if start { startRecordingFromRequest() }
            }
            .onChange(of: requests.openRecording, initial: true) { _, id in
                if let id { openFromRequest(id) }
            }
            .sheet(isPresented: $showRecorder) { recordSheet }
            .sheet(item: $pendingImport, onDismiss: {
                // A swipe-down reaches neither Import nor Cancel, and is not a
                // decision to throw the recording away.
                if let stranded = dismissedImport {
                    dismissedImport = nil
                    for url in stranded.urls {
                        model.importRecording(
                            from: url,
                            securityScoped: stranded.securityScoped,
                            deleteSourceAfterImport: stranded.deleteAfterImport,
                            declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
                            expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount,
                            location: stranded.location,
                            title: stranded.title,
                            markers: stranded.markers)
                    }
                }
            }, content: importOptionsSheet)
            .confirmationDialog(
                "Delete Recording?",
                isPresented: Binding(get: { deleteTarget != nil },
                                     set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete “\(deleteTarget?.title ?? "Recording")”", role: .destructive) {
                    if let target = deleteTarget {
                        deleteHaptic += 1
                        model.delete(jobID: target.id)
                    }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("This also deletes the original audio and the transcript. This can't be undone.")
            }
            .sheet(item: $renameTarget) { target in
                RenameRecordingSheet(name: target.title) { newName in
                    model.rename(jobID: target.id, to: newName)
                    renameTarget = nil
                } onCancel: {
                    renameTarget = nil
                }
            }
            .alert(item: $model.errorAlert) { alert in
                Alert(title: Text(alert.title),
                      message: Text(alert.message),
                      dismissButton: .default(Text("OK")))
            }
            .confirmationDialog(
                "Unrecognized format",
                isPresented: Binding(get: { model.pendingRawPCMJob != nil },
                                     set: { if !$0 { model.pendingRawPCMJob = nil } }),
                titleVisibility: .visible
            ) {
                if let job = model.pendingRawPCMJob {
                    Button("Import as raw PCM (16 kHz mono)") {
                        model.confirmRawPCM(jobID: job.id)
                    }
                    Button("Cancel", role: .cancel) { model.pendingRawPCMJob = nil }
                }
            } message: {
                Text("This file has no recognizable container or MPEG frame sync. If you know it is raw 16 kHz mono 16-bit PCM, you can import it as such (§5.5). Otherwise it will be rejected.")
            }
            .confirmationDialog(
                "Download required",
                isPresented: Binding(get: { model.pendingModelDownload != nil },
                                     set: { if !$0 { model.cancelModelDownload() } }),
                titleVisibility: .visible
            ) {
                if let pending = model.pendingModelDownload {
                    // The value goes with the call: the dialog's own dismissal
                    // clears `pendingModelDownload` and can win the race.
                    Button("Download \(pending.sizeText)") { model.confirmModelDownload(pending) }
                    Button("Not now", role: .cancel) { model.cancelModelDownload(pending) }
                }
            } message: {
                if let pending = model.pendingModelDownload {
                    // Named before anything is fetched (guideline 4.2.3(ii)).
                    Text("\(pending.asset) needs a one-time \(pending.sizeText) download before this recording can be processed. It runs on this device afterwards and is never downloaded again. Wi-Fi recommended.")
                }
            }
    }

    private var recordSheet: some View {
        RecordSheet { url, location, markers in
            showRecorder = false
            // Straight to processing on the saved defaults; language and
            // speakers stay adjustable through Re-transcribe.
            model.importRecording(
                from: url,
                securityScoped: false,
                deleteSourceAfterImport: true,
                declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
                expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount,
                location: location,
                title: RecordingTitle.forTake(),
                markers: markers)
        } onSaveWithOptions: { url, location, markers in
            showRecorder = false
            // Same options sheet an imported file gets (§7.1).
            pendingImport = PendingImport(urls: [url], securityScoped: false, deleteAfterImport: true,
                                          title: RecordingTitle.forTake(), markers: markers,
                                          location: location)
        } onCancel: {
            showRecorder = false
        }
    }

    /// A file another app shared with Longhand, or opened in it.
    ///
    /// Imported with the saved defaults, as a drop is, rather than raising the
    /// options sheet: the file can arrive while the recorder, Settings or an
    /// edit is already on screen, and a second sheet would silently fail to
    /// appear and strand the file.
    private func receiveShared(_ url: URL) {
        guard url.isFileURL else { return }
        // Usually a copy iOS made in our own Inbox, and so ours to delete once
        // imported. It can arrive with a security scope even so, so location
        // decides the deletion, never the scope: a file anywhere else is the
        // other app's.
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { url.stopAccessingSecurityScopedResource() }
        model.importRecording(
            from: url,
            securityScoped: scoped,
            deleteSourceAfterImport: Self.isInInbox(url),
            declaredLanguage: declaredLanguage == "system" ? nil : declaredLanguage,
            expectedSpeakerCount: speakerCount == 0 ? nil : speakerCount)
    }

    static func isInInbox(_ url: URL) -> Bool {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        return url.resolvingSymlinksInPath().path.hasPrefix(inbox.resolvingSymlinksInPath().path + "/")
    }

    private func importOptionsSheet(for pending: PendingImport) -> some View {
        // A take's temp filename is a UUID, so show its title instead.
        ImportOptionsSheet(fileNames: pending.title.map { [$0] }
                               ?? pending.urls.map(\.lastPathComponent),
                           declaredLanguage: $declaredLanguage,
                           speakerCount: $speakerCount) {
            dismissedImport = nil
            for url in pending.urls {
                model.importRecording(
                    from: url,
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
            // A discarded recording temp file should not linger (§14.1).
            dismissedImport = nil
            if pending.deleteAfterImport {
                for url in pending.urls { try? FileManager.default.removeItem(at: url) }
            }
            pendingImport = nil
        }
        .onAppear { dismissedImport = pending }
    }
}

private struct JobRow: View {
    let job: JobRecord
    let progress: PipelineProgress?
    var hit: LibrarySearch.Result?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.callout)
                        .foregroundStyle(.tint)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(job.title).font(.headline).lineLimit(1)
                    Spacer()
                    if let language = job.language {
                        // "auto" is the §4.2 mixed-language sentinel, not a code.
                        Text(language == "auto" ? "Mixed" : language.uppercased())
                            .font(.caption2.weight(.medium).monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let duration = job.duration {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                statusLine
                if let hit, let snippet = hit.snippet {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if hit.hitCount > 1 {
                            Text("\(hit.hitCount) matches")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 2)
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
                .accessibilityIdentifier("status-COMPLETE")
        case .failed:
            VStack(alignment: .leading, spacing: 2) {
                Label("Couldn't transcribe", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                if let error = job.errorDescription {
                    Text(error)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .accessibilityIdentifier("status-FAILED")
        case .interrupted:
            // One state, two situations: the system stopped this job and it
            // will pick itself up, or the user stopped it and nothing should
            // happen until they say so.
            if job.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("status-PAUSED")
            } else {
                Label("Interrupted, will resume", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("status-INTERRUPTED")
            }
        default:
            // A stop is not instant: the pipeline finishes the stage it is in
            // before it can checkpoint, and a row still showing progress would
            // look like the tap did nothing.
            if job.pausedByUser == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Stopping…").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("status-STOPPING")
            } else if let progress {
                HStack(spacing: 6) {
                    // Merging, identifying and exporting have no honest number,
                    // so they get a spinner rather than an invented one (§17).
                    if !progress.isDeterminate || (progress.stage == .downloadingModel && progress.fraction <= 0) {
                        ProgressView().controlSize(.mini)
                    } else {
                        ProgressView(value: min(1, max(0, progress.fraction)))
                            .frame(maxWidth: 120)
                    }
                    Text(progressLabel(progress))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(progressLabel(progress)))
                .accessibilityValue(progress.fraction > 0
                                    ? Text("\(Int(progress.fraction * 100)) percent")
                                    : Text(""))
            } else {
                Label(job.state.rawValue.capitalized, systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func progressLabel(_ progress: PipelineProgress) -> String {
        if progress.stage == .downloadingModel && progress.fraction > 0 {
            return "Downloading speech model (one-time)… \(Int(progress.fraction * 100))%"
        }
        // Core ML compiles the weights for this device the first time, which
        // takes minutes where every later load takes seconds. Said plainly, or
        // the wait reads as a hang.
        if progress.stage == .loadingModel, progress.isFirstModelLoad {
            return "Preparing speech model for this device (one-time, a few minutes)…"
        }
        // Where it has reached in the recording, which is a fact, rather than
        // a percentage over stages with no comparable cost.
        if let processed = progress.processedSeconds, let total = progress.totalSeconds, total > 0 {
            return "Transcribing \(clock(processed)) of \(clock(total))"
        }
        return stageName(progress.stage)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func stageName(_ stage: JobStage) -> String {
        switch stage {
        case .importing: "Importing…"
        case .preparing: "Preparing audio…"
        // §14.2: one-time model acquisition, never audio leaving the device.
        case .downloadingModel: "Downloading speech model (one-time)…"
        case .loadingModel: "Loading speech model…"
        case .transcribing: "Transcribing…"
        case .diarizing: "Detecting speakers…"
        case .merging: "Merging…"
        case .identifying: "Identifying speakers…"
        case .exporting: "Exporting…"
        }
    }
}

/// Shared "Re-transcribe in…" submenu (§13.2 explicit re-run).
struct RetranscribeMenu: View {
    let action: (String?) -> Void

    var body: some View {
        Menu {
            LanguageMenuItems(pick: action)
        } label: {
            Label("Re-transcribe in…", systemImage: "arrow.trianglehead.2.clockwise")
        }
    }
}

/// Language + expected-speakers pickers, shared by the import sheet and
/// Settings. §7.1: a forced count must be user-declared, never guessed.
private struct TranscriptionOptionsPickers: View {
    @Binding var declaredLanguage: String
    @Binding var speakerCount: Int

    var body: some View {
        Section("Language") {
            LanguagePicker(declaredLanguage: $declaredLanguage)
        }
        Section("Speakers") {
            Picker("Expected speakers", selection: $speakerCount) {
                Text("Don't know").tag(0)
                Text("2 (phone call)").tag(2)
                Text("3").tag(3)
                Text("4").tag(4)
            }
        }
    }
}

/// Settings: transcription defaults (previously only reachable mid-import),
/// voice management, and the §13.4 storage figure.
private struct SettingsSheet: View {
    @Binding var declaredLanguage: String
    @Binding var speakerCount: Int
    let onShowVoices: () -> Void

    @State private var diskUsage: Int64 = 0
    @State private var leftoverBytes: Int64 = 0
    @AppStorage(LocationCapture.settingsKey) private var captureLocation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TranscriptionOptionsPickers(declaredLanguage: $declaredLanguage,
                                            speakerCount: $speakerCount)
                Section {
                    Toggle("Save location with recordings", isOn: $captureLocation)
                        .onChange(of: captureLocation) { _, _ in
                            // Immediately: the watch obeys this setting and
                            // would otherwise act on the previous answer until
                            // the next job status went out.
                            WatchLink.shared.pushSettings()
                        }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Off by default. Tags new recordings with where they were made, including takes recorded on your Apple Watch, which follows this setting. Stored only on this device, shown only to you, and never included in exports.")
                }
                ModelSettingsSection()
                Section {
                    Button {
                        dismiss()
                        onShowVoices()
                    } label: {
                        Label("Enrolled Voices", systemImage: "person.wave.2")
                    }
                }
                Section("Storage") {
                    LabeledContent(
                        "Used by recordings",
                        value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                    // Only when there is something to see. An interrupted model
                    // download leaves a partial payload in the vendor's staging
                    // area that no other figure counts, and a healthy install
                    // has none, so a permanent row reading "Zero KB" would be
                    // noise standing in for a fact worth surfacing.
                    if leftoverBytes > 0 {
                        LabeledContent(
                            "Interrupted downloads",
                            value: ByteCountFormatter.string(fromByteCount: leftoverBytes, countStyle: .file))
                        Button("Clean Up") {
                            for root in ModelStaging.vendorRoots { ModelStaging.sweep(in: root) }
                            leftoverBytes = ModelStaging.totalLeftoverBytes()
                        }
                    }
                }
                Section {
                    NavigationLink("Acknowledgments") { AcknowledgmentsView() }
                } footer: {
                    Text("Longhand processes everything on this device. Nothing is uploaded; model downloads are the only network activity.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            diskUsage = AppLibrary.model.totalDiskUsage() + WatchLink.incomingBytes()
            leftoverBytes = ModelStaging.totalLeftoverBytes()
        }
    }
}

private struct ImportOptionsSheet: View {
    let fileNames: [String]
    @Binding var declaredLanguage: String
    @Binding var speakerCount: Int
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fileNames, id: \.self) { name in
                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                TranscriptionOptionsPickers(declaredLanguage: $declaredLanguage,
                                            speakerCount: $speakerCount)
            }
            .navigationTitle(fileNames.count == 1 ? "Import Recording"
                                                  : "Import \(fileNames.count) Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport)
                }
            }
        }
        .presentationDetents([.medium])
    }
}


private struct RenameRecordingSheet: View {
    @State var name: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($focused)
                        .accessibilityIdentifier("rename-field")
                    Text("Only the name shown in your library changes; the recording and transcript are untouched.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rename Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
