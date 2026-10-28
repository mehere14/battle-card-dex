import Combine
import Foundation
import UIKit

nonisolated enum CardScannerPhase: Equatable, Sendable {
    case starting, ready, processing
    case choosing([BattleCardDetail])
    case found(BattleCardDetail)
    case saving(BattleCardDetail)
    case added(BattleCardDetail)
    case saveFailed(BattleCardDetail, String)
    case failed(String)
    case permissionDenied
}

@MainActor
final class CardScannerModel: ObservableObject {
    @Published private(set) var phase: CardScannerPhase = .starting
    @Published private(set) var errorDetails: String?
    private var recognitionDiagnostics = ScanRecognitionDiagnostics(ocrText: "Unavailable: no photo text extracted.")
    func errorReport(message: String) -> String {
        recognitionDiagnostics.report(error: errorDetails ?? message)
    }
    @Published private(set) var photo: UIImage?
    @Published private(set) var cameraID = UUID()
    @Published private(set) var shutterRequest = UUID()
    @Published private(set) var autoAdd: Bool
    private let library: LibraryRepository
    private let recognizer: any CardRecognizing
    private let defaults: UserDefaults
    private var scanID = UUID()
    private var generation = UUID()
    private var request: Task<Void, Never>?
    private var didSave = false

    init(library: LibraryRepository, recognizer: (any CardRecognizing)? = nil, defaults: UserDefaults = .standard) {
        self.library = library; self.recognizer = recognizer ?? CardRecognitionService(); self.defaults = defaults
        autoAdd = defaults.bool(forKey: "library.scanner.autoAdd")
    }
    func capture() { guard phase == .ready else { return }; phase = .processing; shutterRequest = UUID() }
    func cameraEvent(_ event: CardCameraEvent) {
        switch event {
        case .ready: if phase == .starting { phase = .ready }
        case .captureStarted: if phase == .ready || phase == .starting { phase = .processing }
        case .permissionDenied: phase = .permissionDenied
        case .failed(let message): if phase == .starting || phase == .ready || phase == .processing { phase = .failed(message) }
        }
    }
    func captured(_ image: UIImage, text: String) {
        guard !didSave, photo == nil, phase == .processing || phase == .ready else { return }
        recognitionDiagnostics = ScanRecognitionDiagnostics(ocrText: text)
        photo = image; phase = .processing
        let token = generation
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await recognizer.recognize(text: text, onDiagnostics: { diagnostics in
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.recognitionDiagnostics = diagnostics
                })
                try Task.checkCancellation()
                guard token == generation else { return }
                if matches.isEmpty { phase = .failed("No matching card found. Keep the card flat and make sure its text is clear.") }
                else if matches.count == 1 { choose(matches[0]) }
                else { phase = .choosing(matches) }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, token == generation else { return }
                errorDetails = Self.describeError(error)
                phase = .failed("Couldn’t finish this scan. See the error details below, then try again.")
            }
        }
    }
    func choose(_ card: BattleCardDetail) {
        switch phase {
        case .processing: break
        case .choosing(let candidates): guard candidates.contains(where: { $0.id == card.id }) else { return }
        default: return
        }
        phase = .found(card)
        if autoAdd { add() }
    }
    func setAutoAdd(_ enabled: Bool) {
        autoAdd = enabled; defaults.set(enabled, forKey: "library.scanner.autoAdd")
        if enabled, case .found = phase { add() }
    }
    func add() {
        guard !didSave else { return }
        let card: BattleCardDetail
        switch phase {
        case .found(let match), .saveFailed(let match, _): card = match
        default: return
        }
        phase = .saving(card)
        do {
            try library.addScannedCard(scanID: scanID, card: card)
            didSave = true; phase = .added(card)
        } catch { phase = .saveFailed(card, error.localizedDescription) }
    }
    func reset() {
        recognitionDiagnostics = ScanRecognitionDiagnostics(ocrText: "Unavailable: no photo text extracted.")
        cancel(); errorDetails = nil; photo = nil; didSave = false; scanID = UUID(); cameraID = UUID(); shutterRequest = UUID(); phase = .starting
    }
    nonisolated static func describeError(_ error: Error) -> String {
        var messages: [String] = []
        var current: NSError? = error as NSError
        // Limit traversal in case an SDK supplies a cyclic underlying error chain.
        for _ in 0..<5 {
            guard let value = current else { break }
            var message = "\(value.localizedDescription)\nDomain: \(value.domain) · Code: \(value.code)"
            if let reason = value.localizedFailureReason { message += "\n\(reason)" }
            if let suggestion = value.localizedRecoverySuggestion { message += "\n\(suggestion)" }
            messages.append(message)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return messages.joined(separator: "\n\nCaused by:\n")
    }

    func waitForRecognition() async { await request?.value }
    func cancel() { generation = UUID(); request?.cancel(); request = nil }
    func backgrounded() {
        cancel()
        if phase == .processing { phase = .failed("Scan interrupted. Tap Try Again to scan your card.") }
    }
    func resumed() { if phase == .starting || phase == .ready || phase == .permissionDenied { reset() } }
}
