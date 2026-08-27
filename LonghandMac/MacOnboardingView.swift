import SwiftUI
import LonghandEngines

/// First-launch welcome, the Mac's counterpart to the iOS one. No paging and
/// no upfront permission asks: the microphone prompt belongs to the moment you
/// record. `hasSeenOnboarding` is written by the caller when this sheet is
/// raised, so a crash while it is up does not replay it.
struct MacOnboardingView: View {
    /// The caller swaps this sheet for the record sheet.
    let onRecord: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            BrandMarkTile(size: 88)
            Text("Welcome to Longhand")
                .font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                bullet("mic", "Record a meeting or voice note, or import an existing audio file.")
                bullet("desktopcomputer", "Everything is transcribed on this Mac. The speech models download once; your audio never leaves.")
                bullet("square.and.arrow.down", "Drop an audio file anywhere in the window, or press Command-O to choose one.")
            }
            .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: 12) {
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") {
                    dismiss()
                    onRecord()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(width: 520)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
