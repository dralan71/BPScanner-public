// MARK: Camera/CameraView.swift

import AVFoundation
import Photos
import SwiftUI

/// SwiftUI wrapper for AVFoundation camera.
/// Provides in-app photo capture with a shutter button.
struct CameraView: UIViewControllerRepresentable {
    let shouldAutoSaveToPhotoLibrary: Bool
    let onCapture: (UIImage, Date) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        CameraViewController(
            shouldAutoSaveToPhotoLibrary: shouldAutoSaveToPhotoLibrary,
            onCapture: onCapture,
            onCancel: onCancel
        )
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

/// UIViewController that manages AVFoundation camera session and capture.
class CameraViewController: UIViewController {
    private enum Layout {
        static let previewAspectRatio: CGFloat = 3.0 / 4.0
        static let shutterSize: CGFloat = 80
        static let shutterBottomInset: CGFloat = 32
        static let cancelTopInset: CGFloat = 16
        static let horizontalInset: CGFloat = 20
        static let previewBottomSpacing: CGFloat = 28
        static let previewTopMinimum: CGFloat = 72
        static let zoomButtonSize = CGSize(width: 44, height: 44)
        static let zoomControlSpacing: CGFloat = 12
        static let defaultZoomFactor: CGFloat = 1
        static let maximumPreferredZoomFactor: CGFloat = 5
    }

    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.dralan71.BPScanner.camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewContainerView = UIView()
    private var previewBorderView = UIView()
    private weak var shutterButton: UIButton?
    private weak var zoomOutButton: UIButton?
    private weak var zoomInButton: UIButton?
    private weak var zoomLabel: UILabel?
    private var pendingCapturedImage: UIImage?
    private var pendingCaptureTime: Date?
    private var isCaptureInProgress = false
    private var videoDevice: AVCaptureDevice?
    private var currentZoomFactor: CGFloat = Layout.defaultZoomFactor
    private var minimumZoomFactor: CGFloat = Layout.defaultZoomFactor
    private var maximumZoomFactor: CGFloat = Layout.defaultZoomFactor
    private var pinchZoomBaseFactor: CGFloat = Layout.defaultZoomFactor
    private let shouldAutoSaveToPhotoLibrary: Bool
    private let onCapture: (UIImage, Date) -> Void
    private let onCancel: () -> Void

    init(
        shouldAutoSaveToPhotoLibrary: Bool,
        onCapture: @escaping (UIImage, Date) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.shouldAutoSaveToPhotoLibrary = shouldAutoSaveToPhotoLibrary
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreview()
        configureCameraSession()
        setupUI()
        updateZoomUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPreview()
    }

    deinit {
        let captureSession = captureSession
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func setupPreview() {
        previewContainerView.backgroundColor = .black
        previewContainerView.layer.cornerRadius = 24
        previewContainerView.layer.masksToBounds = true
        view.addSubview(previewContainerView)

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewContainerView.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        previewBorderView.isUserInteractionEnabled = false
        previewBorderView.layer.cornerRadius = 24
        previewBorderView.layer.borderWidth = 2
        previewBorderView.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        previewBorderView.layer.shadowColor = UIColor.black.cgColor
        previewBorderView.layer.shadowOpacity = 0.28
        previewBorderView.layer.shadowRadius = 14
        previewBorderView.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.addSubview(previewBorderView)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        previewContainerView.addGestureRecognizer(pinchGesture)
    }

    private func configureCameraSession() {
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .photo
            defer { self.captureSession.commitConfiguration() }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                DispatchQueue.main.async {
                    self.showError(message: String(localized: "Camera not available", bundle: .main))
                }
                return
            }

            self.videoDevice = device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }
                if self.captureSession.canAddOutput(self.photoOutput) {
                    self.captureSession.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .speed
                }

                let maxAvailableZoom = min(device.activeFormat.videoMaxZoomFactor, Layout.maximumPreferredZoomFactor)
                self.minimumZoomFactor = Layout.defaultZoomFactor
                self.maximumZoomFactor = max(self.minimumZoomFactor, maxAvailableZoom)

                try device.lockForConfiguration()
                device.videoZoomFactor = self.currentZoomFactor
                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.updateZoomUI()
                }
            } catch {
                DispatchQueue.main.async {
                    self.showError(message: error.localizedDescription)
                }
            }
        }
    }

    private func setupUI() {
        let shutterButton = UIButton(type: .system)
        shutterButton.setTitle(String(localized: "📷", bundle: .main), for: .normal)
        shutterButton.titleLabel?.font = UIFont.systemFont(ofSize: 40)
        shutterButton.backgroundColor = UIColor.white
        shutterButton.tintColor = UIColor.black
        shutterButton.layer.cornerRadius = 40
        shutterButton.clipsToBounds = true
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        self.shutterButton = shutterButton

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle(String(localized: "Cancel", bundle: .main), for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        cancelButton.tintColor = UIColor.white
        cancelButton.addTarget(self, action: #selector(didCancel), for: .touchUpInside)

        let zoomOutButton = UIButton(type: .system)
        zoomOutButton.setTitle("−", for: .normal)
        zoomOutButton.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        zoomOutButton.tintColor = .white
        zoomOutButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        zoomOutButton.layer.cornerRadius = 22
        zoomOutButton.addTarget(self, action: #selector(decreaseZoom), for: .touchUpInside)
        self.zoomOutButton = zoomOutButton

        let zoomInButton = UIButton(type: .system)
        zoomInButton.setTitle("+", for: .normal)
        zoomInButton.titleLabel?.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        zoomInButton.tintColor = .white
        zoomInButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        zoomInButton.layer.cornerRadius = 22
        zoomInButton.addTarget(self, action: #selector(increaseZoom), for: .touchUpInside)
        self.zoomInButton = zoomInButton

        let zoomLabel = UILabel()
        zoomLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        zoomLabel.textColor = .white
        zoomLabel.textAlignment = .center
        zoomLabel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        zoomLabel.layer.cornerRadius = 16
        zoomLabel.clipsToBounds = true
        self.zoomLabel = zoomLabel

        view.addSubview(shutterButton)
        view.addSubview(cancelButton)
        view.addSubview(zoomOutButton)
        view.addSubview(zoomInButton)
        view.addSubview(zoomLabel)

        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        zoomOutButton.translatesAutoresizingMaskIntoConstraints = false
        zoomInButton.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            shutterButton.widthAnchor.constraint(equalToConstant: Layout.shutterSize),
            shutterButton.heightAnchor.constraint(equalToConstant: Layout.shutterSize),
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Layout.shutterBottomInset),

            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Layout.cancelTopInset),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            zoomLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            zoomLabel.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -20),
            zoomLabel.widthAnchor.constraint(equalToConstant: 72),
            zoomLabel.heightAnchor.constraint(equalToConstant: 32),

            zoomOutButton.centerYAnchor.constraint(equalTo: zoomLabel.centerYAnchor),
            zoomOutButton.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -Layout.zoomControlSpacing),
            zoomOutButton.widthAnchor.constraint(equalToConstant: Layout.zoomButtonSize.width),
            zoomOutButton.heightAnchor.constraint(equalToConstant: Layout.zoomButtonSize.height),

            zoomInButton.centerYAnchor.constraint(equalTo: zoomLabel.centerYAnchor),
            zoomInButton.leadingAnchor.constraint(equalTo: zoomLabel.trailingAnchor, constant: Layout.zoomControlSpacing),
            zoomInButton.widthAnchor.constraint(equalToConstant: Layout.zoomButtonSize.width),
            zoomInButton.heightAnchor.constraint(equalToConstant: Layout.zoomButtonSize.height)
        ])
    }

    @objc private func capturePhoto() {
        guard !isCaptureInProgress else { return }

        isCaptureInProgress = true
        pendingCaptureTime = Date()
        shutterButton?.isEnabled = false
        shutterButton?.alpha = 0.55

        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        settings.photoQualityPrioritization = .speed
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func decreaseZoom() {
        setZoomFactor(currentZoomFactor / 1.25)
    }

    @objc private func increaseZoom() {
        setZoomFactor(currentZoomFactor * 1.25)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchZoomBaseFactor = currentZoomFactor
        case .changed:
            setZoomFactor(pinchZoomBaseFactor * gesture.scale)
        default:
            break
        }
    }

    @objc private func didCancel() {
        onCancel()
    }

    private func showError(message: String) {
        let alert = UIAlertController(title: String(localized: "Error", bundle: .main), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK", bundle: .main), style: .default))
        present(alert, animated: true)
    }

    private func layoutPreview() {
        let safeArea = view.safeAreaInsets
        let controlsTop = view.bounds.height - safeArea.bottom - Layout.shutterBottomInset - Layout.shutterSize - 76
        let availableTop = safeArea.top + Layout.previewTopMinimum
        let availableHeight = max(120, controlsTop - availableTop)
        let availableWidth = max(120, view.bounds.width - (Layout.horizontalInset * 2))

        let widthFromHeight = availableHeight * Layout.previewAspectRatio
        let previewWidth = min(availableWidth, widthFromHeight)
        let previewHeight = previewWidth / Layout.previewAspectRatio
        let previewFrame = CGRect(
            x: (view.bounds.width - previewWidth) / 2,
            y: max(availableTop, controlsTop - previewHeight - Layout.previewBottomSpacing),
            width: previewWidth,
            height: previewHeight
        ).integral

        previewContainerView.frame = previewFrame
        previewBorderView.frame = previewFrame
        previewLayer?.frame = previewContainerView.bounds
    }

    private func setZoomFactor(_ requestedFactor: CGFloat) {
        let clampedFactor = min(max(requestedFactor, minimumZoomFactor), maximumZoomFactor)
        guard abs(clampedFactor - currentZoomFactor) > 0.001 else { return }

        sessionQueue.async {
            guard let device = self.videoDevice else { return }

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clampedFactor
                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.currentZoomFactor = clampedFactor
                    self.updateZoomUI()
                }
            } catch {
                DispatchQueue.main.async {
                    self.showError(message: error.localizedDescription)
                }
            }
        }
    }

    private func updateZoomUI() {
        zoomLabel?.text = String(format: "%.1fx", currentZoomFactor)
        zoomOutButton?.isEnabled = currentZoomFactor > minimumZoomFactor + 0.01
        zoomOutButton?.alpha = zoomOutButton?.isEnabled == true ? 1 : 0.45
        zoomInButton?.isEnabled = currentZoomFactor < maximumZoomFactor - 0.01
        zoomInButton?.alpha = zoomInButton?.isEnabled == true ? 1 : 0.45
    }

    private func croppedCaptureImage(_ image: UIImage) -> UIImage {
        guard let previewLayer,
              let normalizedImage = image.normalizedOrientationImage(),
              let cgImage = normalizedImage.cgImage else {
            return image
        }

        let normalizedRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewLayer.bounds)
        let cropRect = CGRect(
            x: normalizedRect.minX * CGFloat(cgImage.width),
            y: normalizedRect.minY * CGFloat(cgImage.height),
            width: normalizedRect.width * CGFloat(cgImage.width),
            height: normalizedRect.height * CGFloat(cgImage.height)
        ).integral

        guard cropRect.width > 0,
              cropRect.height > 0,
              let croppedImage = cgImage.cropping(to: cropRect) else {
            return normalizedImage
        }

        return UIImage(cgImage: croppedImage, scale: normalizedImage.scale, orientation: .up)
    }
}

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            resetCaptureState()
            showError(message: String(localized: "Failed to capture photo", bundle: .main))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            resetCaptureState()
            showError(message: String(localized: "Failed to process photo", bundle: .main))
            return
        }

        pendingCapturedImage = croppedCaptureImage(image)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard error == nil else {
            resetCaptureState()
            showError(message: String(localized: "Failed to capture photo", bundle: .main))
            return
        }

        guard let image = pendingCapturedImage else {
            resetCaptureState()
            showError(message: String(localized: "Failed to process photo", bundle: .main))
            return
        }

        let captureTime = pendingCaptureTime ?? Date()
        if shouldAutoSaveToPhotoLibrary {
            Task {
                try? await PhotoLibrarySaver.save(image: image)
            }
        }
        onCapture(image, captureTime)
    }

    private func resetCaptureState() {
        pendingCapturedImage = nil
        pendingCaptureTime = nil
        isCaptureInProgress = false
        shutterButton?.isEnabled = true
        shutterButton?.alpha = 1
    }
}

private extension UIImage {
    func normalizedOrientationImage() -> UIImage? {
        guard imageOrientation != .up else {
            return self
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private enum PhotoLibrarySaver {
    static func save(image: UIImage) async throws {
        let authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw PhotoLibrarySaveError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed)
                }
            }
        }
    }
}

private enum PhotoLibrarySaveError: LocalizedError {
    case notAuthorized
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "Photo Library access was not granted.", bundle: .main)
        case .saveFailed:
            return String(localized: "Failed to save photo to your library.", bundle: .main)
        }
    }
}
