import Foundation
import CryptoKit
import UIKit
import ImageIO
import AVFoundation
import Combine

// MARK: - API Configuration

struct LegitAPIConfiguration: Sendable {
    let baseURL: URL
    let jwtToken: String

    static func load() -> LegitAPIConfiguration {
        guard
            let path   = Bundle.main.path(forResource: "LegitConfig", ofType: "plist"),
            let dict   = NSDictionary(contentsOfFile: path),
            let rawURL = dict["APIBaseURL"] as? String,
            let url    = URL(string: rawURL),
            let token  = dict["JWTToken"] as? String,
            !token.isEmpty
        else {
            // Return a dummy config so app doesn't crash without plist
            return LegitAPIConfiguration(
                baseURL:  URL(string: "https://api.example.com")!,
                jwtToken: "placeholder"
            )
        }
        return LegitAPIConfiguration(baseURL: url, jwtToken: token)
    }
}

// MARK: - Wire Models

struct LegitSubmitEnvelope: Encodable {
    let payload: LegitSignedPayload
    let nonce: String
    let clientTimestamp: Int
    let appVersion: String
    enum CodingKeys: String, CodingKey {
        case payload
        case nonce
        case clientTimestamp = "client_timestamp"
        case appVersion      = "app_version"
    }
}

struct LegitSignedPayload: Encodable {
    let snapshot: LegitSnapshotWire
    let hash: String
    let signature: String
    let presenceScore: Double
}

struct LegitSnapshotWire: Encodable {
    let timestamp: String
    let gps: LegitGPSWire
    let accelerometer: LegitVectorWire
    let gyroscope: LegitVectorWire
    let deviceID: String
}

struct LegitGPSWire: Encodable {
    let latitude, longitude, altitude, accuracy, speed: Double
}

struct LegitVectorWire: Encodable {
    let x, y, z: Double
}

// MARK: - Response Models

struct LegitSubmitResponse: Decodable, Hashable, Sendable {
    let success: Bool
    let recordID: Int
    let score: LegitScoreResponse
    let contentHash: String
    let anchoring: String
    let serverTS: Int
    let easUID: String?
    enum CodingKeys: String, CodingKey {
        case success
        case recordID    = "record_id"
        case score
        case contentHash = "content_hash"
        case anchoring
        case serverTS    = "server_ts"
        case easUID      = "eas_uid"
    }
    func hash(into hasher: inout Hasher) { hasher.combine(contentHash) }
    static func == (l: Self, r: Self) -> Bool { l.contentHash == r.contentHash }
}

struct LegitScoreResponse: Decodable, Hashable, Sendable {
    let composite, identity, consistency, presence, aiInverse, history, consensus: Double
    enum CodingKeys: String, CodingKey {
        case composite, identity, consistency, presence
        case aiInverse = "ai_inverse"
        case history, consensus
    }
}

struct LegitVerifyResponse: Decodable, Sendable {
    let success: Bool
    let contentHash: String
    let score: LegitScoreResponse
    let location: LegitLocationResponse
    let blockchain: LegitBlockchainResponse
    let consensus: LegitConsensusResponse
    let contentType: String
    let capturedAt: String?
    let flagged: Bool
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case success
        case contentHash = "content_hash"
        case score, location, blockchain, consensus
        case contentType = "content_type"
        case capturedAt  = "captured_at"
        case flagged
        case createdAt   = "created_at"
    }
}

struct LegitLocationResponse: Decodable, Sendable {
    let latitude, longitude, accuracy: Double?
}

struct LegitBlockchainResponse: Decodable, Sendable {
    let ipfsCID, easUID, txHash, anchoredAt: String?
    enum CodingKeys: String, CodingKey {
        case ipfsCID    = "ipfs_cid"
        case easUID     = "eas_uid"
        case txHash     = "tx_hash"
        case anchoredAt = "anchored_at"
    }
}

struct LegitConsensusResponse: Decodable, Sendable {
    let upvotes, downvotes, verifications: Int
}

// MARK: - API Error

enum LegitAPIError: LocalizedError, Identifiable, Sendable, Equatable {
    case networkUnavailable
    case invalidURL
    case encodingFailed
    case httpError(statusCode: Int, apiCode: String, message: String)
    case decodingFailed(String)
    case replayDetected
    case tokenExpired
    case serverError
    case nonceGenerationFailed
    case gpsPermissionDenied

    var id: String {
        switch self {
        case .networkUnavailable:       return "networkUnavailable"
        case .invalidURL:               return "invalidURL"
        case .encodingFailed:           return "encodingFailed"
        case .httpError(let c, _, _):   return "httpError_\(c)"
        case .decodingFailed(let d):    return "decodingFailed_\(d.prefix(20))"
        case .replayDetected:           return "replayDetected"
        case .tokenExpired:             return "tokenExpired"
        case .serverError:              return "serverError"
        case .nonceGenerationFailed:    return "nonceGenerationFailed"
        case .gpsPermissionDenied:      return "gpsPermissionDenied"
        }
    }

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:             return "No network connection."
        case .invalidURL:                     return "API URL is misconfigured."
        case .encodingFailed:                 return "Failed to encode the request payload."
        case .httpError(_, _, let msg):       return msg
        case .decodingFailed(let d):          return "Parse error: \(d)"
        case .replayDetected:                 return "Duplicate request — please try again."
        case .tokenExpired:                   return "Session expired. Please sign in again."
        case .serverError:                    return "Server error. Please try again shortly."
        case .nonceGenerationFailed:          return "Could not generate a secure nonce."
        case .gpsPermissionDenied:            return "Location permission is required."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .tokenExpired, .gpsPermissionDenied, .invalidURL: return false
        default: return true
        }
    }

    static func == (lhs: LegitAPIError, rhs: LegitAPIError) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Private Error Envelope

private struct APIErrorEnvelope: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let success: Bool
    let error: Body
}

// MARK: - Nonce Generator

private enum NonceGenerator {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LegitAPIError.nonceGenerationFailed
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - UIImage HEIC Encoder

private extension UIImage {
    func heicData(quality: CGFloat = 0.88) -> Data? {
        guard let cgImage else { return nil }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buf, AVFileType.heic as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (buf as Data) : nil
    }

    func bestData(quality: CGFloat = 0.88) throws -> (data: Data, mime: String) {
        if let heic = heicData(quality: quality) { return (heic, "image/heic") }
        guard let jpeg = jpegData(compressionQuality: quality) else { throw LegitAPIError.encodingFailed }
        return (jpeg, "image/jpeg")
    }
}

// MARK: - LegitAPIClient

@MainActor
final class LegitAPIClient: ObservableObject {
    static let shared: LegitAPIClient = LegitAPIClient(config: .load())

    @Published private(set) var lastUploadProgress: Double = 0.0
    @Published private(set) var isUploading: Bool = false

    private let config: LegitAPIConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    init(config: LegitAPIConfiguration) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: cfg)
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .useDefaultKeys
        self.encoder.outputFormatting    = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: Submit

    func submitContent(proof: SignedProof, image: UIImage) async throws -> LegitSubmitResponse {
        guard !isUploading else { throw LegitAPIError.serverError }
        isUploading        = true
        lastUploadProgress = 0.0
        defer { isUploading = false; lastUploadProgress = 0.0 }

        lastUploadProgress = 0.05
        let (imageData, mimeType) = try await Task.detached(priority: .userInitiated) {
            try image.bestData(quality: 0.88)
        }.value
        lastUploadProgress = 0.12

        let nonce    = try NonceGenerator.generate()
        let clientTS = Int(Date().timeIntervalSince1970)

        let envelope = LegitSubmitEnvelope(
            payload: LegitSignedPayload(
                snapshot: LegitSnapshotWire(
                    timestamp:     proof.snapshot.timestamp,
                    gps:           LegitGPSWire(latitude: proof.snapshot.gps.latitude, longitude: proof.snapshot.gps.longitude, altitude: proof.snapshot.gps.altitude, accuracy: proof.snapshot.gps.accuracy, speed: proof.snapshot.gps.speed),
                    accelerometer: LegitVectorWire(x: proof.snapshot.accelerometer.x, y: proof.snapshot.accelerometer.y, z: proof.snapshot.accelerometer.z),
                    gyroscope:     LegitVectorWire(x: proof.snapshot.gyroscope.x, y: proof.snapshot.gyroscope.y, z: proof.snapshot.gyroscope.z),
                    deviceID:      proof.snapshot.deviceID
                ),
                hash:          proof.hash,
                signature:     proof.signature,
                presenceScore: proof.presenceScore
            ),
            nonce:           nonce,
            clientTimestamp: clientTS,
            appVersion:      appVersion
        )

        let envelopeData: Data
        do { envelopeData = try encoder.encode(envelope) }
        catch { throw LegitAPIError.encodingFailed }
        lastUploadProgress = 0.18

        let boundary = "LegitBoundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body     = buildMultipart(boundary: boundary, envelopeData: envelopeData, imageData: imageData, mimeType: mimeType)
        lastUploadProgress = 0.22

        guard let url = URL(string: "/api/v1/content/submit", relativeTo: config.baseURL) else {
            throw LegitAPIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.jwtToken)",                  forHTTPHeaderField: "Authorization")
        req.setValue(nonce,             forHTTPHeaderField: "X-LEGIT-Nonce")
        req.setValue(String(clientTS),  forHTTPHeaderField: "X-LEGIT-Timestamp")
        req.httpBody = body
        lastUploadProgress = 0.28

        let progressTask = Task { [weak self] in
            var sim = 0.28
            while !Task.isCancelled && sim < 0.88 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                sim = min(sim + Double.random(in: 0.02...0.06), 0.88)
                await MainActor.run { self?.lastUploadProgress = sim }
            }
        }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await executeWithRetry(req, maxAttempts: 2) }
        catch { progressTask.cancel(); throw mapNetworkError(error) }
        progressTask.cancel()

        guard let http = response as? HTTPURLResponse else { throw LegitAPIError.serverError }
        lastUploadProgress = 0.94
        let result: LegitSubmitResponse = try decode(data: data, status: http.statusCode)
        lastUploadProgress = 1.0
        return result
    }

    // MARK: Verify

    func verifyContent(hash: String) async throws -> LegitVerifyResponse {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent("/api/v1/content/verify"), resolvingAgainstBaseURL: true)
        comps?.queryItems = [URLQueryItem(name: "hash", value: hash)]
        guard let url = comps?.url else { throw LegitAPIError.invalidURL }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        let (data, response) = try await executeWithRetry(req, maxAttempts: 2)
        guard let http = response as? HTTPURLResponse else { throw LegitAPIError.serverError }
        return try decode(data: data, status: http.statusCode)
    }

    // MARK: Score Conversion

    func toScoreResult(_ sr: LegitScoreResponse) -> LegitScoreResult {
        LegitScoreResult.compute(
            identityScore:    sr.identity,
            consistencyScore: sr.consistency,
            presenceScore:    sr.presence,
            aiDetectionRaw:   max(0, 1.0 - sr.aiInverse),
            historyScore:     sr.history,
            consensusScore:   sr.consensus
        )
    }

    func submitAndScore(proof: SignedProof, image: UIImage) async throws -> (response: LegitSubmitResponse, scoreResult: LegitScoreResult) {
        let response = try await submitContent(proof: proof, image: image)
        return (response, toScoreResult(response.score))
    }

    func verifyAndScore(hash: String) async throws -> (response: LegitVerifyResponse, scoreResult: LegitScoreResult) {
        let response = try await verifyContent(hash: hash)
        return (response, toScoreResult(response.score))
    }

    // MARK: Private

    private func executeWithRetry(_ req: URLRequest, maxAttempts: Int, attempt: Int = 0) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch let err as URLError {
            if attempt < maxAttempts - 1, err.code == .timedOut || err.code == .networkConnectionLost {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return try await executeWithRetry(req, maxAttempts: maxAttempts, attempt: attempt + 1)
            }
            throw err
        }
    }

    private func mapNetworkError(_ error: Error) -> LegitAPIError {
        if let urlErr = error as? URLError,
           urlErr.code == .notConnectedToInternet || urlErr.code == .networkConnectionLost {
            return .networkUnavailable
        }
        return error as? LegitAPIError ?? .serverError
    }

    private func decode<T: Decodable>(data: Data, status: Int) throws -> T {
        switch status {
        case 200, 201:
            do { return try decoder.decode(T.self, from: data) }
            catch let e { throw LegitAPIError.decodingFailed(e.localizedDescription) }
        case 401:  throw LegitAPIError.tokenExpired
        case 409:  throw LegitAPIError.replayDetected
        case 422, 400:
            let env = try? decoder.decode(APIErrorEnvelope.self, from: data)
            throw LegitAPIError.httpError(statusCode: status, apiCode: env?.error.code ?? "VALIDATION_ERROR", message: env?.error.message ?? "Validation failed.")
        default:   throw LegitAPIError.serverError
        }
    }

    private func buildMultipart(boundary: String, envelopeData: Data, imageData: Data, mimeType: String) -> Data {
        var body = Data()
        let crlf = "\r\n"
        let ext  = mimeType == "image/heic" ? "heic" : "jpg"
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\(crlf)Content-Disposition: form-data; name=\"data\"\(crlf)Content-Type: application/json; charset=utf-8\(crlf)\(crlf)")
        body.append(envelopeData); append(crlf)
        append("--\(boundary)\(crlf)Content-Disposition: form-data; name=\"media\"; filename=\"legit_photo.\(ext)\"\(crlf)Content-Type: \(mimeType)\(crlf)Content-Length: \(imageData.count)\(crlf)\(crlf)")
        body.append(imageData); append(crlf)
        append("--\(boundary)--\(crlf)")
        return body
    }
}
