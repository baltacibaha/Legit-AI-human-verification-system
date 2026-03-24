import Foundation
import CoreLocation
import CoreMotion
import CryptoKit
import AVFoundation
import UIKit
import Combine

// MARK: - Data Models

struct SensorSnapshot: Codable {
    let timestamp: String
    let gps: GPSData
    let accelerometer: MotionVector
    let gyroscope: MotionVector
    let deviceID: String
}

struct GPSData: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let accuracy: Double
    let speed: Double
}

struct MotionVector: Codable {
    let x: Double
    let y: Double
    let z: Double
}

struct SignedProof: Codable, Hashable {
    let snapshot: SensorSnapshot
    let hash: String
    let signature: String
    let presenceScore: Double

    func hash(into hasher: inout Hasher) { hasher.combine(hash) }
    static func == (l: Self, r: Self) -> Bool { l.hash == r.hash }
}

// MARK: - Errors

enum LegitSensorError: LocalizedError {
    case gpsUnavailable
    case gpsAccuracyTooLow(accuracy: Double)
    case gpsPermissionDenied
    case motionUnavailable
    case signingFailed
    case snapshotCaptureFailed
    case deviceKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .gpsUnavailable:             return "GPS is not available on this device."
        case .gpsAccuracyTooLow(let a):   return "GPS accuracy too low (\(String(format: "%.1f", a))m)."
        case .gpsPermissionDenied:        return "Location permission denied."
        case .motionUnavailable:          return "Motion sensors unavailable."
        case .signingFailed:              return "Cryptographic signing failed."
        case .snapshotCaptureFailed:      return "Failed to capture sensor data."
        case .deviceKeyUnavailable:       return "Device private key unavailable."
        }
    }
}

// MARK: - LegitSensorCore Singleton

@MainActor
final class LegitSensorCore: NSObject, ObservableObject {
    static let shared = LegitSensorCore()

    @Published private(set) var lastSignedProof: SignedProof?
    @Published private(set) var isCaptureInProgress: Bool   = false
    @Published private(set) var currentAccuracy: Double     = 0.0
    @Published private(set) var locationAuthorized: Bool    = false

    private let locationManager = CLLocationManager()
    private let motionManager   = CMMotionManager()
    private var latestLocation: CLLocation?
    private var latestAccelerometerData: CMAccelerometerData?
    private var latestGyroData: CMGyroData?
    private let motionQueue = OperationQueue()
    private let keyTag      = "com.legit.device.private.key"
    private let presenceAccuracyThreshold: Double = 50.0

    private override init() {
        super.init()
        motionQueue.name = "com.legit.motionQueue"
        motionQueue.maxConcurrentOperationCount = 1
        configureLocationManager()
        configureMotionSensors()
    }

    private func configureLocationManager() {
        locationManager.delegate             = self
        locationManager.desiredAccuracy      = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter       = kCLDistanceFilterNone
        locationManager.activityType         = .other
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    private func configureMotionSensors() {
        guard motionManager.isAccelerometerAvailable && motionManager.isGyroAvailable else { return }
        motionManager.accelerometerUpdateInterval = 0.01
        motionManager.gyroUpdateInterval          = 0.01
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
            if let data { DispatchQueue.main.async { self?.latestAccelerometerData = data } }
        }
        motionManager.startGyroUpdates(to: motionQueue) { [weak self] data, _ in
            if let data { DispatchQueue.main.async { self?.latestGyroData = data } }
        }
    }

    // MARK: Capture

    func captureProofAtShutterMoment() async throws -> SignedProof {
        guard !isCaptureInProgress else { throw LegitSensorError.snapshotCaptureFailed }
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }

        guard CLLocationManager.locationServicesEnabled() else { throw LegitSensorError.gpsUnavailable }
        let authStatus = locationManager.authorizationStatus
        guard authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways else {
            throw LegitSensorError.gpsPermissionDenied
        }
        guard let location = latestLocation else { throw LegitSensorError.gpsUnavailable }
        guard motionManager.isAccelerometerAvailable, motionManager.isGyroAvailable else {
            throw LegitSensorError.motionUnavailable
        }
        guard let accelData = latestAccelerometerData, let gyroData = latestGyroData else {
            throw LegitSensorError.motionUnavailable
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        let snapshot = SensorSnapshot(
            timestamp:     formatter.string(from: Date()),
            gps:           GPSData(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                   altitude: location.altitude, accuracy: location.horizontalAccuracy, speed: max(0, location.speed)),
            accelerometer: MotionVector(x: accelData.acceleration.x, y: accelData.acceleration.y, z: accelData.acceleration.z),
            gyroscope:     MotionVector(x: gyroData.rotationRate.x,  y: gyroData.rotationRate.y,  z: gyroData.rotationRate.z),
            deviceID:      deviceID
        )

        let presenceScore = computePresenceScore(location: location)

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonData = try enc.encode(snapshot)

        let hashDigest = SHA256.hash(data: jsonData)
        let hashHex    = hashDigest.map { String(format: "%02x", $0) }.joined()

        let privateKey = try retrieveOrCreateDeviceKey()
        let signature  = try privateKey.signature(for: jsonData)

        let proof = SignedProof(
            snapshot:      snapshot,
            hash:          hashHex,
            signature:     signature.derRepresentation.base64EncodedString(),
            presenceScore: presenceScore
        )
        lastSignedProof = proof
        return proof
    }

    private func computePresenceScore(location: CLLocation) -> Double {
        let age      = abs(location.timestamp.timeIntervalSinceNow)
        let accuracy = location.horizontalAccuracy
        let freshnessPenalty: Double
        if age <= 3.0       { freshnessPenalty = 0.0 }
        else if age <= 10.0 { freshnessPenalty = (age - 3.0) / 7.0 * 0.3 }
        else                { freshnessPenalty = 0.5 }
        let accuracyScore: Double
        if accuracy < 0          { accuracyScore = 0.0 }
        else if accuracy <= 10.0 { accuracyScore = 1.0 }
        else if accuracy <= 100.0 { accuracyScore = 1.0 - ((accuracy - 10.0) / 90.0) }
        else                      { accuracyScore = 0.0 }
        return min(max(accuracyScore * (1.0 - freshnessPenalty), 0.0), 1.0) * 100.0
    }

    private func retrieveOrCreateDeviceKey() throws -> P256.Signing.PrivateKey {
        #if targetEnvironment(simulator)
        return P256.Signing.PrivateKey()
        #else
        let query: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String:          true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let keyRef = item {
            let secKey = keyRef as! SecKey
            guard let keyData = SecKeyCopyExternalRepresentation(secKey, nil) as Data? else {
                throw LegitSensorError.deviceKeyUnavailable
            }
            return try P256.Signing.PrivateKey(x963Representation: keyData)
        }
        let newKey  = P256.Signing.PrivateKey()
        let keyData = newKey.x963Representation
        let addQuery: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String:          keyData,
            kSecAttrAccessible as String:     kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw LegitSensorError.deviceKeyUnavailable
        }
        return newKey
        #endif
    }

    func exportPublicKeyBase64() throws -> String {
        let privateKey = try retrieveOrCreateDeviceKey()
        return privateKey.publicKey.x963Representation.base64EncodedString()
    }

    func serializeSignedProof(_ proof: SignedProof) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(proof)
    }
}

// MARK: - CLLocationManagerDelegate

extension LegitSensorCore: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.latestLocation  = location
            self.currentAccuracy = location.horizontalAccuracy
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.locationAuthorized = true
                manager.startUpdatingLocation()
            default:
                self.locationAuthorized = false
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LegitSensorCore] Location error: \(error.localizedDescription)")
    }
}
