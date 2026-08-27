import SwiftUI

/// First-launch welcome: one screen, shown once, never over a library that
/// already has content. No paging and no upfront permission asks: the
/// microphone prompt belongs to the moment you record. `hasSeenOnboarding` is
/// written by the caller when this sheet is raised, so a kill while it is up
/// does not replay it.
struct OnboardingView: View {

    /// The caller swaps this sheet for the record sheet.
    let onRecord: () -> Void

    @Environment(\.dismiss) private var dismiss

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
                dismiss()
                onRecord()
            } label: {
                Text("Start Recording")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            Button("Not now") { dismiss() }
                .foregroundStyle(.secondary)
            Spacer().frame(height: 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("LonghandBackground").ignoresSafeArea())
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
