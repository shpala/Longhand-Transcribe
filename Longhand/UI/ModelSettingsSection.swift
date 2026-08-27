import SwiftUI
import LonghandEngines

/// The Whisper weights this app downloads, with their sizes, so the first
/// recording is not where you find out about them (§14.2).
///
/// The phone offers the same two builds the Mac does (§6.1). It briefly
/// offered only `turbo`, on the reasoning that a Mac has the thermal headroom
/// for a choice a phone does not; the tradeoff is real, so it is stated on this
/// screen rather than made on the owner's behalf.
struct ModelSettingsSection: View {

    @AppStorage(WhisperModelVariant.defaultsKey) private var whisperVariant =
        WhisperModelVariant.turbo.rawValue

    /// Outside the view, so reopening Settings mid-download does not show the
    /// model as "Not downloaded" with a Download button.
    @State private var downloads = ModelDownloadState.shared
    @State private var error: String?
    /// Bumped after a download or a delete so the presence checks re-run.
    @State private var refreshToken = 0
    /// The variant whose delete is awaiting confirmation. Deleting costs a
    /// re-download rather than data, but on cellular that is 626 MB of
    /// somebody's plan, so it is worth one tap to be sure.
    @State private var pendingDelete: WhisperModelVariant?
    /// A run holds its weights open and re-reads them per chunk, so deleting
    /// underneath one fails the job. The engine cannot see jobs; this can.
    private var libraryIsBusy: Bool { !AppLibrary.model.runningJobs.isEmpty }

    private var selected: WhisperModelVariant {
        WhisperModelVariant(rawValue: whisperVariant) ?? .turbo
    }

    var body: some View {
        Section {
            Picker("Model", selection: $whisperVariant) {
                ForEach(WhisperModelVariant.selectable, id: \.rawValue) { variant in
                    Text(variant.displayName).tag(variant.rawValue)
                }
            }
            // Follows the selection, so the cost of a choice is readable while
            // it is being made rather than after a slow recording.
            Text(selected.speedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("whisper-variant-note")
            ForEach(WhisperModelVariant.selectable, id: \.rawValue) { variant in
                row(for: variant)
            }
        } header: {
            Text("Transcription Model")
        } footer: {
            Text("Used for languages Apple's speech recognition does not cover. Maximum accuracy is the full large-v3 model rather than the distilled one: a larger one-time download, several times slower on a phone, and warm enough on a long recording that the system may slow it further. Each build downloads once, and those downloads are the only network activity in this app. Changing this affects new recordings; re-transcribe an existing one to apply it there.\n\nDeleting a model frees its space now and costs the download again the next time a recording needs it. Nothing you have already transcribed is affected.")
        }
        // A phone left on a build this screen does not list would keep using it
        // with nothing saying so.
        .onAppear {
            if !WhisperModelVariant.selectable.map(\.rawValue).contains(whisperVariant) {
                whisperVariant = WhisperModelVariant.turbo.rawValue
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let variant = pendingDelete {
                Button("Delete \(onDisk(variant))", role: .destructive) { delete(variant) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let variant = pendingDelete {
                Text(variant.rawValue == whisperVariant
                     ? "This is the model currently selected, so the next recording that needs it will download it again."
                     : "It will download again if you select it, or if a recording needs it.")
            }
        }
        .alert("Couldn't Download Model",
               isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func row(for variant: WhisperModelVariant) -> some View {
        let installed = isInstalled(variant)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.displayName).font(.subheadline)
                Text(installed ? "Downloaded · \(onDisk(variant))" : "Not downloaded · \(size(variant))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = downloads.fraction(for: variant) {
                ProgressView(value: progress).frame(width: 80)
            } else if installed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Delete") { pendingDelete = variant }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(libraryIsBusy || downloads.isDownloading)
                    .accessibilityIdentifier("delete-model-\(variant.rawValue)")
            } else {
                Button("Download") { download(variant) }
                    .buttonStyle(.bordered)
                    .disabled(downloads.isDownloading)
            }
        }
        .accessibilityIdentifier("whisper-model-\(variant.rawValue)")
    }

    private func isInstalled(_ variant: WhisperModelVariant) -> Bool {
        _ = refreshToken
        return WhisperKitEngine.isDownloaded(variant)
    }

    private func size(_ variant: WhisperModelVariant) -> String {
        ByteCountFormatter.string(fromByteCount: variant.approximateBytes, countStyle: .file)
    }

    private func onDisk(_ variant: WhisperModelVariant) -> String {
        ByteCountFormatter.string(fromByteCount: WhisperKitEngine.downloadedBytes(for: variant), countStyle: .file)
    }

    private func delete(_ variant: WhisperModelVariant) {
        WhisperKitEngine.delete(variant)
        pendingDelete = nil
        refreshToken += 1
    }

    private func download(_ variant: WhisperModelVariant) {
        Task {
            if let failure = await downloads.download(variant) {
                error = failure
            }
            refreshToken += 1
        }
    }
}


/// One place that knows which model is downloading and how far along, so
/// reopening Settings neither loses sight of it nor offers to start it again.
@Observable
@MainActor
final class ModelDownloadState {
    static let shared = ModelDownloadState()

    private var progressByVariant: [String: Double] = [:]
    var isDownloading: Bool { !progressByVariant.isEmpty }

    func fraction(for variant: WhisperModelVariant) -> Double? {
        progressByVariant[variant.rawValue]
    }


    /// A message on failure, nil on success. A second call for a variant
    /// already downloading is ignored.
    func download(_ variant: WhisperModelVariant) async -> String? {
        guard progressByVariant[variant.rawValue] == nil else { return nil }
        progressByVariant[variant.rawValue] = 0
        defer { progressByVariant[variant.rawValue] = nil }
        do {
            try await WhisperKitEngine.prefetch(variant) { [weak self] value in
                Task { @MainActor in self?.progressByVariant[variant.rawValue] = value }
            }
            return nil
        } catch {
            return JobLibraryModel.describe(error)
        }
    }
}
