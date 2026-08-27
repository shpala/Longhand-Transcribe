import SwiftUI
import AppKit
import AVFoundation
import LonghandKit
import LonghandEngines
import UniformTypeIdentifiers

/// Transcript detail: turns with speaker chips, word-level highlight during
/// playback, and exports behind the §14.1 confirmation through a save panel.
struct MacTranscriptView: View {

    let jobID: UUID

    /// The data and the corrections, shared with iOS.
    @State private var screen: TranscriptScreenModel
    private var player: TranscriptPlayer { MacLibrary.player }
    @State private var currentTurn: Int?
    @AppStorage("playbackRate") private var playbackRate = 1.0
    @State private var query = ""
    @State private var hitIndex = 0
    @State private var editTarget: Transcript.Turn?
    @State private var editText = ""
    @State private var renameTarget: RenameTarget?
    @State private var newSpeakerTarget: Transcript.Turn?
    @State private var newSpeakerName = ""
    @State private var failure: RetryableError?
    /// Not a failure: an action that legitimately had nothing to do.
    @State private var infoMessage: String?
    @State private var pendingExport: ExportTarget?
    @State private var exportDocument: ExportDocument?
    @State private var exportName = ""
    @State private var showExporter = false
    @Environment(JobLibraryModel.self) private var model

    init(jobID: UUID) {
        self.jobID = jobID
        _screen = State(initialValue: TranscriptScreenModel(jobID: jobID))
    }

    private var transcript: Transcript? { screen.transcript }
    private var record: JobRecord? { screen.record }

    struct RenameTarget: Identifiable {
        var id: String { cluster }
        var cluster: String
        var currentName: String
        var canEnroll: Bool
    }

    struct ExportTarget: Identifiable {
        var id: String { label }
        var label: String
        var url: URL
        var contentType: UTType
        /// The clipboard is a boundary too (§14.1).
        var toClipboard: Bool = false
    }

    var body: some View {
        Group {
            if let transcript, transcript.turns.isEmpty {
                ContentUnavailableView {
                    Label("No speech detected", systemImage: "waveform.slash")
                } description: {
                    NoSpeechDiagnostics(degradations: record?.degradations ?? [],
                                        appliedGainDb: screen.appliedGainDb,
                                        inputLevelDbFS: screen.inputLevelDbFS)
                } actions: {
                    if player.isLoaded {
                        Button("Play the Recording") { player.toggle() }
                    }
                    Menu("Re-transcribe") {
                        RetranscribeLanguageItems(pick: retranscribe)
                    }
                    .frame(width: 180)
                }
            } else if let transcript {
                transcriptList(transcript)
            } else if screen.transcriptUnreadable {
                ContentUnavailableView {
                    Label("Transcript Unreadable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The job finished, but its transcript file could not be read.")
                } actions: {
                    Menu("Re-transcribe") {
                        RetranscribeLanguageItems(pick: retranscribe)
                    }
                    .frame(width: 180)
                }
            } else if let record, record.state != .complete {
                ContentUnavailableView {
                    Label(record.state == .failed ? "Transcription Failed" : "Processing…",
                          systemImage: record.state == .failed ? "exclamationmark.triangle" : "hourglass")
                } description: {
                    if record.state == .failed {
                        Text(record.errorDescription ?? "The job failed.")
                    } else if let progress = model.progressByJob[jobID] {
                        VStack(spacing: 8) {
                            if progress.isDeterminate {
                                ProgressView(value: max(0, min(1, progress.fraction)))
                                    .frame(width: 220)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            if let processed = progress.processedSeconds, let total = progress.totalSeconds, total > 0 {
                                Text("Transcribing \(Duration.seconds(processed).formatted(.time(pattern: .minuteSecond))) of \(Duration.seconds(total).formatted(.time(pattern: .minuteSecond)))")
                            } else {
                                Text(JobPipeline.stageDisplayName(progress.stage))
                            }
                        }
                    } else {
                        Text(record.state.rawValue.capitalized)
                    }
                } actions: {
                    // Resume, not Retry: Retry restarts from the top and
                    // throws away the stages already on disk.
                    if record.isPaused {
                        Button("Resume") { model.resume(jobID: jobID) }
                    } else if record.state == .failed {
                        Button("Retry") { model.start(jobID: jobID) }
                    }
                }
            } else {
                ProgressView("Loading transcript…")
            }
        }
        .navigationTitle(record?.title ?? "Transcript")
        .searchable(text: $query, prompt: "Find in transcript")
        .onChange(of: query) { _, _ in
            hitIndex = 0
            focusCurrentHit()
        }
        .background(Color("LonghandBackground"))
        .toolbar {
            if transcript != nil {
                exportMenu
                actionsMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if transcript != nil, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    findBar(hits)
                }
                if transcript != nil, player.isLoaded {
                    MacPlaybackBar(markers: transcript?.markers ?? [],
                                   player: player, rate: $playbackRate)
                }
            }
        }
        .sheet(item: $editTarget) { turn in
            MacEditTurnSheet(speaker: turn.speaker, text: $editText) {
                applyEdit(to: turn, newText: editText)
                editTarget = nil
            } onCancel: {
                editTarget = nil
            }
        }
        .sheet(item: $renameTarget) { target in
            MacRenameSpeakerSheet(cluster: target.cluster, name: target.currentName,
                                  canEnroll: target.canEnroll) { newName, enroll in
                rename(cluster: target.cluster, to: newName)
                if enroll {
                    enrollVoice(cluster: target.cluster, as: newName)
                }
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
            }
        }
        .sheet(item: $newSpeakerTarget) { turn in
            MacNewSpeakerSheet(name: $newSpeakerName) {
                assignToNewSpeaker(turn, named: newSpeakerName)
                newSpeakerTarget = nil
            } onCancel: {
                newSpeakerTarget = nil
            }
        }
        .retryableErrorAlert($failure)
        .alert("Nothing to Re-identify",
               isPresented: Binding(get: { infoMessage != nil },
                                    set: { if !$0 { infoMessage = nil } })) {
            Button("OK") { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
        .confirmationDialog(
            "Export \(pendingExport?.label ?? "")?",
            isPresented: Binding(get: { pendingExport != nil },
                                 set: { if !$0 { pendingExport = nil } })
        ) {
            if let target = pendingExport {
                Button(target.toClipboard ? "Copy \(target.label)" : "Save \(target.label)…") {
                    if target.toClipboard {
                        if let text = try? String(contentsOf: target.url, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        } else {
                            failure = RetryableError(message: "That transcript could not be read from disk.",
                                                     retry: { pendingExport = target })
                        }
                    } else if let document = ExportDocument(url: target.url, type: target.contentType) {
                        exportDocument = document
                        exportName = target.url.lastPathComponent
                        showExporter = true
                    } else {
                        failure = RetryableError(message: "\(target.label) could not be read from disk, so there is nothing to save.",
                                                 retry: { pendingExport = target })
                    }
                    pendingExport = nil
                }
                Button("Cancel", role: .cancel) { pendingExport = nil }
            }
        } message: {
            Text("This file leaves on-device processing.")
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: exportDocument?.type ?? .plainText,
                      defaultFilename: exportName) { result in
            if case let .failure(error) = result {
                failure = RetryableError(message: "Couldn't save the export: \(error.localizedDescription)",
                                         retry: { showExporter = true })
            }
        }
        .onAppear {
            load()
            MacLibrary.commands.findNext = { step(1, in: hits) }
            MacLibrary.commands.findPrevious = { step(-1, in: hits) }
            MacLibrary.commands.editCurrentTurn = editCurrentTurn
            MacLibrary.commands.hasCurrentTurn = false
            MacLibrary.commands.hasFindHits = false
        }
        // The library reuses this view across selections, so a new job needs
        // a model of its own.
        .onChange(of: jobID) { _, newID in
            player.stop()
            screen = TranscriptScreenModel(jobID: newID)
            load()
        }
        // The view can be opened mid-pipeline.
        .onChange(of: model.jobs.first { $0.id == jobID }?.state) { _, _ in
            if transcript == nil { load() }
        }
        .onChange(of: currentTurn) { _, turn in
            MacLibrary.commands.hasCurrentTurn = turn != nil && transcript != nil
        }
        .onDisappear {
            player.stop()
            MacLibrary.commands.findNext = nil
            MacLibrary.commands.findPrevious = nil
            MacLibrary.commands.hasFindHits = false
            MacLibrary.commands.editCurrentTurn = nil
            MacLibrary.commands.hasCurrentTurn = false
        }
    }

    @ViewBuilder
    private func transcriptList(_ transcript: Transcript) -> some View {
        // §15.2 ⟨R-16⟩, as on iOS: the playhead is observed by one empty view,
        // and only the active row reads it at tick rate.
        ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let location = screen.location {
                            // Raw coordinates by design: reverse geocoding is a
                            // network call.
                            Button {
                                let query = "\(location.latitude),\(location.longitude)"
                                if let url = URL(string: "https://maps.apple.com/?ll=\(query)&q=Recording") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label(String(format: "%.4f, %.4f", location.latitude, location.longitude),
                                      systemImage: "mappin.and.ellipse")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Recording location. Opens in Maps.")
                        }
                        if let record, !record.degradations.isEmpty {
                            ForEach(record.degradations, id: \.self) { note in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(note.message, systemImage: "info.circle")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if note.kind == .diarizationUnavailable {
                                        speakerLabelsAction
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        if let record, record.stageSeconds != nil {
                            ProcessingTimings(record: record, asrModel: transcript.models.asr)
                        }
                        SuppressedSpans(spans: screen.suppressedSpans)
                        ForEach(Array(transcript.turns.enumerated()), id: \.element.id) { position, turn in
                            ForEach(screen.rowMarkers(beforeTurnAt: position)) { marker in
                                MarkerRow(label: screen.rowMarkerLabel(marker, at: position)) {
                                    player.seekAndPlay(to: marker.time)
                                }
                            }
                            let isAuto = screen.isAutoLabeled(turn)
                            let isCurrent = position == currentTurn
                            MacTurnView(turn: turn,
                                        autoLabeled: isAuto,
                                        isCurrent: isCurrent,
                                        playbackTime: isCurrent ? player.currentTime : nil,
                                        words: screen.renderedWords(at: position, isCurrent: isCurrent),
                                        placedMarkers: screen.placedMarkers(at: position),
                                        highlights: query.isEmpty ? [] : TextFold.ranges(of: query, in: turn.text),
                                        passageCount: screen.index.passageCount(forCluster: turn.effectiveCluster),
                                        onRename: {
                                            renameTarget = RenameTarget(cluster: turn.effectiveCluster,
                                                                        currentName: turn.speaker,
                                                                        canEnroll: screen.canEnroll(cluster: turn.effectiveCluster))
                                        },
                                        onConfirmMatch: isAuto ? { confirm(cluster: turn.effectiveCluster) } : nil,
                                        onEdit: {
                                            editTarget = turn
                                            editText = turn.text
                                        },
                                        onRevert: turn.edited == true ? { revertEdit(turn) } : nil,
                                        speakerChoices: screen.otherSpeakers(than: turn),
                                        onReassign: { cluster in reassign(turn, to: cluster) },
                                        onNewSpeaker: {
                                            newSpeakerName = ""
                                            newSpeakerTarget = turn
                                        },
                                        originalSpeakerName: transcript.displayName(forCluster: turn.cluster),
                                        onSeek: { player.seekAndPlay(to: turn.start) },
                                        onSeekToTime: { player.seekAndPlay(to: $0) })
                                .id(turn.id)
                        }
                        // Flagged after the last turn began: drawn here, or they
                        // vanish, which on the Mac they did.
                        ForEach(screen.trailingRowMarkers) { marker in
                            MarkerRow(label: screen.rowMarkerLabel(marker, at: nil)) {
                                player.seekAndPlay(to: marker.time)
                            }
                        }
                    }
                    .padding()
                }
                .overlay(alignment: .top) {
                    PlaybackTurnTracker(player: player, index: screen.index, currentTurn: $currentTurn)
                }
                .onChange(of: currentTurn) { _, position in
                    if let position, position < transcript.turns.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(transcript.turns[position].id, anchor: .center)
                        }
                    }
                }
        }
    }

    private var hits: [TranscriptSearch.Hit] {
        screen.hits(for: query)
    }

    private func focusCurrentHit() {
        let hits = self.hits
        guard !hits.isEmpty else { return }
        let hit = hits[min(hitIndex, hits.count - 1)]
        currentTurn = hit.turnIndex
        if player.isLoaded { player.seek(to: hit.start) }
    }

    @ViewBuilder
    private func findBar(_ hits: [TranscriptSearch.Hit]) -> some View {
        HStack(spacing: 10) {
            Text(hits.isEmpty ? "No matches" : "\(min(hitIndex + 1, hits.count)) of \(hits.count)")
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { step(-1, in: hits) } label: { Image(systemName: "chevron.up") }
                .disabled(hits.isEmpty).help("Previous match")
            Button { step(1, in: hits) } label: { Image(systemName: "chevron.down") }
                .disabled(hits.isEmpty).help("Next match")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        // ⌘G is live only while there is something to step to. Tracked here
        // rather than on `body`: the bar exists exactly when a query does, and
        // another onChange on body's chain stalls the type-checker.
        .onChange(of: hits.count, initial: true) { _, count in
            MacLibrary.commands.hasFindHits = count > 0
        }
        .onDisappear { MacLibrary.commands.hasFindHits = false }
    }

    private func step(_ delta: Int, in hits: [TranscriptSearch.Hit]) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + delta + hits.count) % hits.count
        focusCurrentHit()
    }

    /// ⌘E target. The current turn is the one under the playhead or the
    /// current find hit; with neither, the menu item is off.
    private func editCurrentTurn() {
        guard let transcript, let currentTurn, currentTurn < transcript.turns.count else { return }
        let turn = transcript.turns[currentTurn]
        editText = turn.text
        editTarget = turn
    }

    private var exportMenu: some View {
        Menu {
            let files = JobStore.files(for: jobID)
            Button("Copy Transcript") {
                pendingExport = ExportTarget(label: "Transcript", url: files.transcriptText,
                                             contentType: .plainText, toClipboard: true)
            }
            Divider()
            Button("Markdown") { pendingExport = ExportTarget(label: "Markdown", url: files.transcriptMarkdown, contentType: .plainText) }
            Button("Text") { pendingExport = ExportTarget(label: "Text", url: files.transcriptText, contentType: .plainText) }
            Button("JSON (canonical)") { pendingExport = ExportTarget(label: "JSON", url: files.transcriptJSON, contentType: .json) }
            if let original = files.findOriginal() {
                Button("Original audio") { pendingExport = ExportTarget(label: "Original audio", url: original, contentType: .audio) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    /// Re-identification after new enrollment (§10 re-entry edge) and
    /// explicit re-transcription (§13.2).
    private var actionsMenu: some View {
        Menu {
            Button {
                reidentifySpeakers()
            } label: {
                Label("Re-identify Speakers", systemImage: "person.crop.circle.badge.checkmark")
            }
            Menu("Re-transcribe") {
                RetranscribeLanguageItems(pick: retranscribe)
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    private func reidentifySpeakers() {
        do {
            // False means there is no diarization checkpoint to match against,
            // which is not the same as finding no match.
            if try model.reidentify(jobID: jobID) {
                screen.load()
            } else {
                infoMessage = "This recording has no speaker data to match against: the voice detection never ran on it. Re-transcribe it to add speaker labels."
            }
        } catch {
            failure = RetryableError(message: JobLibraryModel.describe(error),
                                     retry: reidentifySpeakers)
        }
    }

    /// A note saying the speaker labels are missing has to sit next to the one
    /// thing that can add them. iOS offered this and the Mac printed the note
    /// as dead text.
    ///
    /// Re-transcribe, not re-identify: identification needs a diarization
    /// checkpoint this job has none of, and the normalized audio a re-merge
    /// would need is deleted at COMPLETE (§13.4). There is no download row to
    /// mirror either, and none is needed: the speaker models ship in the app
    /// and are seeded into the cache on first use, so the re-run is the repair.
    @ViewBuilder private var speakerLabelsAction: some View {
        Button {
            retranscribe(record?.language)
        } label: {
            Label("Re-transcribe to add speaker labels", systemImage: "arrow.clockwise")
                .font(.callout)
        }
        .accessibilityIdentifier("retranscribe-after-model-download")
    }

    private func retranscribe(_ language: String?) {
        player.stop()
        model.retranscribe(jobID: jobID, language: language)
        load()
    }

    /// Runs a correction; a failure offers to run it again. The screen
    /// reloads its data on success and playback carries on.
    private func correct(_ change: @escaping () throws -> Void) {
        do {
            try change()
        } catch {
            failure = RetryableError(message: JobLibraryModel.describe(error),
                                     retry: { correct(change) })
        }
    }

    private func applyEdit(to turn: Transcript.Turn, newText: String) {
        correct { try screen.edit(turn, to: newText) }
    }

    private func revertEdit(_ turn: Transcript.Turn) {
        correct { try screen.revertEdit(turn) }
    }

    private func assignToNewSpeaker(_ turn: Transcript.Turn, named name: String) {
        correct { try screen.assignToNewSpeaker(turn, named: name) }
    }

    private func reassign(_ turn: Transcript.Turn, to cluster: String) {
        correct { try screen.reassign(turn, to: cluster) }
    }

    private func rename(cluster: String, to newName: String) {
        correct { try screen.rename(cluster: cluster, to: newName) }
    }

    private func confirm(cluster: String) {
        correct { try screen.confirm(cluster: cluster) }
    }

    private func enrollVoice(cluster: String, as name: String) {
        screen.enrollVoice(cluster: cluster, as: name)
    }

    /// Opening a recording: the data and the player both.
    private func load() {
        screen.load()
        currentTurn = nil
        // The stored preference is a starting point, not an override: a rate
        // chosen from the Playback menu since the last load survives.
        if player.rate != playbackRate, !player.isLoaded {
            player.rate = playbackRate
        }
        if let original = screen.files.findOriginal() {
            player.load(url: original, title: screen.record?.title)
        }
    }
}

/// Data-backed FileDocument so exports go through NSSavePanel.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json, .audio, .data]
    let data: Data
    let type: UTType

    /// Fails rather than substituting empty data: a zero-byte file presented
    /// as an export is worse than an error.
    init?(url: URL, type: UTType) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Turn row (karaoke rules identical to iOS)

private struct MacTurnView: View {
    let turn: Transcript.Turn
    var autoLabeled: Bool = false
    var isCurrent: Bool = false
    var playbackTime: TimeInterval?
    var words: [MergedWord]?
    var placedMarkers: [MarkerPlacement.Placed] = []
    var highlights: [Range<String.Index>] = []
    /// The reach of a rename, named in the menu.
    var passageCount: Int = 1
    let onRename: () -> Void
    /// Present only on an unconfirmed automatic match (§9.3).
    var onConfirmMatch: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRevert: (() -> Void)?
    var speakerChoices: [(String, String)] = []
    var onReassign: ((String) -> Void)?
    var onNewSpeaker: (() -> Void)?
    /// What the diarizer called this turn, for the undo item's label.
    var originalSpeakerName: String?
    let onSeek: () -> Void
    var onSeekToTime: ((TimeInterval) -> Void)?

    /// Ordered by reach: confirm, then the one-passage fix, then the
    /// everywhere fix. Shared between the chip and the context menu.
    @ViewBuilder private var speakerMenuItems: some View {
        if let onConfirmMatch {
            Button("Yes, this is \(turn.speaker)", action: onConfirmMatch)
        }
        if let onReassign {
            Menu("This passage is…") {
                ForEach(speakerChoices, id: \.0) { cluster, name in
                    Button(name) { onReassign(cluster) }
                }
                if let onNewSpeaker {
                    if !speakerChoices.isEmpty { Divider() }
                    // Nothing in the list to pick when the diarizer folded this
                    // person into someone else's cluster.
                    Button("Someone else…", action: onNewSpeaker)
                }
            }
        }
        Button(passageCount == 1
               ? "Rename \(turn.speaker) in 1 Passage…"
               : "Rename \(turn.speaker) in \(passageCount) Passages…",
               action: onRename)
        if turn.assignedCluster != nil, let onReassign {
            Divider()
            Button(originalSpeakerName.map { "Undo, Back to \($0)" } ?? "Undo Reassignment") {
                onReassign(turn.cluster)
            }
        }
    }

    var body: some View {
        let direction = BidiText.baseDirection(of: turn.text)
        VStack(alignment: direction == .rtl ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    speakerMenuItems
                } label: {
                    HStack(spacing: 4) {
                        Text(turn.speaker)
                            .font(.subheadline.weight(.semibold))
                        if autoLabeled {
                            Text("auto").font(.caption2.smallCaps())
                        }
                        // The chip hides the menu indicator, which would
                        // crowd the capsule, so this says "menu" instead.
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(autoLabeled ? Color("LonghandCream") : Color.accentColor.opacity(0.12),
                                in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(autoLabeled ? Color("LonghandIndigo") : Color.accentColor)
                .help(autoLabeled ? "Matched automatically. Click to confirm, reattribute or rename"
                                  : "Click to reattribute this passage or rename this speaker")
                if turn.overlapped {
                    Text("overlap").font(.caption2.smallCaps())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if turn.assignedCluster != nil {
                    Text("reassigned").font(.caption2.smallCaps())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if turn.edited == true {
                    Text("edited").font(.caption2.smallCaps())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(TranscriptClock.label(turn.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            TurnBodyText(turn: turn, playbackTime: playbackTime, words: words,
                         placedMarkers: placedMarkers, highlights: highlights,
                         onSeek: onSeek, onSeekToTime: onSeekToTime)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(isCurrent ? Color("LonghandHighlight").opacity(0.6) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSeek)
        .contextMenu {
            if let onEdit { Button("Edit Text…", action: onEdit) }
            if let onRevert { Button("Revert to Original", action: onRevert) }
            Divider()
            speakerMenuItems
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.text, forType: .string)
            }
            Button("Copy with Timestamp") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(TranscriptClock.label(turn.start))] \(turn.speaker): \(turn.text)",
                                               forType: .string)
            }
            Button("Play from Here", action: onSeek)
        }
    }
}

// MARK: - Playback

struct MacPlaybackBar: View {
    var markers: [Transcript.Marker] = []
    let player: TranscriptPlayer
    @Binding var rate: Double
    @State private var scrubTime: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            Button { player.skip(by: -TranscriptPlayer.skipInterval) } label: {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(.plain)
            .help("Skip back 15 seconds")
            .accessibilityLabel("Skip back 15 seconds")

            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.skip(by: TranscriptPlayer.skipInterval) } label: {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(.plain)
            .help("Skip forward 15 seconds")
            .accessibilityLabel("Skip forward 15 seconds")

            Text(TranscriptClock.label(scrubTime ?? player.currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { scrubTime ?? player.currentTime },
                                  set: { scrubTime = $0 }),
                   in: 0...max(player.duration, 0.01)) { editing in
                if !editing, let target = scrubTime {
                    player.seek(to: target)
                    scrubTime = nil
                }
            }
            .accessibilityLabel("Playback position")
            .overlay(alignment: .bottom) {
                MarkerTrack(markers: markers, duration: player.duration) { time in
                    player.seekAndPlay(to: time)
                }
                .offset(y: 9)
            }
            Text(TranscriptClock.label(player.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            Picker("Speed", selection: Binding(get: { rate },
                                               set: { rate = $0; player.rate = $0 })) {
                ForEach(TranscriptPlayer.availableRates, id: \.self) { option in
                    Text(TranscriptClock.rateLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 74)
            .help("Playback speed")
            .accessibilityLabel("Playback speed")
        }
        .padding(10)
        .background(.bar)
    }
}

/// Holds the whole turn's text, as on iOS: a transcription mistake is rarely
/// a single token.
private struct MacEditTurnSheet: View {
    let speaker: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(speaker)").font(.title3.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(.body, design: .serif))
                .frame(minWidth: 460, minHeight: 200)
                .border(.quaternary)
                Text("Corrections are kept separately from the transcription, so a re-merge or re-identification won't lose them, and reverting brings the original words back.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
