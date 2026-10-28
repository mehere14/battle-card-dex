import AVFoundation
import CoreImage
import SwiftUI
import Vision

nonisolated enum CardCameraEvent: Sendable {
    case ready, captureStarted, permissionDenied
    case failed(String)
}

struct CardCamera: UIViewControllerRepresentable {
    let shutterRequest: UUID
    let onCapture: @MainActor @Sendable (UIImage, String) -> Void
    let onStatus: @MainActor @Sendable (String) -> Void
    var onEvent: @MainActor @Sendable (CardCameraEvent) -> Void = { _ in }

    func makeUIViewController(context: Context) -> CardCameraController {
        CardCameraController(shutterRequest: shutterRequest, onCapture: onCapture, onStatus: onStatus, onEvent: onEvent)
    }
    func updateUIViewController(_ controller: CardCameraController, context: Context) { controller.captureIfRequested(shutterRequest) }
    static func dismantleUIViewController(_ controller: CardCameraController, coordinator: ()) { controller.stop() }
}

@MainActor
final class CardCameraController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onCapture: @MainActor @Sendable (UIImage, String) -> Void
    private let onStatus: @MainActor @Sendable (String) -> Void
    private let onEvent: @MainActor @Sendable (CardCameraEvent) -> Void
    private var processor: CardPhotoProcessor?
    private var presentedCamera = false
    private var stopped = false
    private var takingPhoto = false
    private weak var camera: UIImagePickerController?
    private weak var shutterButton: UIButton?

    init(shutterRequest: UUID, onCapture: @escaping @MainActor @Sendable (UIImage, String) -> Void,
         onStatus: @escaping @MainActor @Sendable (String) -> Void, onEvent: @escaping @MainActor @Sendable (CardCameraEvent) -> Void) {
        self.onCapture = onCapture; self.onStatus = onStatus; self.onEvent = onEvent
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Keep the host consistent with the camera while its preview initializes.
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presentedCamera, !stopped else { return }
        presentedCamera = true
        Task { [weak self] in
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard let self, !stopped else { return }
            guard granted else { onEvent(.permissionDenied); return }
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                onEvent(.failed("A camera is unavailable on this device.")); return
            }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraDevice = .rear
            picker.cameraCaptureMode = .photo
            picker.showsCameraControls = false
            picker.allowsEditing = false
            picker.delegate = self
            camera = picker
            picker.cameraOverlayView = makeCameraControls(for: picker)
            picker.view.backgroundColor = .black
            picker.modalPresentationStyle = .fullScreen
            onEvent(.ready)
            present(picker, animated: false)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        guard !stopped, let image = info[.originalImage] as? UIImage else { return }
        onEvent(.captureStarted)
        let processor = CardPhotoProcessor(capture: onCapture, status: onStatus, event: onEvent)
        self.processor = processor
        picker.dismiss(animated: true) { processor.process(image) }
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        onEvent(.failed("Photo cancelled. Tap Try Again to open the camera."))
    }
    private func makeCameraControls(for picker: UIImagePickerController) -> UIView {
        let overlay = CardCameraControls(frame: picker.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let shutter = UIButton(type: .custom)
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 36
        shutter.layer.borderWidth = 5
        shutter.layer.borderColor = UIColor.gray.cgColor
        shutter.accessibilityLabel = "Capture card photo"
        shutter.accessibilityIdentifier = "card-scanner-shutter"
        shutter.addAction(UIAction { [weak self] _ in self?.takePhoto() }, for: .touchUpInside)
        shutterButton = shutter
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.tintColor = .white
        cancel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        cancel.layer.cornerRadius = 12
        cancel.addAction(UIAction { [weak self, weak picker] _ in
            guard let self, let picker else { return }
            imagePickerControllerDidCancel(picker)
        }, for: .touchUpInside)
        for control in [shutter, cancel] {
            control.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(control)
        }
        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shutter.widthAnchor.constraint(equalToConstant: 72),
            shutter.heightAnchor.constraint(equalToConstant: 72),
            cancel.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cancel.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancel.widthAnchor.constraint(equalToConstant: 84),
            cancel.heightAnchor.constraint(equalToConstant: 44)
        ])
        return overlay
    }
    private func takePhoto() {
        guard !stopped, !takingPhoto, let camera else { return }
        takingPhoto = true
        shutterButton?.isEnabled = false
        onEvent(.captureStarted)
        camera.takePicture()
    }
    func captureIfRequested(_ request: UUID) {}
    func stop() {
        stopped = true
        processor?.stop()
        if let picker = presentedViewController { picker.dismiss(animated: false) }
    }
}

// Leave preview gestures available outside the shutter and cancel buttons.
@MainActor
private final class CardCameraControls: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}

// Only OCR runs on this queue; capture is handled by the system camera.
nonisolated final class CardPhotoProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "card-scanner.ocr", qos: .userInitiated)
    private let context = CIContext()
    private let capture: @MainActor @Sendable (UIImage, String) -> Void
    private let status: @MainActor @Sendable (String) -> Void
    private let event: @MainActor @Sendable (CardCameraEvent) -> Void
    private var stopped = false
    private var capturedGuide = CGRect.zero
    private var capturedViewport = CGSize.zero
    private var photoData: [Data] = []
    private var photoError: String?

    init(capture: @escaping @MainActor @Sendable (UIImage, String) -> Void,
         status: @escaping @MainActor @Sendable (String) -> Void,
         event: @escaping @MainActor @Sendable (CardCameraEvent) -> Void) {
        self.capture = capture; self.status = status; self.event = event
    }
    func stop() { queue.async { self.stopped = true } }
    private func report(_ message: String) { Task { @MainActor in self.status(message) } }
    func process(_ image: UIImage) {
        queue.async {
            guard !self.stopped else { return }
            // Normalize orientation without reducing the system camera photo's resolution.
            guard let source = CIImage(image: image),
                  let cgImage = self.context.createCGImage(source, from: source.extent),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 1) else {
                Task { @MainActor in self.event(.failed("Couldn’t read the photo. Please try again.")) }
                return
            }
            self.capturedViewport = CGSize(width: cgImage.width, height: cgImage.height)
            self.capturedGuide = CGRect(origin: .zero, size: self.capturedViewport)
            self.photoData = [data]
            self.processPhotos()
        }
    }
    private func rectangleRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.58; request.maximumAspectRatio = 0.85
        request.minimumSize = 0.25; request.minimumConfidence = 0.8
        request.maximumObservations = 1; request.quadratureTolerance = 20
        return request
    }

    private func normalizedGuide(imageSize: CGSize, rect: CGRect, viewport: CGSize) -> CGRect {
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let origin = CGPoint(x: (viewport.width - imageSize.width * scale) / 2,
                             y: (viewport.height - imageSize.height * scale) / 2)
        return CGRect(x: (rect.minX - origin.x) / (imageSize.width * scale),
                      y: 1 - (rect.maxY - origin.y) / (imageSize.height * scale),
                      width: rect.width / (imageSize.width * scale),
                      height: rect.height / (imageSize.height * scale)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private struct OCRReading {
        var text = ""
        var confidence = 0.0
        var fractionConfidence = 0.0
    }

    private func readText(_ image: CGImage, smallText: Bool) throws -> OCRReading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        if smallText { request.minimumTextHeight = 0.004 }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        guard !lines.isEmpty else { return OCRReading() }
        let fractionConfidence = lines.filter {
            $0.string.range(of: #"[A-Za-z]*\d+\s*/\s*[A-Za-z]*\d+"#, options: .regularExpression) != nil
        }.map { Double($0.confidence) }.max() ?? 0
        return OCRReading(text: lines.map(\.string).joined(separator: "\n"),
                          confidence: lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(lines.count),
                          fractionConfidence: fractionConfidence)
    }

    private func readFooter(_ image: CIImage) -> OCRReading {
        // A failed footer variant must not discard a readable whole-card result.
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return OCRReading() }
        do { return try readText(cgImage, smallText: true) }
        catch {
            scannerLog("[CardScanner] Footer OCR variant failed: \(error.localizedDescription)")
            return OCRReading()
        }
    }

    private func processPhotos() {
        let ocrStarted = Date()
        defer { scannerLog("[CardScanner] Local OCR processing: \(Date().timeIntervalSince(ocrStarted))s.") }
        report("Reading text from captured photo…")
        var best: (image: CGImage, text: String, score: Double)?
        for data in photoData {
            guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { continue }
            do {
                let guide = normalizedGuide(imageSize: source.extent.size, rect: capturedGuide, viewport: capturedViewport)
                let detect = rectangleRequest()
                try VNImageRequestHandler(ciImage: source).perform([detect])
                let image: CIImage
                if let rectangle = detect.results?.first,
                   guide.contains(CGPoint(x: rectangle.boundingBox.midX, y: rectangle.boundingBox.midY)) {
                    func vector(_ point: CGPoint) -> CIVector {
                        CIVector(x: source.extent.minX + point.x * source.extent.width,
                                 y: source.extent.minY + point.y * source.extent.height)
                    }
                    image = source.applyingFilter("CIPerspectiveCorrection", parameters: [
                        "inputTopLeft": vector(rectangle.topLeft), "inputTopRight": vector(rectangle.topRight),
                        "inputBottomLeft": vector(rectangle.bottomLeft), "inputBottomRight": vector(rectangle.bottomRight)
                    ])
                } else {
                    // The manual shutter never depends on rectangle detection.
                    image = source.cropped(to: CGRect(x: source.extent.minX + guide.minX * source.extent.width,
                        y: source.extent.minY + guide.minY * source.extent.height,
                        width: guide.width * source.extent.width, height: guide.height * source.extent.height))
                }
                guard let cgImage = context.createCGImage(image, from: image.extent) else { continue }
                let whole = try readText(cgImage, smallText: false)
                // Core Image's origin is bottom-left: minY is the printed footer.
                let footerRect = CGRect(x: image.extent.minX, y: image.extent.minY,
                                        width: image.extent.width, height: image.extent.height * 0.22)
                let cropped = image.cropped(to: footerRect)
                let scale = max(1, min(3, 2400 / cropped.extent.width))
                let footer = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let contrast = footer.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0, kCIInputContrastKey: 1.5, kCIInputBrightnessKey: 0
                ])
                let originalFooter = readFooter(footer)
                let contrastFooter = readFooter(contrast)
                guard !whole.text.isEmpty || !originalFooter.text.isEmpty || !contrastFooter.text.isEmpty else { continue }
                let text = """
                [WHOLE_CARD_OCR]
                \(whole.text.isEmpty ? "(unreadable)" : whole.text)
                [FOOTER_ORIGINAL_OCR]
                \(originalFooter.text.isEmpty ? "(unreadable)" : originalFooter.text)
                [FOOTER_HIGH_CONTRAST_OCR]
                \(contrastFooter.text.isEmpty ? "(unreadable)" : contrastFooter.text)
                """
                let footerScore = max(originalFooter.fractionConfidence, contrastFooter.fractionConfidence)
                let score = whole.confidence + footerScore * 2
                scannerLog("[CardScanner] Exposure OCR score: \(score), photo: \(cgImage.width)x\(cgImage.height), footer confidence: \(originalFooter.confidence)/\(contrastFooter.confidence)")
                if best == nil || score > best!.score { best = (cgImage, text, score) }
            } catch { photoError = CardScannerModel.describeError(error) }
        }
        photoData = []
        guard !stopped else { return }
        guard let best else {
            let message = "The card text couldn’t be read. Reduce glare and try again."
                + (photoError.map { "\n\nError details:\n" + $0 } ?? "")
            Task { @MainActor in self.event(.failed(message)) }
            report(photoError ?? "Text unreadable. Reduce glare, position the card in the guide, and try the shutter again.")
            return
        }
        let image = UIImage(cgImage: best.image)
        let text = best.text
        Task { @MainActor in self.capture(image, text) }
    }
}

#if DEBUG
typealias DebugCardCamera = CardCamera
#endif
