#if DEBUG
import SwiftUI

@MainActor
struct DebugCardScannerView: View {
    let imageRepository: (any ImageRepository)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableSize = CGSize(width: 390, height: 800)
    @State private var scanID = UUID()
    @State private var shutterRequest = UUID()
    @State private var status = "Starting camera…"
    @State private var photo: UIImage?
    @State private var ocr = ""
    @State private var json = ""
    @State private var candidates: [BattleCardDetail] = []
    @State private var selected: BattleCardDetail?
    @State private var processing = false
    @State private var request: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLandscape {
                        HStack(alignment: .center, spacing: 20) {
                            cameraSurface
                            captureControls.frame(maxWidth: .infinity)
                        }
                    } else {
                        cameraSurface
                        captureControls
                    }
                    if candidates.count > 1 {
                        Text("Multiple catalog matches. Choose the matching artwork.")
                        ForEach(candidates) { card in
                            Button { selected = card } label: {
                                HStack {
                                    if let url = card.summary.smallImageURL {
                                        AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                                            .frame(width: 65, height: 90)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(card.summary.name)
                                        Text("\(card.summary.setName) · \(card.summary.collectorNumber)").font(.caption)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if !json.isEmpty { debugText("Gemini structured output", text: json) }
                    if !ocr.isEmpty { debugText("OCR text", text: ocr) }
                    Text("Debug experiment · \(DebugCardRecognition.modelName) · No collection changes")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Card Scanner Lab")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if let selected {
                    InteractiveCardViewer(card: selected, imageRepository: imageRepository) { self.selected = nil }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { availableSize = $0 }
        .onDisappear { request?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                request?.cancel()
                if processing { status = "Scan interrupted. Tap Scan another card to retry." }
                processing = false
            }
            else if photo == nil { scanID = UUID() }
        }
    }

    private var isLandscape: Bool { availableSize.width > availableSize.height }

    private var cameraSurface: some View {
        ZStack {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFit()
            } else if scenePhase == .active {
                camera
            } else { Color.black }
            if selected == nil && (photo == nil || processing) {
                scanLine
            }
        }
        .frame(width: cameraWidth, height: cameraHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("Automatic card scanning camera")
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if photo == nil {
                Button { shutterRequest = UUID() } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 58)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(.black, in: RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityLabel("Capture card photo")
                .accessibilityIdentifier("card-scanner-shutter")
                .disabled(scenePhase != .active)
            }
            Text(status).font(.headline).accessibilityIdentifier("card-scanner-status")
            if processing { ProgressView() }
            if photo != nil {
                Button("Scan another card") { reset() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var cameraHeight: CGFloat {
        isLandscape
            ? max(140, availableSize.height - 32)
            : min(420, max(220, availableSize.height * 0.55))
    }
    private var cameraWidth: CGFloat {
        let width = max(1, availableSize.width - 32)
        return isLandscape ? min(width * 0.62, cameraHeight * 4 / 3) : width
    }

    private var camera: some View {
        let token = scanID
        return DebugCardCamera(shutterRequest: shutterRequest, onCapture: { image, text in
            guard scanID == token, scenePhase == .active else { return }
            captured(image, text: text)
        }, onStatus: { message in
            guard scanID == token, photo == nil else { return }
            status = message
        }).id(token)
    }

    private var scanLine: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let progress = reduceMotion ? 0.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                Rectangle().fill(Color.mint)
                    .frame(height: 2)
                    .shadow(color: .mint, radius: 8)
                    .offset(y: progress * (geometry.size.height - 2))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func debugText(_ title: String, text: String) -> some View {
        DisclosureGroup(title) {
            Text(text).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func captured(_ image: UIImage, text: String) {
        guard photo == nil else { return }
        photo = image; ocr = text; processing = true
        print("[CardScanner] OCR:\n\(text)")
        status = "Extracting identity with Gemini…"
        request = Task {
            do {
                let service = DebugCardRecognition()
                let (identity, raw) = try await service.extract(text: text, onStatus: { status = $0 })
                try Task.checkCancellation()
                json = raw
                status = "Searching the public CloudKit catalog…"
                let matches = try await service.findCards(identity: identity)
                try Task.checkCancellation()
                candidates = matches
                if matches.count == 1 {
                    status = "Matched \(matches[0].summary.name)."
                    selected = matches[0]
                } else if matches.isEmpty {
                    status = "No matching card in the public catalog. Check OCR and structured output below."
                } else { status = "Found \(matches.count) possible matches." }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
                print("[CardScanner] Failed: \(error.localizedDescription)")
            }
            processing = false
        }
    }

    private func reset() {
        request?.cancel(); request = nil
        photo = nil; ocr = ""; json = ""; candidates = []; selected = nil; processing = false
        status = "Starting camera…"; scanID = UUID()
    }
}
#endif
