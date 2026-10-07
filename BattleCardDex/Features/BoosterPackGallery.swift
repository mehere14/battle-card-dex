import SwiftUI
import UIKit

struct BoosterPackArtwork: Identifiable, Hashable {
    let setID: String
    let name: String
    let year: Int
    let recordID: String
    let sourceVariantPath: String

    var id: String { setID }

    var bundledFallbackName: String? {
        ["me1": "PackMegaEvolution", "me2": "PackPhantasmalFlames", "me3": "PackPerfectOrder",
         "me4": "PackChaosRising", "me5": "PackPitchBlack"][setID]
    }
}

struct BoosterPackTile: View {
    let pack: BoosterPackArtwork
    let repository: PackArtworkRepository?
    @State private var artwork: UIImage?

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let artwork { Image(uiImage: artwork).resizable() }
                else if let fallback = pack.bundledFallbackName { Image(fallback).resizable() }
                else { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)).overlay(ProgressView().tint(.yellow)) }
            }
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .aspectRatio(0.55, contentMode: .fit)
                .shadow(color: .black.opacity(0.62), radius: 12, y: 9)
            VStack(spacing: 2) {
                Text(pack.name)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(minHeight: 38, alignment: .top)
        }
        .padding(12)
        .background(
            LinearGradient(colors: [.white.opacity(0.13), .purple.opacity(0.13)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.13)))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pack.name), \(pack.year)")
        .accessibilityHint("Opens this booster pack")
        .task(id: pack.recordID) {
            guard let repository,
                  let data = try? await repository.data(recordID: pack.recordID, resolution: .thumbnail) else { return }
            artwork = UIImage(data: data)
        }
    }
}
