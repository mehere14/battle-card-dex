import SwiftUI
import UIKit

struct LibraryCardArtwork: View {
    let card: BattleCardDetail
    let repository: (any ImageRepository)?
    @State private var image: UIImage?
    @State private var failed = false
    private var url: URL? { card.summary.largeImageURL ?? card.summary.smallImageURL }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed || url == nil {
                VStack { Image(systemName: "rectangle.portrait"); Text(card.summary.name).font(.caption).multilineTextAlignment(.center) }.padding()
            } else { ProgressView() }
        }
        .aspectRatio(63.0 / 88, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(card.summary.name)
        .task(id: url) {
            image = nil; failed = false
            guard let url else { return }
            do {
                let data: Data
                if let repository { data = try await repository.data(for: url).value }
                else { data = try await URLSession.shared.data(from: url).0 }
                try Task.checkCancellation()
                image = UIImage(data: data); failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct YourLibraryView: View {
    @ObservedObject var library: LibraryRepository
    let imageRepository: (any ImageRepository)?
    let width: CGFloat
    let explorePacks: () -> Void
    @State private var source: LibrarySource = .scanned
    @State private var selectedCard: BattleCardDetail?
    @AccessibilityFocusState private var focusedCardID: String?
    @State private var lastCardID: String?
    private let design = DesignConstants.standard
    private var entries: [LibraryCardEntry] { library.entries(for: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 26) {
                ForEach(LibrarySource.allCases) { item in
                    Button { source = item } label: {
                        VStack(spacing: 10) {
                            Text(item.title).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
                            Capsule().fill(source == item ? Color(design.palette.secondary) : .clear).frame(height: 3)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Color(source == item ? design.palette.text : design.palette.mutedText))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == item ? .isSelected : [])
                    .accessibilityIdentifier("library-source-\(item.rawValue)")
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(design.palette.outline).opacity(0.25)).frame(height: 1) }
            VStack(alignment: .leading, spacing: 4) {
                Text(source == .scanned ? "Your collection, one scan at a time." : "Every card pulled from virtual packs.")
                Text("\(entries.reduce(0) { $0 + $1.quantity }) cards").font(.caption.weight(.semibold))
            }.font(.subheadline).foregroundStyle(Color(design.palette.mutedText))
            syncStatus
            if library.isLoading && entries.isEmpty { ProgressView("Loading your library…").frame(maxWidth: .infinity, minHeight: 160) }
            else if entries.isEmpty {
                ContentUnavailableView {
                    Label(source == .scanned ? "Give your collection a home." : "Your next favourite is in a pack.", systemImage: "sparkles")
                } description: {
                    Text(source == .scanned ? "Scan your first card to start your library." : "Open a virtual pack to see your pulls here.")
                } actions: {
                    if source == .pulls { Button("Explore Packs", action: explorePacks).buttonStyle(.borderedProminent).tint(Color(design.palette.primary)).foregroundStyle(.black) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width >= 1000 ? 180 : width >= 700 ? 150 : 125), spacing: 18)], spacing: 20) {
                    ForEach(entries) { entry in
                        Button {
                            lastCardID = entry.id; selectedCard = entry.card
                        } label: {
                            LibraryCardArtwork(card: entry.card, repository: imageRepository)
                                .overlay(alignment: .bottomTrailing) {
                                    Text("×\(entry.quantity)").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                                        .foregroundStyle(.white).background(.black.opacity(0.82), in: Capsule()).padding(8)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.card.summary.name), \(entry.quantity) copies")
                        .accessibilityHint("Opens the card viewer")
                        .accessibilityIdentifier("library-card-\(entry.card.id)")
                        .accessibilityFocused($focusedCardID, equals: entry.id)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedCard, onDismiss: { focusedCardID = lastCardID }) { card in
            InteractiveCardViewer(card: card, imageRepository: imageRepository) { selectedCard = nil }
        }
    }
    @ViewBuilder private var syncStatus: some View {
        if let message = library.storageError ?? library.syncError {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "icloud.slash").font(.caption)
                Button("Retry Sync") { Task { await library.retrySync() } }.font(.caption.bold())
            }.foregroundStyle(Color(design.palette.mutedText))
        } else if library.pendingCount > 0 {
            Label("Saved on this device · Waiting to sync", systemImage: "icloud.and.arrow.up").font(.caption).foregroundStyle(Color(design.palette.mutedText))
        } else if library.isSyncing { ProgressView("Syncing library…").font(.caption) }
    }
}

struct LibraryHeader: View {
    let scanCards: () -> Void
    private let design = DesignConstants.standard
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) { heading; Spacer(); scanButton }
            VStack(alignment: .leading, spacing: 12) { heading; scanButton }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Library").font(.largeTitle.bold()).foregroundStyle(Color(design.palette.text))
            Text("Collected by you").font(.subheadline).foregroundStyle(Color(design.palette.mutedText))
        }
    }
    private var scanButton: some View {
        Button(action: scanCards) { Label("Scan Cards", systemImage: "viewfinder").font(.subheadline.bold()).padding(.vertical, 4) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .tint(Color(design.palette.primary)).foregroundStyle(.black)
            .accessibilityIdentifier("library-scan-cards")
    }
}
