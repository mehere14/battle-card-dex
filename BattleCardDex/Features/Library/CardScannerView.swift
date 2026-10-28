import SwiftUI
import UIKit

struct CardScannerView: View {
    @ObservedObject var library: LibraryRepository
    let imageRepository: (any ImageRepository)?
    @StateObject private var scanner: CardScannerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let design = DesignConstants.standard
    private let simulated: Bool

    init(library: LibraryRepository, imageRepository: (any ImageRepository)?) {
        self.library = library; self.imageRepository = imageRepository
#if DEBUG
        let outcome = ProcessInfo.processInfo.environment["BATTLE_CARD_DEX_SCAN_OUTCOME"]
        simulated = outcome != nil
        _scanner = StateObject(wrappedValue: CardScannerModel(library: library,
            recognizer: outcome.map { ScannerFixtureRecognition(outcome: $0) as any CardRecognizing } ?? CardRecognitionService(),
            defaults: outcome == nil ? .standard : UserDefaults(suiteName: "scanner-fixture-\(UUID().uuidString)")!))
#else
        simulated = false
        _scanner = StateObject(wrappedValue: CardScannerModel(library: library))
#endif
    }
    private var showingResult: Bool {
        switch scanner.phase { case .found, .saving, .added, .saveFailed: true; default: false }
    }
    private var cameraActive: Bool {
        guard scanner.photo == nil, scenePhase == .active else { return false }
        return switch scanner.phase { case .starting, .ready, .processing: true; default: false }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if showingResult {
                    Color(design.palette.background).ignoresSafeArea()
                } else {
                    cameraSurface(size: geometry.size).ignoresSafeArea()
                    LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                }
                content(size: CGSize(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 98)))
                    .padding(.top, 74).padding(.horizontal, 24).padding(.bottom, 24)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .top) {
                HStack {
                    Text(showingResult ? "Your collection" : "Scan a card").font(.subheadline.bold())
                    Spacer()
                    Button { scanner.cancel(); dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                            .background(showingResult ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.black.opacity(0.4)), in: Circle())
                    }.accessibilityLabel("Close scanner").accessibilityIdentifier("library-scanner-close")
                }.padding(.horizontal, 24).padding(.top, 12)
            }
            .foregroundStyle(showingResult ? Color(design.palette.text) : .white)
        }
        .onAppear { if simulated { scanner.cameraEvent(.ready) } }
        .onDisappear { scanner.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scanner.backgrounded() }
            else { scanner.resumed(); if simulated { scanner.cameraEvent(.ready) }; Task { await library.start() } }
        }
        .onChange(of: scanner.phase) { _, phase in
            let message: String?
            switch phase {
            case .processing: message = "Finding your card"
            case .found: message = "Card found"
            case .added: message = "Added to Library"
            case .failed(let text): message = text
            case .choosing: message = "Choose the matching artwork"
            default: message = nil
            }
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
    }
    @ViewBuilder private func cameraSurface(size: CGSize) -> some View {
        if let photo = scanner.photo {
            Color.black.overlay {
                Image(uiImage: photo).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height).clipped()
            }.frame(width: size.width, height: size.height).clipped().accessibilityHidden(true)
        } else if simulated {
            GeometryReader { proxy in
                let width = min(proxy.size.width * 0.78, proxy.size.height * 0.8 * 63 / 88)
                ZStack {
                    Color(red: 0.16, green: 0.23, blue: 0.19)
                    RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                        .frame(width: width, height: width * 88 / 63)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.accessibilityHidden(true)
        }
        else if cameraActive {
            let token = scanner.cameraID
            CardCamera(shutterRequest: scanner.shutterRequest, onCapture: { image, text in
                guard token == scanner.cameraID, scenePhase == .active else { return }
                scanner.captured(image, text: text)
            }, onStatus: { _ in }, onEvent: { event in
                guard token == scanner.cameraID, scenePhase == .active else { return }
                scanner.cameraEvent(event)
            }).id(token).accessibilityHidden(true)
        }
        else { Color.black }
    }
    @ViewBuilder private func content(size: CGSize) -> some View {
        switch scanner.phase {
        case .starting:
            VStack(spacing: 12) { ProgressView().tint(.white); Text("Starting camera…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack {
                Spacer()
                Text(simulated ? "Take a photo of your card" : "Tap the shutter to photograph and identify your card.").font(.subheadline).multilineTextAlignment(.center)
                if simulated { Button {
                    scanner.capture()
                    if simulated { scanner.captured(scannerFixturePhoto(), text: "fixture") }
                } label: {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 74, height: 74)
                        .overlay { Circle().fill(.white).padding(7) }
                }
                .buttonStyle(.plain).padding(.top, 14)
                .accessibilityLabel("Capture card photo").accessibilityIdentifier("card-scanner-shutter") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .processing:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(Color(design.palette.primary))
                Text("Finding your card…").font(.title2.bold())
                Text("Reading the card and matching its artwork").font(.subheadline).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("card-scanner-status")
        case .choosing(let matches):
            VStack(spacing: 18) {
                Text("Choose the matching artwork").font(.title2.bold()).multilineTextAlignment(.center)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size.width > size.height ? 120 : 135), spacing: 16)], spacing: 16) {
                        ForEach(matches) { card in
                            Button { scanner.choose(card) } label: {
                                VStack(spacing: 8) {
                                    LibraryCardArtwork(card: card, repository: imageRepository)
                                    Text("\(card.summary.setName) · \(card.summary.collectorNumber)").font(.caption).multilineTextAlignment(.center)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("Choose \(card.summary.name), \(card.summary.setName), \(card.summary.collectorNumber)")
                        }
                    }
                }
                retryButton
            }
        case .found(let card), .saving(let card), .added(let card), .saveFailed(let card, _):
            if size.width > size.height {
                HStack(spacing: 28) {
                    LibraryCardArtwork(card: card, repository: imageRepository)
                        .frame(width: min(size.width * 0.4, size.height * 0.82 * 63 / 88), height: size.height * 0.82)
                    ScrollView { resultControls(card: card) }.frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        let cardHeight = min(size.width * 0.88 * 88 / 63, max(160, size.height - 300))
                        LibraryCardArtwork(card: card, repository: imageRepository)
                            .frame(width: cardHeight * 63 / 88, height: cardHeight)
                        resultControls(card: card)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
        case .failed(let message):
            ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "viewfinder").font(.largeTitle)
                Text(message).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                let details = scanner.errorDetails ?? message
                VStack(alignment: .leading, spacing: 10) {
                        Text("Scan error details").font(.headline)
                        Text(details).font(.footnote.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("card-scanner-error-details")
                        Button("Copy Error Details") { UIPasteboard.general.string = scanner.errorReport(message: message) }
                            .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                retryButton
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }.defaultScrollAnchor(.center)
        case .permissionDenied:
            VStack(spacing: 18) {
                Image(systemName: "camera.fill").font(.largeTitle)
                Text("Allow camera access in Settings to scan your cards.").font(.title3).multilineTextAlignment(.center)
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    .buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func resultControls(card: BattleCardDetail) -> some View {
        VStack(spacing: 14) {
            Text(isAdded ? "ADDED TO LIBRARY" : "CARD FOUND").font(.caption.bold()).tracking(1.6).foregroundStyle(Color(design.palette.focus))
                .accessibilityIdentifier("scanner-result-status")
            Text(card.summary.name).font(.title.bold())
            Text("\(card.summary.setName) · \(card.summary.collectorNumber)").font(.subheadline).foregroundStyle(Color(design.palette.mutedText))
            if isAdded {
                if library.pendingCount > 0 { Text("Saved on this device · Waiting to sync").font(.caption).foregroundStyle(Color(design.palette.mutedText)) }
                HStack(spacing: 14) {
                    Button("Scan Another") { scanner.reset(); if simulated { scanner.cameraEvent(.ready) } }.buttonStyle(.borderedProminent).foregroundStyle(Color(design.palette.onPrimary))
                    Button("Done") { dismiss() }.buttonStyle(.bordered)
                }
            } else {
                if case .saveFailed(_, let message) = scanner.phase { Text(message).font(.caption).multilineTextAlignment(.center).foregroundStyle(Color(design.palette.mutedText)) }
                Button(saveFailed ? "Retry Add" : "Add to Library") { scanner.add() }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color(design.palette.onPrimary)).disabled(isSaving)
                    .accessibilityIdentifier("scanner-add-to-library")
            }
            Toggle(isOn: Binding(get: { scanner.autoAdd }, set: { scanner.setAutoAdd($0) })) {
                Text("Automatically add future scans").font(.subheadline)
            }.toggleStyle(ScannerCheckboxStyle()).accessibilityIdentifier("scanner-auto-add")
        }
        .tint(Color(design.palette.primary))
        .buttonBorderShape(.capsule)
    }
    private func scannerFixturePhoto() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 2400), format: format).image { context in
            UIColor.darkGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1500, height: 2400))
        }
    }
    private var isAdded: Bool { if case .added = scanner.phase { true } else { false } }
    private var isSaving: Bool { if case .saving = scanner.phase { true } else { false } }
    private var saveFailed: Bool { if case .saveFailed = scanner.phase { true } else { false } }
    private var retryButton: some View {
        Button("Try Again") { scanner.reset(); if simulated { scanner.cameraEvent(.ready) } }
            .buttonStyle(.borderedProminent).tint(Color(design.palette.primary)).foregroundStyle(.black)
    }
}

private struct ScannerCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square").font(.title3)
                configuration.label
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("Automatically add future scans")
            .accessibilityValue(configuration.isOn ? "On" : "Off").accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

#if DEBUG
@MainActor
struct ScannerFixtureRecognition: CardRecognizing {
    let outcome: String
    func recognize(text: String) async throws -> [BattleCardDetail] {
        try await Task.sleep(for: .milliseconds(300))
        switch outcome {
        case "missing": return []
        case "error": throw ScannerFailure.message("Fixture recognition failure")
        case "multiple": return Array(CatalogViewModel.preview().cards.prefix(2))
        default: return Array(CatalogViewModel.preview().cards.prefix(1))
        }
    }
}
#endif
