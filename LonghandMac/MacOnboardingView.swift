import SwiftUI
import LonghandEngines

/// First-launch welcome, the Mac's counterpart to the iOS one, under the same
/// App Review rule (guideline 5.1.1(iv)): a message ahead of the microphone
/// prompt has one neutral button, and it always goes on to the prompt. Then
/// the library, whatever the answer. `hasSeenOnboarding` is written by the
/// caller when this sheet is raised, so a crash while it is up does not replay
/// it.
struct MacOnboardingView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

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
            Button("Continue") {
                asking = true
                Task {
                    _ = await MacRecorderService.requestPermission()
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(asking)
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
