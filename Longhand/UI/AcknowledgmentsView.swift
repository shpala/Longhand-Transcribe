import SwiftUI
import LonghandEngines

/// Third-party attributions: MIT (Argmax OSS, Whisper weights), Apache 2.0
/// (swift-transformers portions), CC BY 4.0 (pyannote Community-1). The catalog
/// lives in LonghandEngines, so iOS and macOS show the same list.
struct AcknowledgmentsView: View {

    var body: some View {
        List(Acknowledgments.entries) { entry in
            NavigationLink {
                ScrollView {
                    Text(Acknowledgments.licenseText(for: entry.id))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(entry.title)
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.subheadline.weight(.medium))
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Acknowledgments")
        .navigationBarTitleDisplayMode(.inline)
    }

}
