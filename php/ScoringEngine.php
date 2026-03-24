<?php
// ScoringEngine.php
declare(strict_types=1);

namespace Legit\Engine;

use PDO;
use PDOException;
use RuntimeException;
use InvalidArgumentException;

final class ScoringEngine
{
    private const WEIGHT_IDENTITY    = 0.25;
    private const WEIGHT_CONSISTENCY = 0.15;
    private const WEIGHT_PRESENCE    = 0.20;
    private const WEIGHT_AI_DETECT   = 0.20;
    private const WEIGHT_HISTORY     = 0.10;
    private const WEIGHT_CONSENSUS   = 0.10;

    private const GPS_ACCURACY_FULL_THRESHOLD  = 10.0;
    private const GPS_ACCURACY_ZERO_THRESHOLD  = 100.0;
    private const GPS_AGE_PENALTY_START        = 3.0;
    private const GPS_AGE_PENALTY_END          = 10.0;
    private const GPS_AGE_MAX_PENALTY          = 0.30;
    private const AI_DETECTION_VERSION         = 'v2.1';

    private PDO $db;

    public function __construct(PDO $db)
    {
        $this->db = $db;
        $this->db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $this->db->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
        $this->db->setAttribute(PDO::ATTR_EMULATE_PREPARES, false);
    }

    public function process(array $payload, string $userUid): array
    {
        $this->validatePayloadStructure($payload);

        $snapshot      = $payload['snapshot'];
        $clientHash    = $payload['hash'];
        $signatureB64  = $payload['signature'];
        $clientPresence = (float) $payload['presenceScore'];

        $this->verifyContentHash($snapshot, $clientHash);
        $this->verifyEcdsaSignature($snapshot, $signatureB64, $userUid);

        $identityScore    = $this->computeIdentityScore($userUid);
        $consistencyScore = $this->computeConsistencyScore($snapshot, $userUid);
        $presenceScore    = $this->computePresenceScore($snapshot, $clientPresence);
        $aiScore          = $this->computeAiDetectionScore($snapshot, $clientHash);
        $historyScore     = $this->computeHistoryScore($userUid);
        $consensusScore   = $this->computeConsensusScore($clientHash);

        $composite = $this->computeComposite(
            $identityScore, $consistencyScore, $presenceScore,
            $aiScore, $historyScore, $consensusScore
        );

        $record = [
            'user_uid'          => $userUid,
            'content_hash'      => $clientHash,
            'signature'         => $signatureB64,
            'composite_score'   => round($composite, 4),
            'identity_score'    => round($identityScore, 4),
            'consistency_score' => round($consistencyScore, 4),
            'presence_score'    => round($presenceScore, 4),
            'ai_score_raw'      => round($aiScore, 4),
            'history_score'     => round($historyScore, 4),
            'consensus_score'   => round($consensusScore, 4),
            'gps_lat'           => $snapshot['gps']['latitude']  ?? null,
            'gps_lng'           => $snapshot['gps']['longitude'] ?? null,
            'gps_accuracy'      => $snapshot['gps']['accuracy']  ?? null,
            'captured_at'       => $snapshot['timestamp']        ?? null,
            'device_id'         => $snapshot['deviceID']         ?? null,
            'ai_version'        => self::AI_DETECTION_VERSION,
            'created_at'        => date('Y-m-d H:i:s'),
        ];

        $record['id'] = $this->persistRecord($record);
        return $record;
    }

    private function validatePayloadStructure(array $payload): void
    {
        foreach (['snapshot', 'hash', 'signature', 'presenceScore'] as $key) {
            if (!array_key_exists($key, $payload)) {
                throw new InvalidArgumentException("Missing required payload key: {$key}");
            }
        }
        $snapshot = $payload['snapshot'];
        foreach (['timestamp', 'gps', 'accelerometer', 'gyroscope', 'deviceID'] as $key) {
            if (!array_key_exists($key, $snapshot)) {
                throw new InvalidArgumentException("Missing required snapshot key: {$key}");
            }
        }
        foreach (['latitude', 'longitude', 'altitude', 'accuracy', 'speed'] as $field) {
            if (!array_key_exists($field, $snapshot['gps'])) {
                throw new InvalidArgumentException("Missing required GPS field: {$field}");
            }
        }
        foreach (['accelerometer', 'gyroscope'] as $sensor) {
            foreach (['x', 'y', 'z'] as $axis) {
                if (!array_key_exists($axis, $snapshot[$sensor])) {
                    throw new InvalidArgumentException("Missing {$sensor}.{$axis} in snapshot");
                }
            }
        }
    }

    private function verifyContentHash(array $snapshot, string $clientHash): void
    {
        $sorted     = $this->recursiveKsort($snapshot);
        $json       = json_encode($sorted, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        $serverHash = hash('sha256', $json);
        if (!hash_equals($serverHash, strtolower($clientHash))) {
            throw new RuntimeException('Content hash mismatch. Payload may have been tampered.');
        }
    }

    private function verifyEcdsaSignature(array $snapshot, string $signatureB64, string $userUid): void
    {
        $publicKeyB64 = $this->fetchDevicePublicKey($userUid, $snapshot['deviceID'] ?? '');
        if ($publicKeyB64 === null) {
            throw new RuntimeException('No registered device public key found for this user/device.');
        }
        $rawPublicKey = base64_decode($publicKeyB64, true);
        if ($rawPublicKey === false) {
            throw new RuntimeException('Stored public key is not valid base64.');
        }
        $sorted       = $this->recursiveKsort($snapshot);
        $json         = json_encode($sorted, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        $signatureDer = base64_decode($signatureB64, true);
        if ($signatureDer === false) {
            throw new RuntimeException('Signature is not valid base64.');
        }
        $pemKey = $this->x963PublicKeyToPem($rawPublicKey);
        if ($pemKey === null) {
            throw new RuntimeException('Failed to import device public key.');
        }
        $ecKey = openssl_pkey_get_public($pemKey);
        if ($ecKey === false) {
            throw new RuntimeException('Could not parse device public key PEM.');
        }
        $verifyResult = openssl_verify($json, $signatureDer, $ecKey, OPENSSL_ALGO_SHA256);
        if ($verifyResult !== 1) {
            throw new RuntimeException('ECDSA signature verification failed.');
        }
    }

    private function computeIdentityScore(string $userUid): float
    {
        $stmt = $this->db->prepare(
            'SELECT identity_level, gov_id_confirmed, last_biometric_auth_at
               FROM legit_users WHERE uid = :uid LIMIT 1'
        );
        $stmt->execute([':uid' => $userUid]);
        $row = $stmt->fetch();
        if (!$row) return 0.0;

        $levelScore = match ((int) $row['identity_level']) {
            0 => 0.0, 1 => 0.30, 2 => 0.60, 3 => 1.00, default => 0.0,
        };
        $govBonus       = $row['gov_id_confirmed'] ? 0.15 : 0.0;
        $biometricBonus = 0.0;
        if (!empty($row['last_biometric_auth_at'])) {
            $hoursAgo = (time() - strtotime($row['last_biometric_auth_at'])) / 3600;
            if ($hoursAgo <= 24) {
                $biometricBonus = 0.10 * max(0.0, 1.0 - ($hoursAgo / 24.0));
            }
        }
        return $this->clamp($levelScore + $govBonus + $biometricBonus);
    }

    private function computeConsistencyScore(array $snapshot, string $userUid): float
    {
        $score      = 1.0;
        $capturedAt = strtotime($snapshot['timestamp'] ?? '');
        if ($capturedAt === false) return 0.0;

        $ageSec = abs(time() - $capturedAt);
        if ($ageSec > 300) {
            $score -= min(0.60, ($ageSec - 300) / 3600 * 0.60);
        }

        $accel           = $snapshot['accelerometer'];
        $accelMagnitude  = sqrt($accel['x'] ** 2 + $accel['y'] ** 2 + $accel['z'] ** 2);
        if ($accelMagnitude < 0.1) $score -= 0.40;

        $lastPos = $this->fetchLastKnownPosition($userUid);
        if ($lastPos !== null) {
            $distMetres   = $this->haversineDistanceMetres(
                $lastPos['lat'], $lastPos['lng'],
                (float) $snapshot['gps']['latitude'],
                (float) $snapshot['gps']['longitude']
            );
            $timeDeltaSec = abs(time() - strtotime($lastPos['recorded_at']));
            if ($timeDeltaSec > 0 && ($distMetres / $timeDeltaSec) > 300) {
                $score -= 0.50;
            }
        }
        return $this->clamp($score);
    }

    private function computePresenceScore(array $snapshot, float $clientPresenceNormalized): float
    {
        $accuracy   = (float) ($snapshot['gps']['accuracy'] ?? -1);
        $capturedAt = strtotime($snapshot['timestamp'] ?? '');
        if ($accuracy < 0) return 0.0;

        $accuracyScore = match (true) {
            $accuracy <= self::GPS_ACCURACY_FULL_THRESHOLD  => 1.0,
            $accuracy >= self::GPS_ACCURACY_ZERO_THRESHOLD  => 0.0,
            default => 1.0 - (($accuracy - self::GPS_ACCURACY_FULL_THRESHOLD) /
                               (self::GPS_ACCURACY_ZERO_THRESHOLD - self::GPS_ACCURACY_FULL_THRESHOLD)),
        };

        $ageSec = ($capturedAt !== false) ? abs(time() - $capturedAt) : PHP_INT_MAX;
        $freshnessPenalty = match (true) {
            $ageSec <= self::GPS_AGE_PENALTY_START => 0.0,
            $ageSec >= self::GPS_AGE_PENALTY_END   => self::GPS_AGE_MAX_PENALTY,
            default => (($ageSec - self::GPS_AGE_PENALTY_START) /
                        (self::GPS_AGE_PENALTY_END - self::GPS_AGE_PENALTY_START)) * self::GPS_AGE_MAX_PENALTY,
        };

        $serverPresence = $accuracyScore * (1.0 - $freshnessPenalty);
        $clientNorm     = $this->clamp($clientPresenceNormalized / 100.0);
        return $this->clamp(min($serverPresence, $clientNorm));
    }

    private function computeAiDetectionScore(array $snapshot, string $contentHash): float
    {
        $endpoint = sprintf('http://127.0.0.1:3001/analyze?hash=%s', urlencode($contentHash));
        $context  = stream_context_create([
            'http' => [
                'method'  => 'GET',
                'timeout' => 5,
                'header'  => "Accept: application/json\r\nX-Internal-Token: " .
                              ($_ENV['INTERNAL_SERVICE_TOKEN'] ?? '') . "\r\n",
            ],
        ]);
        $response = @file_get_contents($endpoint, false, $context);
        if ($response === false) return 0.5;
        $data = json_decode($response, true);
        if (!is_array($data) || !isset($data['ai_probability'])) return 0.5;
        return $this->clamp((float) $data['ai_probability']);
    }

    private function computeHistoryScore(string $userUid): float
    {
        $stmt = $this->db->prepare(
            'SELECT COUNT(*) AS total_submissions,
                    SUM(CASE WHEN composite_score >= 60 THEN 1 ELSE 0 END) AS good_submissions,
                    SUM(CASE WHEN flagged = 1 THEN 1 ELSE 0 END) AS flagged_count
               FROM legit_content_records
              WHERE user_uid = :uid
                AND created_at >= DATE_SUB(NOW(), INTERVAL 90 DAY)'
        );
        $stmt->execute([':uid' => $userUid]);
        $row = $stmt->fetch();
        if (!$row || (int) $row['total_submissions'] === 0) return 0.50;

        $total        = (int) $row['total_submissions'];
        $good         = (int) $row['good_submissions'];
        $flagged      = (int) $row['flagged_count'];
        $goodRatio    = $total > 0 ? ($good    / $total) : 0.5;
        $flaggedRatio = $total > 0 ? ($flagged / $total) : 0.0;
        $volumeBonus  = min(0.10, $total / 200 * 0.10);
        return $this->clamp($goodRatio * (1.0 - $flaggedRatio * 1.5) + $volumeBonus);
    }

    private function computeConsensusScore(string $contentHash): float
    {
        $stmt = $this->db->prepare(
            'SELECT COALESCE(SUM(upvotes),0) AS total_upvotes,
                    COALESCE(SUM(downvotes),0) AS total_downvotes,
                    COALESCE(SUM(verifications),0) AS total_verifications
               FROM legit_content_consensus WHERE content_hash = :hash'
        );
        $stmt->execute([':hash' => $contentHash]);
        $row = $stmt->fetch();
        if (!$row) return 0.50;

        $up         = max(0, (int) $row['total_upvotes']);
        $down       = max(0, (int) $row['total_downvotes']);
        $verif      = max(0, (int) $row['total_verifications']);
        $totalVotes = $up + $down;
        $voteRatio  = $totalVotes > 0 ? ($up / $totalVotes) : 0.5;
        $verifBonus = $verif > 0 ? min(0.40, log10($verif + 1) / log10(101) * 0.40) : 0.0;
        return $this->clamp($voteRatio * 0.60 + $verifBonus);
    }

    private function computeComposite(
        float $identity, float $consistency, float $presence,
        float $aiScore, float $history, float $consensus
    ): float {
        $aiInverse = 1.0 - $this->clamp($aiScore);
        $weighted  =
            $identity    * self::WEIGHT_IDENTITY    +
            $consistency * self::WEIGHT_CONSISTENCY +
            $presence    * self::WEIGHT_PRESENCE    +
            $aiInverse   * self::WEIGHT_AI_DETECT   +
            $history     * self::WEIGHT_HISTORY     +
            $consensus   * self::WEIGHT_CONSENSUS;
        return $this->clamp($weighted * 100.0, 0.0, 100.0);
    }

    private function persistRecord(array $record): int
    {
        $sql = 'INSERT INTO legit_content_records (
                    user_uid, content_hash, signature, composite_score,
                    identity_score, consistency_score, presence_score,
                    ai_score_raw, history_score, consensus_score,
                    gps_lat, gps_lng, gps_accuracy,
                    captured_at, device_id, ai_version, created_at
                ) VALUES (
                    :user_uid, :content_hash, :signature, :composite_score,
                    :identity_score, :consistency_score, :presence_score,
                    :ai_score_raw, :history_score, :consensus_score,
                    :gps_lat, :gps_lng, :gps_accuracy,
                    :captured_at, :device_id, :ai_version, :created_at
                )';
        try {
            $stmt = $this->db->prepare($sql);
            $stmt->execute([
                ':user_uid'          => $record['user_uid'],
                ':content_hash'      => $record['content_hash'],
                ':signature'         => $record['signature'],
                ':composite_score'   => $record['composite_score'],
                ':identity_score'    => $record['identity_score'],
                ':consistency_score' => $record['consistency_score'],
                ':presence_score'    => $record['presence_score'],
                ':ai_score_raw'      => $record['ai_score_raw'],
                ':history_score'     => $record['history_score'],
                ':consensus_score'   => $record['consensus_score'],
                ':gps_lat'           => $record['gps_lat'],
                ':gps_lng'           => $record['gps_lng'],
                ':gps_accuracy'      => $record['gps_accuracy'],
                ':captured_at'       => $record['captured_at'],
                ':device_id'         => $record['device_id'],
                ':ai_version'        => $record['ai_version'],
                ':created_at'        => $record['created_at'],
            ]);
        } catch (PDOException $e) {
            throw new RuntimeException('Database write failed: ' . $e->getMessage(), 0, $e);
        }
        return (int) $this->db->lastInsertId();
    }

    private function fetchDevicePublicKey(string $userUid, string $deviceId): ?string
    {
        $stmt = $this->db->prepare(
            'SELECT public_key_b64 FROM legit_device_keys
              WHERE user_uid = :uid AND device_id = :did AND revoked = 0
              ORDER BY created_at DESC LIMIT 1'
        );
        $stmt->execute([':uid' => $userUid, ':did' => $deviceId]);
        $row = $stmt->fetch();
        return $row ? (string) $row['public_key_b64'] : null;
    }

    private function fetchLastKnownPosition(string $userUid): ?array
    {
        $stmt = $this->db->prepare(
            'SELECT gps_lat AS lat, gps_lng AS lng, created_at AS recorded_at
               FROM legit_content_records
              WHERE user_uid = :uid AND gps_lat IS NOT NULL
              ORDER BY created_at DESC LIMIT 1'
        );
        $stmt->execute([':uid' => $userUid]);
        $row = $stmt->fetch();
        return $row ?: null;
    }

    private function x963PublicKeyToPem(string $rawKey): ?string
    {
        if (strlen($rawKey) !== 65 || ord($rawKey[0]) !== 0x04) return null;
        $oidHeader = hex2bin(
            '3059' . '3013' .
            '0607' . '2a8648ce3d0201' .
            '0608' . '2a8648ce3d030107' .
            '0342' . '00'
        );
        if ($oidHeader === false) return null;
        $derKey = $oidHeader . $rawKey;
        $b64    = base64_encode($derKey);
        return "-----BEGIN PUBLIC KEY-----\n" . chunk_split($b64, 64, "\n") . "-----END PUBLIC KEY-----\n";
    }

    private function clamp(float $value, float $min = 0.0, float $max = 1.0): float
    {
        return max($min, min($max, $value));
    }

    private function recursiveKsort(array $array): array
    {
        ksort($array);
        foreach ($array as $key => $value) {
            if (is_array($value)) $array[$key] = $this->recursiveKsort($value);
        }
        return $array;
    }

    private function haversineDistanceMetres(float $lat1, float $lng1, float $lat2, float $lng2): float
    {
        $earthRadius = 6_371_000.0;
        $dLat = deg2rad($lat2 - $lat1);
        $dLng = deg2rad($lng2 - $lng1);
        $a    = sin($dLat / 2) ** 2 + cos(deg2rad($lat1)) * cos(deg2rad($lat2)) * sin($dLng / 2) ** 2;
        return $earthRadius * 2 * atan2(sqrt($a), sqrt(1 - $a));
    }
}
