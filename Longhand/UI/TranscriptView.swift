import SwiftUI
import AVFoundation
import LonghandKit
import LonghandEngines

/// Transcript screen (§15.2): turn list, playback, speaker corrections.
struct TranscriptView: View {

    let jobID: UUID

    /// The data and the corrections, shared with the Mac.
    @State private var screen: TranscriptScreenModel
    @State private var renameTarget: RenameTarget?
    @State private var pendingExport: ExportTarget?
    @State private var confirmedExport: ExportTarget?
    @State private var errorMessage: String?
    /// Not a failure: an action that legitimately had nothing to do.
    @State private var infoMessage: String?
    @State private var confirmHaptic = 0
    @State private var actionHaptic = 0
    /// Shared with Settings, so a download cannot be started twice.
    @State private var player = TranscriptPlayer()
    /// Written by `PlaybackTurnTracker`, so the list body re-evaluates once
    /// per turn rather than ten times a second.
    @State private var currentTurn: Int?
    @State private var query = ""
    @State private var hitIndex = 0
    @State private var isFinding = false
    @State private var editTarget: Transcript.Turn?
    @State private var editText = ""
    @State private var reassignTarget: Transcript.Turn?
    @State private var newSpeakerTarget: Transcript.Turn?
    @State private var newSpeakerName = ""
    @AppStorage("playbackRate") private var playbackRate = 1.0
    @Environment(JobLibraryModel.self) private var jobsModel
    @Environment(\.dismiss) private var dismiss

    init(jobID: UUID) {
        self.jobID = jobID
        _screen = State(initialValue: TranscriptScreenModel(jobID: jobID))
    }

    private var transcript: Transcript? { screen.transcript }
    private var record: JobRecord? { screen.record }

    private struct RenameTarget: Identifiable {
        var id: String { cluster }
        var cluster: String
        var currentName: String
        var canEnroll: Bool
    }

    private struct ExportTarget: Identifiable {
        var id: String { label }
        var label: String
        var url: URL
        /// Copying the whole transcript goes through the §14.1 confirmation
        /// like any other export. Copying a single turn does not.
        var toClipboard: Bool = false
    }

    /// Split out of `body`, whose modifier chain outgrew the type-checker.
    private struct ExportPresentations: ViewModifier {
        @Binding var pendingExport: ExportTarget?
        @Binding var confirmedExport: ExportTarget?
        @Binding var errorMessage: String?
        @Binding var infoMessage: String?
        let hapticTrigger: Int
        let onExportConfirmed: () -> Void

        func body(content: Content) -> some View {
            content
                // §14.1: name what is about to leave the device.
                .confirmationDialog(
                    "Share \(pendingExport?.label ?? "Export")?",
                    isPresented: Binding(get: { pendingExport != nil },
                                         set: { if !$0 { pendingExport = nil } }),
                    titleVisibility: .visible
                ) {
                    if let target = pendingExport {
                        Button(target.toClipboard ? "Copy \(target.label)" : "Share \(target.label)") {
                            if target.toClipboard {
                                if let text = try? String(contentsOf: target.url, encoding: .utf8) {
                                    UIPasteboard.general.string = text
                                }
                            } else {
                                confirmedExport = target
                            }
                            onExportConfirmed()
                            pendingExport = nil
                        }
                        Button("Cancel", role: .cancel) { pendingExport = nil }
                    }
                } message: {
                    Text("This file leaves on-device processing and goes to the destination you choose next.")
                }
                .sheet(item: $confirmedExport) { target in
                    ShareSheet(items: [target.url])
                }
                .alert("Something Went Wrong",
                       isPresented: Binding(get: { errorMessage != nil },
                                            set: { if !$0 { errorMessage = nil } })) {
                    Button("OK") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
                .alert("Nothing to Re-identify",
                       isPresented: Binding(get: { infoMessage != nil },
                                            set: { if !$0 { infoMessage = nil } })) {
                    Button("OK") { infoMessage = nil }
                } message: {
                    Text(infoMessage ?? "")
                }
                .sensoryFeedback(.success, trigger: hapticTrigger) { _, new in new > 0 }
        }
    }

    var body: some View {
        Group {
            if let transcript, transcript.turns.isEmpty {
                noSpeechState
            } else if let transcript {
                transcriptList(transcript)
            } else if let record, record.state != .complete {
                notReadyState(record)
            } else if screen.didLoad {
                unreadableState
            } else {
                ProgressView("Loading transcript…")
            }
        }
        .navigationTitle(record?.title ?? "Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $isFinding,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Find in transcript")
        .onChange(of: query) { _, _ in
            hitIndex = 0
            focusCurrentHit()
        }
        .toolbar {
            if transcript != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isFinding = true
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("find-in-transcript")
                }
                ToolbarItem(placement: .primaryAction) { actionsMenu }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if transcript != nil, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    findBar(hits)
                }
                if transcript != nil, player.isLoaded {
                    PlaybackBar(markers: transcript?.markers ?? [],
                                player: player, rate: $playbackRate)
                }
            }
        }
        .sheet(item: $editTarget) { turn in
            EditTurnSheet(speaker: turn.speaker, text: $editText) {
                applyEdit(to: turn, newText: editText)
                editTarget = nil
            } onCancel: {
                editTarget = nil
            }
        }
        .confirmationDialog("Who is speaking here?",
                            isPresented: Binding(get: { reassignTarget != nil },
                                                 set: { if !$0 { reassignTarget = nil } }),
                            titleVisibility: .visible) {
            if let turn = reassignTarget, let transcript {
                ForEach(transcript.speakers.keys.sorted(), id: \.self) { cluster in
                    if cluster != turn.effectiveCluster {
                        Button(transcript.displayName(forCluster: cluster)) {
                            reassign(turn, to: cluster)
                            reassignTarget = nil
                        }
                    }
                }
                // Nothing in the list to pick when the diarizer folded this
                // person into someone else's cluster.
                Button("Someone else…") {
                    newSpeakerName = ""
                    newSpeakerTarget = turn
                    reassignTarget = nil
                }
                if turn.assignedCluster != nil {
                    Button("Undo, back to \(transcript.displayName(forCluster: turn.cluster))") {
                        reassign(turn, to: turn.cluster)
                        reassignTarget = nil
                    }
                }
                Button("Cancel", role: .cancel) { reassignTarget = nil }
            }
        } message: {
            Text("Changes this passage only. The voice detection's own answer is kept, so enrollment and re-identification are unaffected.")
        }
        .sheet(item: $newSpeakerTarget) { turn in
            NewSpeakerSheet(name: $newSpeakerName) {
                assignToNewSpeaker(turn, named: newSpeakerName)
                newSpeakerTarget = nil
            } onCancel: {
                newSpeakerTarget = nil
            }
        }
        .sheet(item: $renameTarget) { target in
            RenameSpeakerSheet(cluster: target.cluster, name: target.currentName,
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
        .modifier(ExportPresentations(pendingExport: $pendingExport,
                                      confirmedExport: $confirmedExport,
                                      errorMessage: $errorMessage,
                                      infoMessage: $infoMessage,
                                      hapticTrigger: confirmHaptic + actionHaptic,
                                      onExportConfirmed: { actionHaptic += 1 }))
        .onAppear {
            load()
            AppCommandTargets.shared.findInTranscript = { isFinding = true }
            AppCommandTargets.shared.togglePlayback = { player.toggle() }
            AppCommandTargets.shared.skipBack = { player.skip(by: -TranscriptPlayer.skipInterval) }
            AppCommandTargets.shared.skipForward = { player.skip(by: TranscriptPlayer.skipInterval) }
            AppCommandTargets.shared.hasPlayback = player.isLoaded
        }
        // The screen can be opened before the job finishes.
        .onChange(of: jobsModel.jobs.first { $0.id == jobID }?.state) { _, _ in
            load(keepingPlayback: true)
        }
        .onDisappear {
            player.stop()
            // The targets outlive this view; stale ones leave Find and the
            // playback items enabled with nothing on screen.
            AppCommandTargets.shared.findInTranscript = nil
            AppCommandTargets.shared.togglePlayback = nil
            AppCommandTargets.shared.skipBack = nil
            AppCommandTargets.shared.skipForward = nil
            AppCommandTargets.shared.hasPlayback = false
        }
    }

    /// A note saying the speaker labels are missing has to sit next to the one
    /// thing that can add them.
    ///
    /// Re-transcribe, not re-identify: identification needs a diarization
    /// checkpoint this job has none of, and the normalized audio a re-merge
    /// would need is deleted at COMPLETE (§13.4). There was a "Download
    /// Speaker Identification (11 MB)" branch here too, for models that ship
    /// inside the app and are seeded on first use, so it offered a download
    /// that could not happen.
    @ViewBuilder private var speakerModelAction: some View {
        Button {
            player.stop()
            jobsModel.retranscribe(jobID: jobID, language: record?.language)
            dismiss()
        } label: {
            Label("Re-transcribe to add speaker labels", systemImage: "arrow.clockwise")
                .font(.footnote)
        }
        .accessibilityIdentifier("retranscribe-after-model-download")
    }

    /// A finished job with no turns.
    @ViewBuilder
    private var noSpeechState: some View {
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
            RetranscribeMenu { language in
                player.stop()
                jobsModel.retranscribe(jobID: jobID, language: language)
                dismiss()
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private func transcriptList(_ transcript: Transcript) -> some View {
        // §15.2 ⟨R-16⟩: the highlight rides a throttled observer scoped to
        // the one row that needs it, not a TimelineView around the whole list.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let location = screen.location {
                        // Raw coordinates by design: reverse geocoding is a
                        // network call.
                        Button {
                            let query = "\(location.latitude),\(location.longitude)"
                            if let url = URL(string: "maps://?ll=\(query)&q=Recording") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label(String(format: "%.4f, %.4f", location.latitude, location.longitude),
                                  systemImage: "mappin.and.ellipse")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recording location. Opens in Maps.")
                    }
                    if let record, !record.degradations.isEmpty {
                        ForEach(record.degradations, id: \.self) { note in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(note.message, systemImage: "info.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // Not gated on the models being missing: the
                                // row has to keep offering the next step once
                                // the download succeeds.
                                if note.kind == .diarizationUnavailable {
                                    speakerModelAction
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
                        TurnView(turn: turn,
                                 autoLabeled: isAuto,
                                 isCurrent: isCurrent,
                                 // Only the active row reads `currentTime`,
                                 // keeping the rest out of the 10 Hz invalidation.
                                 playbackTime: isCurrent ? player.currentTime : nil,
                                 words: screen.renderedWords(at: position, isCurrent: isCurrent),
                                 placedMarkers: screen.placedMarkers(at: position),
                                 highlights: query.isEmpty ? [] : TextFold.ranges(of: query, in: turn.text),
                                 passageCount: screen.index.passageCount(forCluster: turn.effectiveCluster),
                                 // effectiveCluster, not cluster: on a reassigned
                                 // turn, acting on the diarizer's original cluster
                                 // would rename a different person entirely.
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
                                 onReassign: { reassignTarget = turn },
                                 onUndoReassign: turn.assignedCluster != nil
                                     ? { reassign(turn, to: turn.cluster) } : nil,
                                 originalSpeakerName: transcript.displayName(forCluster: turn.cluster),
                                 onSeek: {
                                     player.seekAndPlay(to: turn.start)
                                 },
                                 onSeekToTime: { time in
                                     player.seekAndPlay(to: time)
                                 })
                        .id(turn.id)
                    }
                    // Flagged after the last turn began: drawn here, or they vanish.
                    ForEach(screen.trailingRowMarkers) { marker in
                        MarkerRow(label: screen.rowMarkerLabel(marker, at: nil)) {
                            player.seekAndPlay(to: marker.time)
                        }
                    }
                }
                .padding()
                // Reading measure: on iPad the turns would otherwise run the
                // full column width. The phone is narrower and unaffected.
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color("LonghandBackground"))
            .overlay(alignment: .top) {
                PlaybackTurnTracker(player: player, index: screen.index, currentTurn: $currentTurn)
            }
            // On turn changes only, so it never fights a manual scroll
            // mid-turn. Follows scrubbing too.
            .onChange(of: currentTurn) { _, position in
                if let position, position < transcript.turns.count {
                    let turn = transcript.turns[position]
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(turn.id, anchor: .center)
                    }
                    // Only while playback is running: `currentTurn` is also
                    // written by find-next and word taps, and an announcement
                    // interrupts whatever VoiceOver is currently saying.
                    if UIAccessibility.isVoiceOverRunning, player.isPlaying {
                        UIAccessibility.post(notification: .announcement,
                                             argument: "\(turn.speaker). \(announcementText(turn.text))")
                    }
                }
            }
        }
    }

    private var hits: [TranscriptSearch.Hit] {
        screen.hits(for: query)
    }

    /// Clipped: a VoiceOver announcement cannot be interrupted, and a turn
    /// can run for paragraphs.
    private func announcementText(_ text: String) -> String {
        let limit = 140
        guard text.count > limit else { return text }
        let clipped = text.prefix(limit)
        let end = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? clipped
        return end + "…"
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
        HStack(spacing: 12) {
            Text(hits.isEmpty ? "No matches" : "\(min(hitIndex + 1, hits.count)) of \(hits.count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("find-count")
            Spacer(minLength: 0)
            Button {
                hitIndex = (hitIndex - 1 + hits.count) % max(1, hits.count)
                focusCurrentHit()
            } label: {
                Image(systemName: "chevron.up").frame(width: 44, height: 36)
            }
            .disabled(hits.isEmpty)
            .accessibilityLabel("Previous match")
            Button {
                hitIndex = (hitIndex + 1) % max(1, hits.count)
                focusCurrentHit()
            } label: {
                Image(systemName: "chevron.down").frame(width: 44, height: 36)
            }
            .disabled(hits.isEmpty)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("find-next")
            Button {
                query = ""
                isFinding = false
            } label: {
                Image(systemName: "xmark").frame(width: 44, height: 36)
            }
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("find-close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Exports only; sharing is an explicit, confirmed action (§14.1).
    private var exportMenu: some View {
        Menu {
            let files = JobStore.files(for: jobID)
            Button("Copy Transcript") {
                pendingExport = ExportTarget(label: "Transcript", url: files.transcriptText, toClipboard: true)
            }
            Divider()
            Button("Markdown") { pendingExport = ExportTarget(label: "Markdown", url: files.transcriptMarkdown) }
            Button("Text") { pendingExport = ExportTarget(label: "Text", url: files.transcriptText) }
            Button("JSON (canonical)") { pendingExport = ExportTarget(label: "JSON (canonical)", url: files.transcriptJSON) }
            if let original = files.findOriginal() {
                Button("Original audio") { pendingExport = ExportTarget(label: "Original audio", url: original) }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    /// Actions on the transcript itself: re-identification after new
    /// enrollment (§10 re-entry edge), explicit re-transcription (§13.2),
    /// and export.
    private var actionsMenu: some View {
        Menu {
            Button {
                do {
                    // False means there is no diarization checkpoint to match
                    // against, which is not the same as finding no match.
                    if try jobsModel.reidentify(jobID: jobID) {
                        load(keepingPlayback: true)
                    } else {
                        infoMessage = "This recording has no speaker data to match against: the voice detection never ran on it. Re-transcribe it to add speaker labels."
                    }
                } catch {
                    errorMessage = JobLibraryModel.describe(error)
                }
            } label: {
                Label("Re-identify Speakers", systemImage: "person.crop.circle.badge.checkmark")
            }
            RetranscribeMenu { language in
                player.stop()
                jobsModel.retranscribe(jobID: jobID, language: language)
                dismiss()
            }
            Divider()
            exportMenu
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Data

    /// `keepingPlayback` separates "open this recording" from "the text under
    /// you changed": the latter must not rebuild the player and rewind to 0:00.
    private func load(keepingPlayback: Bool = false) {
        let resumeAt = keepingPlayback ? player.currentTime : nil
        let wasPlaying = keepingPlayback && player.isPlaying
        screen.load()
        // A continuously animating view never reaches XCUITest quiescence.
        player.tickInterval = UITestSupport.isUITestRun ? 0.25 : 0.1
        #if DEBUG
        // A device test plays someone's real recording; nobody needs to hear it.
        if ProcessInfo.processInfo.arguments.contains("--uitest-mute-playback") { player.volume = 0 }
        #endif
        player.rate = playbackRate
        if keepingPlayback, player.isLoaded {
            // Same audio, new text: leave the player alone.
            return
        }
        currentTurn = nil
        if let original = screen.files.findOriginal() {
            player.load(url: original, title: screen.record?.title)
            if let resumeAt, resumeAt > 0 {
                wasPlaying ? player.seekAndPlay(to: resumeAt) : player.seek(to: resumeAt)
            }
        }
        AppCommandTargets.shared.hasPlayback = player.isLoaded
    }

    /// Runs a correction and reports a failure; the screen reloads its data
    /// on success and the player carries on.
    private func correct(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            errorMessage = JobLibraryModel.describe(error)
        }
    }

    private func applyEdit(to turn: Transcript.Turn, newText: String) {
        correct {
            try screen.edit(turn, to: newText)
            actionHaptic += 1
        }
    }

    private func revertEdit(_ turn: Transcript.Turn) {
        correct { try screen.revertEdit(turn) }
    }

    private func reassign(_ turn: Transcript.Turn, to cluster: String) {
        correct { try screen.reassign(turn, to: cluster) }
    }

    private func assignToNewSpeaker(_ turn: Transcript.Turn, named name: String) {
        correct { try screen.assignToNewSpeaker(turn, named: name) }
    }

    private func rename(cluster: String, to newName: String) {
        correct { try screen.rename(cluster: cluster, to: newName) }
    }

    private func confirm(cluster: String) {
        correct {
            try screen.confirm(cluster: cluster)
            confirmHaptic += 1
        }
    }

    private func enrollVoice(cluster: String, as name: String) {
        screen.enrollVoice(cluster: cluster, as: name)
    }

    @ViewBuilder
    private func notReadyState(_ record: JobRecord) -> some View {
        ContentUnavailableView {
            Label("Transcript not ready", systemImage: "hourglass")
        } description: {
            Text(statusText(record))
        } actions: {
            if record.isPaused {
                Button("Resume") { jobsModel.resume(jobID: jobID) }
            } else if record.state == .failed {
                Button("Retry") { jobsModel.start(jobID: jobID) }
            }
        }
    }

    /// COMPLETE on paper, unreadable on disk. The original audio is untouched,
    /// so a re-transcribe rebuilds it.
    @ViewBuilder private var unreadableState: some View {
        ContentUnavailableView {
            Label("Transcript unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The transcript file couldn't be read. The original recording is untouched; transcribing again rebuilds it.")
        } actions: {
            RetranscribeMenu { language in
                player.stop()
                jobsModel.retranscribe(jobID: jobID, language: language)
                dismiss()
            }
        }
    }

    private func statusText(_ record: JobRecord) -> String {
        if let error = record.errorDescription { return error }
        switch record.state {
        case .interrupted:
            return record.isPaused
                ? "Processing is paused."
                : "Processing was interrupted. It will resume on its own."
        case .failed:
            return "Something went wrong."
        default:
            return "Still processing. This usually takes a minute or two."
        }
    }
}

// MARK: - Turn row

private struct TurnView: View {
    let turn: Transcript.Turn
    var autoLabeled: Bool = false
    var isCurrent: Bool = false
    /// Set only while this turn is playing: drives the word-level sweep.
    var playbackTime: TimeInterval?
    var words: [MergedWord]?
    var placedMarkers: [MarkerPlacement.Placed] = []
    /// Ranges of the current find query inside `turn.text`.
    var highlights: [Range<String.Index>] = []
    /// The reach of a rename, named in the menu.
    var passageCount: Int = 1
    let onRename: () -> Void
    /// Present only on an unconfirmed automatic match (§9.3).
    var onConfirmMatch: (() -> Void)?
    var onEdit: (() -> Void)?
    var onRevert: (() -> Void)?
    var onReassign: (() -> Void)?
    var onUndoReassign: (() -> Void)?
    /// What the diarizer called this turn, for the undo item's label.
    var originalSpeakerName: String?
    let onSeek: () -> Void
    var onSeekToTime: ((TimeInterval) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Ordered by reach: confirm, then the one-passage fix, then the
    /// everywhere fix. Shared between the chip and the turn's context menu.
    @ViewBuilder private var speakerMenuItems: some View {
        if let onConfirmMatch {
            Button(action: onConfirmMatch) {
                Label("Yes, this is \(turn.speaker)", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("confirm-speaker-match")
        }
        if let onReassign {
            Button(action: onReassign) {
                Label("This passage is someone else…", systemImage: "person.crop.circle.badge.questionmark")
            }
            .accessibilityIdentifier("reassign-passage")
        }
        Button(action: onRename) {
            Label(passageCount == 1
                  ? "Rename \(turn.speaker) in 1 passage"
                  : "Rename \(turn.speaker) in \(passageCount) passages",
                  systemImage: "pencil")
        }
        .accessibilityIdentifier("rename-speaker")
        if let onUndoReassign {
            Divider()
            Button(action: onUndoReassign) {
                Label(originalSpeakerName.map { "Undo, back to \($0)" } ?? "Undo reassignment",
                      systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("undo-reassign")
        }
    }

    private var speakerChip: some View {
        Menu {
            speakerMenuItems
        } label: {
            HStack(spacing: 4) {
                Text(turn.speaker)
                    .font(.subheadline.weight(.semibold))
                if autoLabeled {
                    Text("auto")
                        .font(.caption2.smallCaps())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(autoLabeled ? Color("LonghandCream") : Color.accentColor.opacity(0.12),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(autoLabeled ? Color("LonghandIndigo") : Color.accentColor)
        // No custom accessibility label: the speaker's name is what VoiceOver
        // should read, and what the UI tests query.
        .accessibilityHint("Double-tap for speaker options")
    }

    @ViewBuilder private var statusCapsules: some View {
        if turn.overlapped {
            Text("overlap")
                .font(.caption2.smallCaps())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.orange.opacity(0.2), in: Capsule())
        }
        if turn.assignedCluster != nil {
            Label("reassigned", systemImage: "person.2")
                .font(.caption2.smallCaps())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        if turn.edited == true {
            Label("edited", systemImage: "pencil")
                .font(.caption2.smallCaps())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    private var hasStatusCapsules: Bool {
        turn.overlapped || turn.assignedCluster != nil || turn.edited == true
    }

    private var timestampText: some View {
        Text(TranscriptClock.label(turn.start))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            // One per row, so counting these counts the rows the list actually
            // built: §15.2's virtualization is only observable from outside as
            // the absence of the rows nobody is looking at.
            .accessibilityIdentifier("turn-\(turn.id)")
    }

    var body: some View {
        let direction = BidiText.baseDirection(of: turn.text)
        VStack(alignment: direction == .rtl ? .trailing : .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: direction == .rtl ? .trailing : .leading, spacing: 6) {
                    HStack(spacing: 8) { speakerChip; Spacer(minLength: 0); timestampText }
                    if hasStatusCapsules {
                        HStack(spacing: 8) { statusCapsules }
                    }
                }
            } else {
                HStack(spacing: 8) { speakerChip; statusCapsules; Spacer(minLength: 0); timestampText }
            }
            TurnBodyText(turn: turn, playbackTime: playbackTime, words: words,
                         placedMarkers: placedMarkers, highlights: highlights,
                         onSeek: onSeek, onSeekToTime: onSeekToTime)
        }
        .padding(8)
        // LonghandHighlight, not LonghandCream: white body text washes out
        // against lit cream.
        .background(isCurrent ? Color("LonghandHighlight").opacity(0.6) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSeek)
        .accessibilityAction(named: "Play from here") { onSeek() }
        .contextMenu {
            if let onEdit {
                Button(action: onEdit) { Label("Edit Text…", systemImage: "pencil") }
            }
            if let onRevert {
                Button(action: onRevert) { Label("Revert to Original", systemImage: "arrow.uturn.backward") }
            }
            if onReassign != nil || onUndoReassign != nil {
                Divider()
                speakerMenuItems
            }
            Divider()
            Button {
                UIPasteboard.general.string = turn.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = "[\(TranscriptClock.label(turn.start))] \(turn.speaker): \(turn.text)"
            } label: {
                Label("Copy with Timestamp", systemImage: "clock")
            }
            Button(action: onSeek) { Label("Play from Here", systemImage: "play.circle") }
        }
    }
}

// MARK: - Playback

private struct PlaybackBar: View {
    var markers: [Transcript.Marker] = []
    let player: TranscriptPlayer
    @Binding var rate: Double
    @State private var scrubTime: TimeInterval?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    player.skip(by: -TranscriptPlayer.skipInterval)
                } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip back 15 seconds")
                .accessibilityIdentifier("playback-back")

                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("playback-toggle")
                .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)

                Button {
                    player.skip(by: TranscriptPlayer.skipInterval)
                } label: {
                    Image(systemName: "goforward.15").font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward 15 seconds")
                .accessibilityIdentifier("playback-forward")

                Spacer(minLength: 0)

                Menu {
                    ForEach(TranscriptPlayer.availableRates, id: \.self) { option in
                        Button {
                            rate = option
                            player.rate = option
                        } label: {
                            Label(TranscriptClock.rateLabel(option),
                                  systemImage: option == rate ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text(TranscriptClock.rateLabel(rate))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                .accessibilityLabel("Playback speed")
                .accessibilityIdentifier("playback-rate")
            }
            HStack(spacing: 8) {
                Text(TranscriptClock.label(scrubTime ?? player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { scrubTime ?? player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(1, player.duration)
                ) { editing in
                    if !editing, let target = scrubTime {
                        player.seek(to: target)
                        scrubTime = nil
                    }
                }
                .accessibilityIdentifier("playback-scrubber")
                    .overlay(alignment: .bottom) {
                        MarkerTrack(markers: markers, duration: player.duration) { time in
                            player.seekAndPlay(to: time)
                        }
                        .allowsHitTesting(true)
                        .offset(y: 10)
                    }
                Text(TranscriptClock.label(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Share sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Rename sheet

/// Naming a speaker the diarizer never separated out. Smaller than the rename
/// sheet: there is no voice behind this person, so nothing to enrol.
private struct NewSpeakerSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Speaker name", text: $name)
                        .accessibilityIdentifier("new-speaker-name")
                    Text("Applies to this passage only. The voice detection's own answer is kept, so enrollment and re-identification are unaffected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Once named, this person appears in the list, so the next passage you correct can be attributed to them in one tap.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct RenameSpeakerSheet: View {
    let cluster: String
    @State var name: String
    let canEnroll: Bool
    let onSave: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var rememberVoice = false
    @State private var profiles: [SpeakerProfile] = SpeakerProfileStore.load()

    var body: some View {
        NavigationStack {
            Form {
                if !profiles.isEmpty {
                    // §15.3: pick an enrolled person instead of retyping.
                    Section("This is…") {
                        ForEach(profiles) { profile in
                            Button {
                                name = profile.displayName
                                if canEnroll { rememberVoice = true }
                            } label: {
                                HStack {
                                    Text(profile.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if name == profile.displayName {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Speaker name", text: $name)
                    Text("Applies to every passage from this speaker. No re-transcription needed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if canEnroll {
                        Toggle("Remember this voice", isOn: $rememberVoice)
                        Text("Future recordings will label this voice “\(name)” automatically. The voice profile stays on this device and is never exported.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if UserOverlay.isUserDefined(cluster: cluster) {
                        Text("This speaker was added by hand, so there's no voice signature to remember.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Voice enrollment isn't available for this speaker (overlapped speech or no voice signature).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Rename Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name, rememberVoice && canEnroll) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}


// MARK: - Turn editor

/// Holds the whole turn's text rather than one word: ASR mistakes are rarely
/// a single token, and punctuation moves with the word boundaries.
private struct EditTurnSheet: View {
    let speaker: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(speaker)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                TextEditor(text: $text)
                    .font(.system(.body, design: .serif))
                    .focused($focused)
                    .frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Turn text").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                        }
                    }
                    .accessibilityIdentifier("edit-turn-field")
                Text("Corrections are kept separately from the transcription, so re-running speaker matching or a re-merge won't lose them, and reverting brings the original words back.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Edit Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
