import SwiftUI
import AVFoundation
import CoreLocation
import CoreMotion
import Photos
import Combine

// MARK: - Capture Result

struct LegitCaptureResult {
    let image: UIImage
    let signedProof: SignedProof
    let presenceWarning: LegitSensorError?
}

// MARK: - Camera Session Manager

@MainActor
final class LegitCameraSessionManager: NSObject, ObservableObject {

    @Published private(set) var isSessionRunning:     Bool                       = false
    @Published private(set) var isCaptureInProgress:  Bool                       = false
    @Published private(set) var flashMode:            AVCaptureDevice.FlashMode  = .auto
    @Published private(set) var activeCamera:         AVCaptureDevice.Position   = .back
    @Published private(set) var zoomFactor:           CGFloat                    = 1.0
    @Published private(set) var focusPoint:           CGPoint?                   = nil
    @Published private(set) var captureResult:        LegitCaptureResult?        = nil
    @Published var cameraError:                       CameraError?               = nil
    @Published private(set) var gpsAccuracyLabel:     String                     = "Acquiring GPS…"
    @Published private(set) var isGPSReady:           Bool                       = false

    enum CameraError: LocalizedError, Identifiable {
        var id: String { errorDescription ?? UUID().uuidString }
        case permissionDenied, deviceUnavailable, sessionInterrupted
        case captureFailed(String), sensorFusionFailed(String), photoLibraryPermissionDenied
        var errorDescription: String? {
            switch self {
            case .permissionDenied:             return "Camera access required. Enable in Settings."
            case .deviceUnavailable:            return "No suitable camera found."
            case .sessionInterrupted:           return "Camera session interrupted."
            case .captureFailed(let m):         return "Capture failed: \(m)"
            case .sensorFusionFailed(let m):    return "Sensor fusion error: \(m)"
            case .photoLibraryPermissionDenied: return "Photo library access needed."
            }
        }
    }

    let session   = AVCaptureSession()
    private var backCamera:   AVCaptureDevice?
    private var frontCamera:  AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private let photoOutput   = AVCapturePhotoOutput()
    private let sessionQueue  = DispatchQueue(label: "com.legit.camera.session", qos: .userInitiated)
    private var pendingPhotoCapture: CheckedContinuation<AVCapturePhoto, Error>?
    private let minimumZoom: CGFloat = 1.0
    private let maximumZoom: CGFloat = 5.0

    // MARK: Session Lifecycle

    func checkPermissionsAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: await configureAndStartSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { await configureAndStartSession() } else { cameraError = .permissionDenied }
        default: cameraError = .permissionDenied
        }
    }

    private func configureAndStartSession() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
                    mediaType: .video, position: .unspecified
                )
                for device in discovery.devices {
                    if device.position == .back  { self.backCamera  = device }
                    if device.position == .front { self.frontCamera = device }
                }
                guard let defaultDevice = self.backCamera ?? self.frontCamera else {
                    DispatchQueue.main.async { self.cameraError = .deviceUnavailable }
                    self.session.commitConfiguration(); cont.resume(); return
                }
                do {
                    let input = try AVCaptureDeviceInput(device: defaultDevice)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        DispatchQueue.main.async { self.currentInput = input }
                    }
                } catch {
                    DispatchQueue.main.async { self.cameraError = .captureFailed(error.localizedDescription) }
                    self.session.commitConfiguration(); cont.resume(); return
                }
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                    self.activeCamera     = defaultDevice.position
                }
                cont.resume()
            }
        }
        observeGPSReadiness()
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.isSessionRunning = false }
        }
    }

    private func observeGPSReadiness() {
        Task {
            while !Task.isCancelled {
                let accuracy   = LegitSensorCore.shared.currentAccuracy
                let authorized = LegitSensorCore.shared.locationAuthorized
                if !authorized          { gpsAccuracyLabel = "Location access denied"; isGPSReady = false }
                else if accuracy <= 0   { gpsAccuracyLabel = "Acquiring GPS…";         isGPSReady = false }
                else if accuracy <= 15  { gpsAccuracyLabel = "GPS ±\(Int(accuracy))m"; isGPSReady = true  }
                else if accuracy <= 50  { gpsAccuracyLabel = "GPS ±\(Int(accuracy))m (fair)"; isGPSReady = true  }
                else                    { gpsAccuracyLabel = "GPS ±\(Int(accuracy))m (weak)"; isGPSReady = false }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: Capture

    func captureWithSensorFusion() async {
        guard !isCaptureInProgress else { return }
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }

        async let sensorTask: SignedProof    = LegitSensorCore.shared.captureProofAtShutterMoment()
        async let photoTask:  AVCapturePhoto = capturePhotoAsync()

        var presenceWarning: LegitSensorError? = nil
        let proof: SignedProof
        let photo: AVCapturePhoto

        do { proof = try await sensorTask }
        catch let sensorErr as LegitSensorError {
            if case .gpsAccuracyTooLow = sensorErr {
                presenceWarning = sensorErr
                do { proof = try await sensorTask }
                catch { cameraError = .sensorFusionFailed(sensorErr.localizedDescription); return }
            } else { cameraError = .sensorFusionFailed(sensorErr.localizedDescription); return }
        } catch { cameraError = .sensorFusionFailed(error.localizedDescription); return }

        do { photo = try await photoTask }
        catch { cameraError = .captureFailed(error.localizedDescription); return }

        guard let photoData = photo.fileDataRepresentation(), let image = UIImage(data: photoData) else {
            cameraError = .captureFailed("Could not decode photo data."); return
        }
        await saveToPhotoLibrary(imageData: photoData)
        captureResult = LegitCaptureResult(image: image, signedProof: proof, presenceWarning: presenceWarning)
    }

    private func capturePhotoAsync() async throws -> AVCapturePhoto {
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(throwing: CameraError.deviceUnavailable); return }
                if self.pendingPhotoCapture != nil {
                    continuation.resume(throwing: CameraError.captureFailed("Capture in progress."))
                    return
                }
                self.pendingPhotoCapture = continuation
                var settings = AVCapturePhotoSettings()
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                }
                settings.flashMode = self.flashMode
                settings.isHighResolutionPhotoEnabled = true
                if self.photoOutput.isDepthDataDeliverySupported { settings.isDepthDataDeliveryEnabled = true }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: Controls

    func switchCamera() {
        guard !isCaptureInProgress else { return }
        let targetPos    = (activeCamera == .back) ? AVCaptureDevice.Position.front : .back
        let targetDevice = (targetPos == .back) ? backCamera : frontCamera
        guard let device = targetDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let ci = self.currentInput { self.session.removeInput(ci) }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    DispatchQueue.main.async { self.currentInput = newInput; self.activeCamera = targetPos; self.zoomFactor = 1.0 }
                }
            } catch { DispatchQueue.main.async { self.cameraError = .captureFailed(error.localizedDescription) } }
            self.session.commitConfiguration()
        }
    }

    func cycleFlashMode() {
        switch flashMode {
        case .auto: flashMode = .on; case .on: flashMode = .off; case .off: flashMode = .auto
        @unknown default: flashMode = .auto
        }
    }

    func setZoom(factor: CGFloat) {
        let clamped = max(minimumZoom, min(factor, maximumZoom))
        guard let device = (activeCamera == .back) ? backCamera : frontCamera else { return }
        do { try device.lockForConfiguration(); device.videoZoomFactor = clamped; device.unlockForConfiguration(); zoomFactor = clamped }
        catch {}
    }

    func focusAndExpose(at point: CGPoint) {
        guard let device = (activeCamera == .back) ? backCamera : frontCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported    { device.focusPointOfInterest = point; device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point; device.exposureMode = .autoExpose }
            device.unlockForConfiguration()
            focusPoint = point
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.focusPoint = nil }
        } catch {}
    }

    private func saveToPhotoLibrary(imageData: Data) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else { return }
        }
        try? await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: imageData, options: nil)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension LegitCameraSessionManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        Task { @MainActor in
            guard let continuation = self.pendingPhotoCapture else { return }
            self.pendingPhotoCapture = nil
            if let error = error { continuation.resume(throwing: CameraError.captureFailed(error.localizedDescription)) }
            else                 { continuation.resume(returning: photo) }
        }
    }
}

// MARK: - Preview Layer

final class LegitPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    func configure(with session: AVCaptureSession) {
        previewLayer.session       = session
        previewLayer.videoGravity  = .resizeAspectFill
        previewLayer.connection?.videoRotationAngle = 90
    }
}

struct CameraPreviewContainer: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> LegitPreviewView {
        let view  = LegitPreviewView(); view.configure(with: session)
        let tap   = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(tap); view.addGestureRecognizer(pinch)
        return view
    }
    func updateUIView(_ uiView: LegitPreviewView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: (CGPoint) -> Void
        private var lastZoom: CGFloat = 1.0
        init(onTap: @escaping (CGPoint) -> Void) { self.onTap = onTap }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let loc  = g.location(in: g.view)
            let size = g.view?.bounds.size ?? .zero
            guard size.width > 0, size.height > 0 else { return }
            onTap(CGPoint(x: loc.x / size.width, y: loc.y / size.height))
        }
        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastZoom = 1.0 }
            let delta = g.scale / lastZoom; lastZoom = g.scale
            NotificationCenter.default.post(name: .legitPinchZoom, object: nil, userInfo: ["delta": delta])
        }
    }
}

extension Notification.Name {
    static let legitPinchZoom = Notification.Name("com.legit.camera.pinchZoom")
}

// MARK: - UI Components

struct FocusRingView: View {
    let point: CGPoint
    @State private var opacity: Double = 1.0
    @State private var scale: CGFloat  = 1.4

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .scaleEffect(scale).opacity(opacity)
                    .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25))           { scale = 1.0 }
            withAnimation(.easeInOut(duration: 0.4).delay(1.2)) { opacity = 0.0 }
        }
        .allowsHitTesting(false)
    }
}

struct GPSHUDView: View {
    let label: String; let isReady: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isReady ? "location.fill" : "location.slash.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isReady ? .green : .orange)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

struct LegitShutterButton: View {
    let isCaptureInProgress: Bool
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 80, height: 80)
                Circle().stroke(.white, lineWidth: 3).frame(width: 80, height: 80)
                if isCaptureInProgress {
                    ProgressView().tint(.white).scaleEffect(1.3)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                        .scaleEffect(isPressed ? 0.88 : 1.0)
                        .animation(.easeOut(duration: 0.1), value: isPressed)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isCaptureInProgress)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true  }
                .onEnded   { _ in isPressed = false }
        )
    }
}

struct ZoomIndicatorView: View {
    let zoomFactor: CGFloat
    var body: some View {
        Text(String(format: "%.1f×", zoomFactor))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.50)))
    }
}
