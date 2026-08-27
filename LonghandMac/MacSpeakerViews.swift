import SwiftUI
import LonghandKit
import LonghandEngines

/// Rename a speaker cluster, optionally enrolling their voice (§15.3, §9.2).
struct MacRenameSpeakerSheet: View {
    let cluster: String
    @State var name: String
    let canEnroll: Bool
    let onSave: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var rememberVoice = false
    @State private var profiles: [SpeakerProfile] = SpeakerProfileStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rename Speaker")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)
            Form {
                if !profiles.isEmpty {
                    // §15.3: assign the cluster to someone already enrolled
                    // instead of retyping their name.
                    Section("This is…") {
                        ForEach(profiles) { profile in
                            Button {
                                name = profile.displayName
                                if canEnroll { rememberVoice = true }
                            } label: {
                                HStack {
                                    Text(profile.displayName)
                                    Spacer()
                                    if name == profile.displayName {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    TextField("Speaker name", text: $name)
                        .onSubmit { if !trimmed.isEmpty { save() } }
                    Text("Applies to every passage from this speaker. No re-transcription needed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if canEnroll {
                        Toggle("Remember this voice", isOn: $rememberVoice)
                        Text("Future recordings will label this voice “\(name)” automatically. The voice profile stays on this Mac and is never exported.")
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
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 420)
        .frame(maxHeight: 520)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() { onSave(trimmed, rememberVoice && canEnroll) }
}

/// Naming a speaker the diarizer never separated out. Smaller than the rename
/// sheet: there is no voice behind this person, so nothing to enrol.
struct MacNewSpeakerSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Who is this?")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)
            Form {
                Section {
                    TextField("Speaker name", text: $name)
                        .onSubmit { if !trimmed.isEmpty { onSave() } }
                    Text("Applies to this passage only. The voice detection's own answer is kept, so enrollment and re-identification are unaffected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Once named, this person appears in the list, so the next passage you correct can be attributed to them in one click.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
}

/// Enrolled voice profiles (§9.2, §14.1). Embeddings are biometric-like:
/// listed here, deletable one-by-one or completely, never exported.
struct MacEnrolledVoicesView: View {
    let model: JobLibraryModel

    @State private var profiles: [SpeakerProfile] = []
    @State private var selection: Set<UUID> = []
    @State private var showDeleteAllConfirm = false
    /// Staged for deletion: §14.1 biometric-like data, deleted permanently.
    @State private var pendingDelete: Set<UUID>?
    @State private var reidentifyResult: (rematched: Int, failed: Int, skipped: Int)?
    /// The shared `reidentifyAll()` is one await with no window into the
    /// middle, so the loop lives here instead.
    @State private var reidentifyProgress: (done: Int, total: Int)?
    @State private var reidentifyTask: Task<Void, Never>?
    @State private var showEnrollSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if profiles.isEmpty {
                ContentUnavailableView {
                    Text("No enrolled voices").font(.title3.weight(.semibold))
                } description: {
                    Text("Record your own voice below, or rename a speaker in a transcript and turn on “Remember this voice”. Voice profiles never leave this Mac.")
                } actions: {
                    Button("Record My Voice") { showEnrollSheet = true }
                }
            } else {
                List(selection: $selection) {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName).font(.headline)
                            Text("\(profile.embeddings.count) voice sample\(profile.embeddings.count == 1 ? "" : "s") · enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(profile.id)
                        .contextMenu {
                            Button("Delete…", role: .destructive) { pendingDelete = [profile.id] }
                        }
                    }
                }
                .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
                HStack {
                    Button("Delete Selected…", role: .destructive) { pendingDelete = selection }
                        .disabled(selection.isEmpty)
                    // §9.2 prefers several samples per person across different
                    // conditions, so this stays available once someone is
                    // enrolled rather than being a one-off.
                    Button("Record My Voice") { showEnrollSheet = true }
                    Spacer()
                    if let progress = reidentifyProgress {
                        ProgressView(value: Double(progress.done),
                                     total: Double(max(progress.total, 1)))
                            .frame(width: 120)
                        Text("\(progress.done) of \(progress.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Cancel") { reidentifyTask?.cancel() }
                    } else {
                        Button {
                            startReidentifyAll()
                        } label: {
                            Label("Re-identify All Recordings",
                                  systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                }
                Text("Re-identification re-runs speaker matching on finished transcripts using these voice profiles. No re-transcription.")
                    .font(.footnote).foregroundStyle(.secondary)
                Divider()
                Button("Delete All Voice Data", role: .destructive) { showDeleteAllConfirm = true }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .confirmationDialog(pendingDeleteTitle,
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This voice profile will be permanently removed from this Mac. Existing transcripts keep their current speaker names.")
        }
        .confirmationDialog("Delete All Voice Data?",
                            isPresented: $showDeleteAllConfirm,
                            titleVisibility: .visible) {
            Button("Delete All Voice Data", role: .destructive) {
                SpeakerProfileStore.deleteAll()
                profiles = []
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All enrolled voice profiles will be permanently removed from this Mac. Existing transcripts keep their current speaker names.")
        }
        .alert(reidentifyTitle,
               isPresented: Binding(get: { reidentifyResult != nil },
                                    set: { if !$0 { reidentifyResult = nil } })) {
            Button("OK") { reidentifyResult = nil }
        } message: {
            Text(reidentifyMessage)
        }
        .onAppear { profiles = SpeakerProfileStore.load() }
        // Reloaded on dismiss rather than passed back, so a sheet that enrolled
        // and one that was cancelled take the same path.
        .sheet(isPresented: $showEnrollSheet,
               onDismiss: { profiles = SpeakerProfileStore.load() }) {
            EnrollVoiceSheet().frame(width: 460, height: 420)
        }
        .onDisappear { reidentifyTask?.cancel() }
    }

    private var pendingDeleteTitle: String {
        guard let pendingDelete else { return "Delete Voice?" }
        if pendingDelete.count == 1,
           let profile = profiles.first(where: { pendingDelete.contains($0.id) }) {
            return "Delete “\(profile.displayName)”?"
        }
        return "Delete \(pendingDelete.count) Voices?"
    }

    /// The model's `reidentifyAll()` walk, reporting position and honouring
    /// cancellation between recordings, which is the only place a cancel can
    /// land: each re-match is synchronous.
    private func startReidentifyAll() {
        let jobs = model.jobs.filter { $0.state == .complete }
        reidentifyProgress = (0, jobs.count)
        reidentifyTask = Task { @MainActor in
            var rematched = 0, failed = 0, visited = 0
            for job in jobs {
                if Task.isCancelled { break }
                visited += 1
                // Each pass rewrites five exports; without a suspension point
                // the bar never gets a chance to move.
                await Task.yield()
                do {
                    if try model.reidentify(jobID: job.id) { rematched += 1 }
                } catch {
                    failed += 1
                }
                reidentifyProgress = ((reidentifyProgress?.done ?? 0) + 1, jobs.count)
            }
            model.refresh()
            // A cancel two recordings into fifty must not read as a full pass.
            reidentifyResult = (rematched, failed, jobs.count - visited)
            reidentifyProgress = nil
            reidentifyTask = nil
        }
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { SpeakerProfileStore.delete(id: id) }
        profiles = SpeakerProfileStore.load()
        selection = []
    }

    private var reidentifyTitle: String {
        (reidentifyResult?.skipped ?? 0) > 0 ? "Re-identification Stopped" : "Re-identification Complete"
    }

    private var reidentifyMessage: String {
        guard let result = reidentifyResult else { return "" }
        var message = "Re-ran speaker matching on \(result.rematched) recording\(result.rematched == 1 ? "" : "s")."
        if result.failed > 0 {
            message += " \(result.failed) recording\(result.failed == 1 ? " has" : "s have") unreadable speaker data and \(result.failed == 1 ? "was" : "were") skipped."
        }
        if result.skipped > 0 {
            message += " Stopped before \(result.skipped) more recording\(result.skipped == 1 ? "" : "s"). Run it again to finish."
        }
        return message
    }
}

/// Mac Settings window: the transcription defaults the import paths read,
/// plus voice management.
struct MacSettingsView: View {
    @AppStorage("defaultImportLanguage") private var declaredLanguage = "system"
    @AppStorage("defaultSpeakerCount") private var speakerCount = 0
    @AppStorage(WhisperModelVariant.defaultsKey) private var whisperVariant =
        WhisperModelVariant.turbo.rawValue
    @AppStorage(LocationCapture.settingsKey) private var captureLocation = false
    @State private var diskUsage: Int64 = 0
    @State private var leftoverBytes: Int64 = 0

    var body: some View {
        TabView {
            Form {
                LanguagePicker(declaredLanguage: $declaredLanguage)
                Picker("Speakers", selection: $speakerCount) {
                    Text("Auto").tag(0)
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Save location with recordings", isOn: $captureLocation)
                Text("Off by default. Tags new recordings made on this Mac with where they were made. Stored only on this Mac, shown only to you, and never included in exports.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Whisper model", selection: $whisperVariant) {
                    ForEach(WhisperModelVariant.selectable, id: \.rawValue) { variant in
                        Text(variant.displayName).tag(variant.rawValue)
                    }
                }
                ForEach(WhisperModelVariant.selectable, id: \.rawValue) { variant in
                    MacModelRow(variant: variant)
                }
                LabeledContent("Used by recordings",
                               value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                // Shown only when there is something to see: a healthy install
                // leaves nothing staged, and a row reading "Zero KB" forever
                // would be noise standing in for a fact worth surfacing.
                if leftoverBytes > 0 {
                    LabeledContent("Interrupted downloads",
                                   value: ByteCountFormatter.string(fromByteCount: leftoverBytes, countStyle: .file))
                    Button("Clean Up") {
                        for root in ModelStaging.vendorRoots { ModelStaging.sweep(in: root) }
                        leftoverBytes = ModelStaging.totalLeftoverBytes()
                    }
                }
                Text("Maximum accuracy uses the full large-v3 model: a bigger one-time download and noticeably slower transcription. Re-transcribe an existing recording to apply a new choice to it. Model downloads are the only network activity in this app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(width: 460)
            .onAppear {
                diskUsage = MacLibrary.model.totalDiskUsage()
                leftoverBytes = ModelStaging.totalLeftoverBytes()
                // A Mac left on a build this screen no longer lists would keep
                // using it with nothing saying so.
                if !WhisperModelVariant.selectable.map(\.rawValue).contains(whisperVariant) {
                    whisperVariant = WhisperModelVariant.turbo.rawValue
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            MacEnrolledVoicesView(model: MacLibrary.model)
                .tabItem { Label("Voices", systemImage: "person.wave.2") }

            MacAcknowledgmentsView()
                .tabItem { Label("Acknowledgments", systemImage: "text.document") }
        }
    }
}

/// Third-party attributions (§4.3 audit), from the same catalog the iOS app
/// shows.
struct MacAcknowledgmentsView: View {
    @State private var selection: String? = Acknowledgments.entries.first?.id

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(Acknowledgments.entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.weight(.medium))
                        Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                }
                .frame(minWidth: 240, idealWidth: 260)
                ScrollView {
                    Text(selection.map(Acknowledgments.licenseText(for:)) ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minWidth: 340)
            }
            Divider()
            Text("Longhand processes everything on this Mac. Nothing is uploaded; model downloads are the only network activity.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

/// One model variant's state, and a way to fetch it before it is needed.
private struct MacModelRow: View {
    let variant: WhisperModelVariant

    @State private var downloading = false
    @State private var fraction: Double = 0
    @State private var refreshToken = 0
    @State private var error: String?
    @State private var confirmingDelete = false
    /// A run holds its weights open and re-reads them per chunk, so deleting
    /// underneath one fails the job. The engine cannot see jobs; this can.
    private var libraryIsBusy: Bool { !MacLibrary.model.runningJobs.isEmpty }

    var body: some View {
        let installed = isInstalled
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.displayName).font(.subheadline)
                Text(installed
                     ? "Downloaded · \(ByteCountFormatter.string(fromByteCount: WhisperKitEngine.downloadedBytes(for: variant), countStyle: .file))"
                     : "Not downloaded · \(ByteCountFormatter.string(fromByteCount: variant.approximateBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if downloading {
                ProgressView(value: fraction).frame(width: 90)
            } else if installed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Delete") { confirmingDelete = true }
                    .disabled(libraryIsBusy)
            } else {
                Button("Download") { download() }
            }
        }
        .confirmationDialog("Delete \(variant.displayName)?",
                            isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                WhisperKitEngine.delete(variant)
                refreshToken += 1
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Frees \(ByteCountFormatter.string(fromByteCount: WhisperKitEngine.reclaimableBytes(for: variant), countStyle: .file)) now. It downloads again the next time a recording needs it. Existing transcripts are unaffected.")
        }
        .alert("Couldn't Download Model",
               isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var isInstalled: Bool {
        _ = refreshToken
        return WhisperKitEngine.isDownloaded(variant)
    }

    private func download() {
        downloading = true
        fraction = 0
        Task {
            do {
                try await WhisperKitEngine.prefetch(variant) { value in
                    Task { @MainActor in fraction = value }
                }
            } catch {
                self.error = JobLibraryModel.describe(error)
            }
            downloading = false
            refreshToken += 1
        }
    }
}

/// Language and speaker options for an Open-panel import (§7.1: a forced
/// speaker count must be declared, never guessed).
struct MacImportOptionsSheet: View {
    let fileNames: [String]
    @Binding var declaredLanguage: String
    @Binding var speakerCount: Int
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(fileNames.count == 1 ? "Import \(fileNames[0])" : "Import \(fileNames.count) recordings")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .padding(.bottom, 12)
            Form {
                LanguagePicker(declaredLanguage: $declaredLanguage)
                Picker("Expected speakers", selection: $speakerCount) {
                    Text("Don't know").tag(0)
                    // 1 included: a saved value with no matching entry renders
                    // an empty picker.
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                Text("These become your defaults for future imports; a dragged-in file uses them without asking.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 420)
    }
}
