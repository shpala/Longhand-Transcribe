import SwiftUI

/// The app's waveform-script mark, reused on empty states.
struct BrandMarkTile: View {
    var size: CGFloat = 84

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .shadow(color: Color("LonghandIndigo").opacity(0.35), radius: size * 0.08, y: size * 0.04)
            .accessibilityHidden(true)
    }
}
