import SwiftUI
import LonghandKit
import LonghandEngines

/// A transcript in a window of its own, for reading two side by side on
/// iPad. The same screen the library pushes, over the same library model,
/// so a correction made here shows in the library's copy and the other way
/// round. A recording deleted while its window is open leaves a placeholder
/// rather than a screen that never loads.
struct TranscriptWindow: View {
    @Binding var jobID: UUID?
    @State private var model = AppLibrary.model

    var body: some View {
        NavigationStack {
            if let jobID, model.jobs.contains(where: { $0.id == jobID }) {
                TranscriptView(jobID: jobID)
                    .environment(model)
                    .id(jobID)
            } else {
                ContentUnavailableView {
                    Label("Recording Deleted", systemImage: "waveform.slash")
                } description: {
                    Text("This recording is no longer in the library.")
                }
                .background(Color("LonghandBackground").ignoresSafeArea())
            }
        }
        .onAppear { model.refresh() }
    }
}
