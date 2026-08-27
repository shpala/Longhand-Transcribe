import SwiftUI

/// First-launch welcome: one screen, shown once, never over a library that
/// already has content. `hasSeenOnboarding` is written by the caller when this
/// sheet is raised, so a kill while it is up does not replay it.
///
/// It mentions recording, so App Review treats it as a message ahead of the
/// microphone prompt (guideline 5.1.1(iv)): its only button is a neutral
/// "Continue", and that always goes on to the system prompt. No "Not now", and
/// no "Start Recording" that reads as the price of granting access. Whatever
/// the answer, it lands in the library; a refusal is met again, with a way to
/// Settings, by the record sheet.
struct OnboardingView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            BrandMarkTile(size: 96)
            Text("Welcome to Longhand")
                .font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 16) {
                bullet("mic", "Record a meeting or voice note, or import an existing audio file.")
                bullet("iphone", "Everything is transcribed on this device. The speech models download once; your audio never leaves.")
                bullet("applewatch", "Record from your wrist with the optional Apple Watch companion.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            Spacer()
            Button {
                asking = true
                Task {
                    _ = await RecorderService.requestPermission()
                    dismiss()
                }
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .disabled(asking)
            Spacer().frame(height: 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("LonghandBackground").ignoresSafeArea())
        // Swiping it away would be "Not now" by another name.
        .interactiveDismissDisabled()
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
