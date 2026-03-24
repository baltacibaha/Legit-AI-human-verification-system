import SwiftUI
import Combine

enum LegitRoute: Hashable { case passport(LegitPassportNavPayload) }

struct LegitPassportNavPayload: Hashable, Sendable {
    let image: UIImage
    let proof: SignedProof
    let response: LegitSubmitResponse
    func hash(into hasher: inout Hasher) { hasher.combine(response.contentHash) }
    static func == (l: Self, r: Self) -> Bool { l.response.contentHash == r.response.contentHash }
}

@MainActor
final class LegitNavigationStore: ObservableObject {
    @Published var path = NavigationPath()
    @Published private(set) var isSubmitting:    Bool           = false
    @Published private(set) var uploadProgress:  Double         = 0.0
    @Published private(set) var submissionError: LegitAPIError? = nil
    private let api: LegitAPIClient

    init(api: LegitAPIClient = .shared) { self.api = api }

    func submitAndNavigate(image: UIImage, proof: SignedProof) async {
        guard !isSubmitting else { return }
        submissionError = nil
        isSubmitting    = true
        uploadProgress  = 0.0

        let progressTask = Task { [weak self, weak api] in
            guard let api else { return }
            while !Task.isCancelled {
                await MainActor.run { self?.uploadProgress = api.lastUploadProgress }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        defer {
            progressTask.cancel()
            isSubmitting   = false
            uploadProgress = 0.0
        }

        let response: LegitSubmitResponse
        do {
            response = try await api.submitContent(proof: proof, image: image)
        } catch let err as LegitAPIError {
            submissionError = err
            return
        } catch {
            submissionError = .serverError
            return
        }

        try? await Task.sleep(nanoseconds: 180_000_000)
        let payload = LegitPassportNavPayload(image: image, proof: proof, response: response)
        withAnimation(.spring(response: 0.46, dampingFraction: 0.80, blendDuration: 0.1)) {
            path.append(LegitRoute.passport(payload))
        }
    }

    func popToRoot() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { path = NavigationPath() }
    }

    func dismissError() {
        withAnimation(.easeOut(duration: 0.22)) { submissionError = nil }
    }
}
