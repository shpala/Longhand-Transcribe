import SwiftUI
import LonghandKit
import LonghandEngines

/// Enrolled voice profiles (§9.2, §14.1). Embeddings are biometric-like data:
/// shown here, deletable individually or completely, never exported.
struct EnrolledVoicesView: View {

    /// Re-runs matching on every finished transcript (§10 COMPLETE→IDENTIFIED),
    /// returning how many were re-matched and how many had unreadable
    /// diarization data (§17). Absent when no pipeline model is around.
    var onReidentifyAll: (() async -> (rematched: Int, failed: Int))?

    @State private var profiles: [SpeakerProfile] = []
    @State private var showDeleteAllConfirm = false
    /// Swipe-deleted rows awaiting confirmation.
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var reidentifyResult: (rematched: Int, failed: Int)?
    @State private var isReidentifying = false
    @State private var showEnrollSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if profiles.isEmpty {
                    ContentUnavailableView {
                        VStack(spacing: 16) {
                            BrandMarkTile(size: 84)
                            Text("No enrolled voices").font(.title2.weight(.semibold))
                        }
                    } description: {
                        Text("Record your own voice below, or rename a speaker in a transcript and turn on “Remember this voice”. Voice profiles never leave this device.")
                    } actions: {
                        Button("Record My Voice") { showEnrollSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(profiles) { profile in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName).font(.headline)
                                Text("\(profile.embeddings.count) voice sample\(profile.embeddings.count == 1 ? "" : "s") · enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            pendingDeleteOffsets = offsets
                        }
                        Section {
                            Button {
                                showEnrollSheet = true
                            } label: {
                                Label("Record My Voice", systemImage: "mic.circle")
                            }
                        } footer: {
                            // §9.2 asks for several samples per person across
                            // different conditions, so this is worth doing more
                            // than once rather than being a one-off.
                            Text("Adds another sample. More samples, in different places and on different microphones, make matching more reliable.")
                        }
                        if let onReidentifyAll {
                            Section {
                                Button {
                                    isReidentifying = true
                                    Task {
                                        reidentifyResult = await onReidentifyAll()
                                        isReidentifying = false
                                    }
                                } label: {
                                    Label("Re-identify All Recordings",
                                          systemImage: "person.crop.circle.badge.checkmark")
                                }
                                .disabled(isReidentifying)
                            } footer: {
                                Text("Re-runs speaker matching on finished transcripts using these voice profiles. No re-transcription.")
                            }
                        }
                        Section {
                            Button("Delete All Voice Data", role: .destructive) {
                                showDeleteAllConfirm = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("Enrolled Voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete Voice?",
                isPresented: Binding(get: { pendingDeleteOffsets != nil },
                                     set: { if !$0 { pendingDeleteOffsets = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Voice", role: .destructive) {
                    if let offsets = pendingDeleteOffsets {
                        for offset in offsets {
                            SpeakerProfileStore.delete(id: profiles[offset].id)
                        }
                        profiles = SpeakerProfileStore.load()
                    }
                    pendingDeleteOffsets = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteOffsets = nil }
            } message: {
                Text("This voice profile will be permanently removed from this device. Existing transcripts keep their current speaker names.")
            }
            .confirmationDialog(
                "Delete All Voice Data?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All Voice Data", role: .destructive) {
                    SpeakerProfileStore.deleteAll()
                    profiles = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All enrolled voice profiles will be permanently removed from this device. Existing transcripts keep their current speaker names.")
            }
            .alert("Re-identification Complete",
                   isPresented: Binding(get: { reidentifyResult != nil },
                                        set: { if !$0 { reidentifyResult = nil } })) {
                Button("OK") { reidentifyResult = nil }
            } message: {
                Text(reidentifyMessage)
            }
            .onAppear { profiles = SpeakerProfileStore.load() }
            // Reloaded on dismiss rather than passed back, so a sheet that
            // enrolled and one that was cancelled take the same path.
            .sheet(isPresented: $showEnrollSheet,
                   onDismiss: { profiles = SpeakerProfileStore.load() }) {
                EnrollVoiceSheet()
            }
        }
    }

    private var reidentifyMessage: String {
        guard let result = reidentifyResult else { return "" }
        var message = "Re-ran speaker matching on \(result.rematched) recording\(result.rematched == 1 ? "" : "s")."
        if result.failed > 0 {
            message += " \(result.failed) recording\(result.failed == 1 ? " has" : "s have") unreadable speaker data and \(result.failed == 1 ? "was" : "were") skipped."
        }
        return message
    }
}
