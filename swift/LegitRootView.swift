import SwiftUI
import AVFoundation
import Combine

// MARK: - Root View
struct LegitRootView: View {
    @StateObject private var navStore = LegitNavigationStore()
    @State private var showErrorSheet = false

    var body: some View {
        NavigationStack(path: $navStore.path) {
            LegitCameraRootView()
                .navigationDestination(for: LegitRoute.self) { route in
                    switch route {
                    case .passport(let payload):
                        LegitServerPassportView(payload: payload).navigationBarBackButtonHidden(true)
                    }
                }
        }
        .environmentObject(navStore)
        .overlay(alignment: .center) {
            LegitUploadProgressHUD(progress: navStore.uploadProgress, isVisible: navStore.isSubmitting)
        }
        .sheet(isPresented: $showErrorSheet, onDismiss: { navStore.dismissError() }) {
            if let err = navStore.submissionError {
                LegitErrorSheet(
                    error: err,
                    onRetry:   { showErrorSheet = false; navStore.dismissError() },
                    onDismiss: { showErrorSheet = false; navStore.dismissError() }
                )
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(.regularMaterial)
            }
        }
        .onChange(of: navStore.submissionError) { _, err in
            showErrorSheet = (err != nil)
        }
    }
}

// MARK: - Camera Root
struct LegitCameraRootView: View {
    @EnvironmentObject private var navStore: LegitNavigationStore
    @StateObject private var session = LegitCameraSessionManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewContainer(session: session.session) { session.focusAndExpose(at: $0) }.ignoresSafeArea()
            if let fp = session.focusPoint {
                FocusRingView(point: fp).id(fp.x + fp.y).ignoresSafeArea()
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                ZoomIndicatorView(zoomFactor: session.zoomFactor).padding(.bottom, 12)
                bottomControls
            }
            .padding(.top, 12).padding(.bottom, 36)
        }
        .task { await session.checkPermissionsAndStart() }
        .onDisappear { session.stopSession() }
        .onReceive(NotificationCenter.default.publisher(for: .legitPinchZoom)) { n in
            if let d = n.userInfo?["delta"] as? CGFloat {
                session.setZoom(factor: session.zoomFactor * d)
            }
        }
        .alert(item: $session.cameraError) { err in
            Alert(
                title: Text("Camera Error"),
                message: Text(err.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var topBar: some View {
        HStack {
            Spacer().frame(width: 40)
            Spacer()
            GPSHUDView(label: session.gpsAccuracyLabel, isReady: session.isGPSReady)
            Spacer()
            Button { session.cycleFlashMode() } label: {
                Image(systemName: flashIconName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.40)))
            }
        }.padding(.horizontal, 20)
    }

    private var flashIconName: String {
        switch session.flashMode {
        case .auto:    return "bolt.badge.automatic.fill"
        case .on:      return "bolt.fill"
        case .off:     return "bolt.slash.fill"
        @unknown default: return "bolt.fill"
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center) {
                thumbnailButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)

                LegitShutterButton(
                    isCaptureInProgress: session.isCaptureInProgress || navStore.isSubmitting
                ) {
                    Task {
                        await session.captureWithSensorFusion()
                        guard let result = session.captureResult else { return }
                        await navStore.submitAndNavigate(image: result.image, proof: result.signedProof)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Button { session.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.black.opacity(0.40)))
                }
                .disabled(session.isCaptureInProgress || navStore.isSubmitting)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 28)
            }

            Text("LEGIT · Proof of Presence")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(1.5)
        }
    }

    @ViewBuilder
    private var thumbnailButton: some View {
        if let result = session.captureResult {
            Image(uiImage: result.image)
                .resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.55), lineWidth: 1.5))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.10))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "photo.on.rectangle").font(.system(size: 18)).foregroundStyle(.white.opacity(0.28)))
        }
    }
}

// MARK: - Upload Progress HUD
struct LegitUploadProgressHUD: View {
    let progress: Double
    let isVisible: Bool
    @State private var pulse: CGFloat = 1.0

    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.52).ignoresSafeArea().transition(.opacity)
                VStack(spacing: 22) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.10), lineWidth: 3).frame(width: 66, height: 66)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(red:0.40,green:0.35,blue:0.92), Color(red:0.15,green:0.65,blue:0.95)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 66, height: 66)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.28), value: progress)
                        Text("L")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .scaleEffect(pulse)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    }

                    VStack(spacing: 5) {
                        Text(hudLabel)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.interpolate)
                            .animation(.easeInOut(duration: 0.22), value: hudLabel)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.50))
                            .monospacedDigit()
                    }

                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.10)).frame(height: 3)
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(red:0.40,green:0.35,blue:0.92), Color(red:0.15,green:0.65,blue:0.95)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: g.size.width * progress, height: 3)
                                .animation(.easeInOut(duration: 0.28), value: progress)
                        }
                    }
                    .frame(height: 3)
                    .frame(maxWidth: 170)
                }
                .padding(.horizontal, 36).padding(.vertical, 30)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
                )
                .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 8)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.86).combined(with: .opacity),
                    removal:   .scale(scale: 1.06).combined(with: .opacity)
                ))
                .onAppear { pulse = 1.08 }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.76), value: isVisible)
        }
    }

    private var hudLabel: String {
        switch progress {
        case 0.00..<0.12: return "Preparing…"
        case 0.12..<0.22: return "Encoding…"
        case 0.22..<0.55: return "Uploading…"
        case 0.55..<0.88: return "Verifying…"
        case 0.88..<1.00: return "Finalizing…"
        default:           return "Done ✓"
        }
    }
}

// MARK: - Error Sheet
struct LegitErrorSheet: View {
    let error: LegitAPIError
    let onRetry:   () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 36, height: 4)
                .padding(.top, 12).padding(.bottom, 24)

            ZStack {
                Circle().fill(iconColor.opacity(0.12)).frame(width: 62, height: 62)
                Image(systemName: iconName).font(.system(size: 26, weight: .medium)).foregroundStyle(iconColor)
            }.padding(.bottom, 16)

            Text(errorTitle)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary).multilineTextAlignment(.center).padding(.horizontal, 28)

            Text(error.localizedDescription ?? "An unexpected error occurred.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 28).padding(.top, 8).lineLimit(4)

            Spacer().frame(height: 28)

            VStack(spacing: 10) {
                if error.isRetryable {
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color(red:0.40,green:0.35,blue:0.92), Color(red:0.28,green:0.24,blue:0.78)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                            )
                    }.padding(.horizontal, 24)
                }

                Button(action: onDismiss) {
                    Text(error.isRetryable ? "Cancel" : "OK")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.07)))
                }.padding(.horizontal, 24)
            }
            Spacer().frame(height: 30)
        }
    }

    private var iconName: String {
        switch error {
        case .networkUnavailable: return "wifi.slash"
        case .tokenExpired:       return "lock.rotation"
        case .replayDetected:     return "arrow.triangle.2.circlepath"
        default:                  return "exclamationmark.triangle.fill"
        }
    }
    private var iconColor: Color {
        switch error {
        case .networkUnavailable: return .orange
        case .tokenExpired:       return .red
        default:                  return Color(red:0.85, green:0.30, blue:0.30)
        }
    }
    private var errorTitle: String {
        switch error {
        case .networkUnavailable:     return "No Connection"
        case .encodingFailed:         return "Encoding Failed"
        case .httpError(let c,_,_):   return "Request Failed (\(c))"
        case .replayDetected:         return "Duplicate Request"
        case .tokenExpired:           return "Session Expired"
        default:                      return "Error"
        }
    }
}

// MARK: - Server Passport View
struct LegitServerPassportView: View {
    let payload: LegitPassportNavPayload
    @EnvironmentObject private var navStore: LegitNavigationStore
    @State private var appeared    = false
    @State private var slideOffset: CGFloat = 56

    private var scoreResult: LegitScoreResult {
        LegitAPIClient.shared.toScoreResult(payload.response.score)
    }
    private var timestampDisplay: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: payload.proof.snapshot.timestamp) {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium
            return df.string(from: d)
        }
        return payload.proof.snapshot.timestamp
    }
    private var locationDisplay: String {
        let g = payload.proof.snapshot.gps
        guard g.accuracy > 0 else { return "Location unavailable" }
        return String(format: "%.5f, %.5f · ±%dm", g.latitude, g.longitude, Int(g.accuracy))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Image(uiImage: payload.image)
                .resizable().scaledToFill().ignoresSafeArea()
                .overlay(.black.opacity(0.55)).blur(radius: 30, opaque: true)

            VStack(spacing: 0) {
                navBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        photoCard
                            .offset(y: appeared ? 0 : slideOffset).opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.04), value: appeared)
                        easBanner
                            .offset(y: appeared ? 0 : slideOffset).opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.10), value: appeared)
                        LegitPassportView(
                            scoreResult:   scoreResult,
                            proofHash:     payload.response.contentHash,
                            timestamp:     timestampDisplay,
                            locationLabel: locationDisplay,
                            isVerified:    true
                        )
                        .offset(y: appeared ? 0 : slideOffset).opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.16), value: appeared)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16).padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation { appeared = true } }
    }

    private var navBar: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.40, dampingFraction: 0.84)) { navStore.popToRoot() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "camera.fill").font(.system(size: 12, weight: .medium))
                    Text("Retake").font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(0.12)))
            }
            Spacer()
            Text("LEGIT Passport").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Spacer()
            Button { share() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12)))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var photoCard: some View {
        ZStack(alignment: .bottomLeading) {
            Image(uiImage: payload.image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5))
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green)
                Text("\(Int(scoreResult.composite.rounded())) LEGIT").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.62)))
            .padding(12)
        }
    }

    @ViewBuilder
    private var easBanner: some View {
        let isDone = payload.response.anchoring == "done"
        HStack(spacing: 10) {
            Image(systemName: isDone ? "link.circle.fill" : "hourglass.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(isDone ? Color(red:0.40,green:0.35,blue:0.92) : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(isDone ? "On-chain · Anchored" : "Blockchain Anchoring…")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                if let eas = payload.response.easUID {
                    Text(eas.prefix(20) + "…")
                        .font(.system(size: 11, weight: .regular, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("EAS UID pending — check back shortly")
                        .font(.system(size: 11, weight: .regular, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("#\(payload.response.recordID)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 0.5))
        )
    }

    private func share() {
        let text = "LEGIT Passport · Score \(Int(scoreResult.composite.rounded()))/100\nHash: \(payload.response.contentHash)\nVerify: https://legit.app/verify/\(payload.response.contentHash)"
        let vc = UIActivityViewController(activityItems: [payload.image, text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(vc, animated: true)
        }
    }
}

// MARK: - App Entry Point
@main
struct LegitApp: App {
    var body: some Scene {
        WindowGroup {
            LegitRootView()
        }
    }
}
