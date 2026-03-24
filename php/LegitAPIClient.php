<?php
// LegitAPIClient.php
// Entrypoint: POST /api/v1/content/submit | GET /api/v1/content/verify
// PHP 8.2+ | OOP | JWT | Replay-Attack Protection | ScoringEngine bridge

declare(strict_types=1);

namespace Legit\API;

use PDO;
use PDOException;
use RuntimeException;
use InvalidArgumentException;
use Legit\Engine\ScoringEngine;

// ============================================================
// JWT Helper (zero-dependency, HMAC-SHA256)
// ============================================================

final class JWT
{
    private function __construct() {}

    public static function encode(array $payload, string $secret): string
    {
        $header = self::base64url(json_encode(['typ' => 'JWT', 'alg' => 'HS256'], JSON_THROW_ON_ERROR));
        $body   = self::base64url(json_encode($payload, JSON_THROW_ON_ERROR));
        $sig    = self::base64url(hash_hmac('sha256', "$header.$body", $secret, true));
        return "$header.$body.$sig";
    }

    public static function decode(string $token, string $secret): array
    {
        $parts = explode('.', $token);
        if (count($parts) !== 3) throw new RuntimeException('JWT: malformed token.');
        [$headerB64, $bodyB64, $sigB64] = $parts;
        $expectedSig = self::base64url(hash_hmac('sha256', "$headerB64.$bodyB64", $secret, true));
        if (!hash_equals($expectedSig, $sigB64)) throw new RuntimeException('JWT: signature verification failed.');
        $payload = json_decode(self::base64urlDecode($bodyB64), true, 512, JSON_THROW_ON_ERROR);
        if (!is_array($payload)) throw new RuntimeException('JWT: payload is not a JSON object.');
        $now = time();
        if (isset($payload['exp']) && $payload['exp'] < $now) throw new RuntimeException('JWT: token has expired.');
        if (isset($payload['nbf']) && $payload['nbf'] > $now) throw new RuntimeException('JWT: token is not yet valid.');
        if (isset($payload['iat']) && $payload['iat'] > $now + 60) throw new RuntimeException('JWT: token issued in the future.');
        return $payload;
    }

    private static function base64url(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }

    private static function base64urlDecode(string $data): string
    {
        $padded  = str_pad(strtr($data, '-_', '+/'), strlen($data) % 4, '=', STR_PAD_RIGHT);
        $decoded = base64_decode($padded, true);
        if ($decoded === false) throw new RuntimeException('JWT: base64url decode failed.');
        return $decoded;
    }
}

// ============================================================
// HTTP Response Helper
// ============================================================

final class HttpResponse
{
    private function __construct() {}

    public static function json(int $status, array $body): never
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');
        header('Strict-Transport-Security: max-age=31536000; includeSubDomains');
        echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        exit;
    }

    public static function error(int $status, string $code, string $message): never
    {
        self::json($status, ['success' => false, 'error' => ['code' => $code, 'message' => $message]]);
    }
}

// ============================================================
// Nonce Store
// ============================================================

final class NonceStore
{
    private PDO $db;
    private int $ttlSeconds;

    public function __construct(PDO $db, int $ttlSeconds = 300)
    {
        $this->db         = $db;
        $this->ttlSeconds = $ttlSeconds;
    }

    public function consumeIfFresh(string $nonce, string $userUid): bool
    {
        if (random_int(1, 20) === 1) $this->purgeExpired();
        $this->db->beginTransaction();
        try {
            $stmt = $this->db->prepare(
                'SELECT id FROM legit_nonces WHERE nonce = :nonce AND user_uid = :uid LIMIT 1 FOR UPDATE'
            );
            $stmt->execute([':nonce' => $nonce, ':uid' => $userUid]);
            if ($stmt->fetch() !== false) { $this->db->rollBack(); return false; }
            $insert = $this->db->prepare(
                'INSERT INTO legit_nonces (nonce, user_uid, expires_at)
                 VALUES (:nonce, :uid, DATE_ADD(NOW(), INTERVAL :ttl SECOND))'
            );
            $insert->execute([':nonce' => $nonce, ':uid' => $userUid, ':ttl' => $this->ttlSeconds]);
            $this->db->commit();
            return true;
        } catch (PDOException $e) {
            $this->db->rollBack();
            throw new RuntimeException('NonceStore: database error — ' . $e->getMessage(), 0, $e);
        }
    }

    private function purgeExpired(): void
    {
        try { $this->db->exec('DELETE FROM legit_nonces WHERE expires_at < NOW()'); }
        catch (PDOException) {}
    }
}

// ============================================================
// Blockchain Queue Dispatcher
// ============================================================

final class BlockchainQueueDispatcher
{
    private string $nodeBaseUrl;
    private string $internalToken;
    private int    $timeoutSeconds;

    public function __construct(string $nodeBaseUrl, string $internalToken, int $timeoutSeconds = 3)
    {
        $this->nodeBaseUrl    = rtrim($nodeBaseUrl, '/');
        $this->internalToken  = $internalToken;
        $this->timeoutSeconds = $timeoutSeconds;
    }

    public function enqueue(string $contentHash, string $userUid): void
    {
        $body    = json_encode(['content_hash' => $contentHash, 'user_uid' => $userUid], JSON_THROW_ON_ERROR);
        $context = stream_context_create([
            'http' => [
                'method'        => 'POST',
                'header'        => implode("\r\n", [
                    'Content-Type: application/json',
                    'Content-Length: ' . strlen($body),
                    'X-Internal-Token: ' . $this->internalToken,
                ]),
                'content'       => $body,
                'timeout'       => $this->timeoutSeconds,
                'ignore_errors' => true,
            ],
        ]);
        @file_get_contents($this->nodeBaseUrl . '/internal/queue-anchoring', false, $context);
    }
}

// ============================================================
// Request Validator
// ============================================================

final class SubmitRequestValidator
{
    private const MAX_CLOCK_SKEW_SECONDS = 120;
    private const MAX_NONCE_LENGTH = 64;
    private const MIN_NONCE_LENGTH = 16;

    public function validate(array $body): void
    {
        foreach (['payload', 'nonce', 'client_timestamp', 'app_version'] as $field) {
            if (!array_key_exists($field, $body) || $body[$field] === '' || $body[$field] === null) {
                throw new InvalidArgumentException("Missing or empty required field: {$field}");
            }
        }
        foreach (['snapshot', 'hash', 'signature', 'presenceScore'] as $field) {
            if (!array_key_exists($field, $body['payload'])) {
                throw new InvalidArgumentException("Missing payload field: {$field}");
            }
        }
        $nonce = (string) $body['nonce'];
        if (strlen($nonce) < self::MIN_NONCE_LENGTH || strlen($nonce) > self::MAX_NONCE_LENGTH) {
            throw new InvalidArgumentException(sprintf('Nonce length must be between %d and %d chars.', self::MIN_NONCE_LENGTH, self::MAX_NONCE_LENGTH));
        }
        $clientTs = filter_var($body['client_timestamp'], FILTER_VALIDATE_INT);
        if ($clientTs === false || $clientTs === null) {
            throw new InvalidArgumentException('client_timestamp must be a Unix epoch integer.');
        }
        $skew = abs(time() - (int) $clientTs);
        if ($skew > self::MAX_CLOCK_SKEW_SECONDS) {
            throw new InvalidArgumentException("Request timestamp is outside the acceptable window ({$skew}s skew; max " . self::MAX_CLOCK_SKEW_SECONDS . 's).');
        }
        $hash = (string) ($body['payload']['hash'] ?? '');
        if (!preg_match('/^[a-f0-9]{64}$/', $hash)) {
            throw new InvalidArgumentException('payload.hash must be a 64-character lowercase hex SHA-256 digest.');
        }
        $ps = $body['payload']['presenceScore'];
        if (!is_numeric($ps) || (float) $ps < 0.0 || (float) $ps > 100.0) {
            throw new InvalidArgumentException('payload.presenceScore must be a number between 0 and 100.');
        }
    }
}

// ============================================================
// Database Factory
// ============================================================

final class DatabaseFactory
{
    private function __construct() {}

    public static function create(): PDO
    {
        $host    = $_ENV['DB_HOST']  ?? '127.0.0.1';
        $port    = $_ENV['DB_PORT']  ?? '3306';
        $dbname  = $_ENV['DB_NAME']  ?? 'legit_db';
        $user    = $_ENV['DB_USER']  ?? 'legit_app';
        $pass    = $_ENV['DB_PASS']  ?? '';
        $dsn     = "mysql:host={$host};port={$port};dbname={$dbname};charset=utf8mb4";
        try {
            return new PDO($dsn, $user, $pass, [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES   => false,
                PDO::MYSQL_ATTR_FOUND_ROWS   => true,
            ]);
        } catch (PDOException $e) {
            throw new RuntimeException('Database connection failed.', 0, $e);
        }
    }
}

// ============================================================
// Request Logger
// ============================================================

final class RequestLogger
{
    private PDO $db;
    public function __construct(PDO $db) { $this->db = $db; }

    public function log(?int $apiKeyId, ?string $userUid, string $endpoint, string $method,
                        int $httpStatus, ?int $responseMs, ?string $contentHash): void
    {
        $ipRaw  = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? '';
        $ipHash = hash('sha256', trim(explode(',', $ipRaw)[0]));
        try {
            $stmt = $this->db->prepare(
                'INSERT INTO legit_api_request_log
                    (api_key_id, user_uid, endpoint, method, ip_hash, http_status, response_ms, content_hash, requested_at)
                 VALUES (:api_key_id, :user_uid, :endpoint, :method, :ip_hash, :http_status, :response_ms, :content_hash, NOW())'
            );
            $stmt->execute([
                ':api_key_id'   => $apiKeyId,
                ':user_uid'     => $userUid,
                ':endpoint'     => $endpoint,
                ':method'       => $method,
                ':ip_hash'      => $ipHash,
                ':http_status'  => $httpStatus,
                ':response_ms'  => $responseMs,
                ':content_hash' => $contentHash,
            ]);
        } catch (PDOException) {}
    }
}

// ============================================================
// Content Submit Controller
// ============================================================

final class ContentSubmitController
{
    public function __construct(
        private PDO $db,
        private NonceStore $nonceStore,
        private SubmitRequestValidator $validator,
        private BlockchainQueueDispatcher $blockchainDispatcher,
        private RequestLogger $logger,
        private string $jwtSecret
    ) {}

    public function handle(): never
    {
        $startMs     = (int) (microtime(true) * 1000);
        $userUid     = null;
        $contentHash = null;

        try {
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                HttpResponse::error(405, 'METHOD_NOT_ALLOWED', 'Only POST is accepted.');
            }
            $rawBody = file_get_contents('php://input');
            if ($rawBody === false || $rawBody === '') {
                HttpResponse::error(400, 'EMPTY_BODY', 'Request body is empty.');
            }
            $body = json_decode($rawBody, true, 32, JSON_THROW_ON_ERROR);
            if (!is_array($body)) {
                HttpResponse::error(400, 'INVALID_JSON', 'Request body must be a JSON object.');
            }

            $authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['HTTP_X_LEGIT_TOKEN'] ?? '';
            if (!str_starts_with($authHeader, 'Bearer ')) {
                HttpResponse::error(401, 'MISSING_TOKEN', 'Authorization: Bearer <token> header is required.');
            }
            $claims  = JWT::decode(substr($authHeader, 7), $this->jwtSecret);
            $userUid = $claims['sub'] ?? null;
            if (empty($userUid) || !is_string($userUid)) {
                HttpResponse::error(401, 'INVALID_TOKEN', 'JWT sub claim is missing or invalid.');
            }
            $this->assertUserActive($userUid);

            try { $this->validator->validate($body); }
            catch (InvalidArgumentException $e) { HttpResponse::error(422, 'VALIDATION_ERROR', $e->getMessage()); }

            $nonce    = (string) $body['nonce'];
            $clientTs = (int)    $body['client_timestamp'];
            if (abs(time() - $clientTs) > 120) {
                HttpResponse::error(422, 'TIMESTAMP_OUT_OF_WINDOW', 'Request timestamp is outside the 120s window.');
            }
            if (!$this->nonceStore->consumeIfFresh($nonce, $userUid)) {
                HttpResponse::error(409, 'REPLAY_DETECTED', 'This nonce has already been used. Possible replay attack.');
            }

            $payload     = $body['payload'];
            $contentHash = (string) $payload['hash'];
            $scoringEngine = new ScoringEngine($this->db);

            try { $record = $scoringEngine->process($payload, $userUid); }
            catch (InvalidArgumentException $e) { HttpResponse::error(422, 'PAYLOAD_INVALID', $e->getMessage()); }
            catch (RuntimeException $e) { HttpResponse::error(500, 'SCORING_FAILED', $e->getMessage()); }

            $this->insertBlockchainQueue($contentHash);
            $this->blockchainDispatcher->enqueue($contentHash, $userUid);

            $responseMs = (int) (microtime(true) * 1000) - $startMs;
            $response   = [
                'success'      => true,
                'record_id'    => $record['id'],
                'score'        => [
                    'composite'   => (float) $record['composite_score'],
                    'identity'    => (float) $record['identity_score'],
                    'consistency' => (float) $record['consistency_score'],
                    'presence'    => (float) $record['presence_score'],
                    'ai_inverse'  => round(1.0 - (float) $record['ai_score_raw'], 4),
                    'history'     => (float) $record['history_score'],
                    'consensus'   => (float) $record['consensus_score'],
                ],
                'content_hash' => $contentHash,
                'eas_uid'      => null,
                'anchoring'    => 'queued',
                'server_ts'    => time(),
            ];

            $this->logger->log(null, $userUid, '/api/v1/content/submit', 'POST', 200, $responseMs, $contentHash);
            HttpResponse::json(200, $response);

        } catch (RuntimeException $e) {
            $responseMs = (int) (microtime(true) * 1000) - $startMs;
            $this->logger->log(null, $userUid, '/api/v1/content/submit', 'POST', 500, $responseMs, $contentHash);
            HttpResponse::error(500, 'INTERNAL_ERROR', 'An internal error occurred. Please try again.');
        }
    }

    private function assertUserActive(string $userUid): void
    {
        $stmt = $this->db->prepare('SELECT account_status FROM legit_users WHERE uid = :uid LIMIT 1');
        $stmt->execute([':uid' => $userUid]);
        $row = $stmt->fetch();
        if (!$row) HttpResponse::error(401, 'USER_NOT_FOUND', 'Authenticated user does not exist.');
        if ($row['account_status'] !== 'active') HttpResponse::error(403, 'ACCOUNT_INACTIVE', 'Account is suspended or deleted.');
    }

    private function insertBlockchainQueue(string $contentHash): void
    {
        try {
            $stmt = $this->db->prepare("INSERT IGNORE INTO legit_blockchain_queue (content_hash, status, queued_at) VALUES (:hash, 'pending', NOW())");
            $stmt->execute([':hash' => $contentHash]);
        } catch (PDOException $e) {
            error_log('[LegitAPI] blockchain queue insert failed: ' . $e->getMessage());
        }
    }
}

// ============================================================
// Content Verify Controller
// ============================================================

final class ContentVerifyController
{
    public function __construct(private PDO $db, private RequestLogger $logger) {}

    public function handle(): never
    {
        $startMs = (int) (microtime(true) * 1000);
        if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
            HttpResponse::error(405, 'METHOD_NOT_ALLOWED', 'Only GET is accepted.');
        }
        $hash = trim($_GET['hash'] ?? '');
        if (!preg_match('/^[a-f0-9]{64}$/', $hash)) {
            HttpResponse::error(400, 'INVALID_HASH', 'hash must be a 64-character lowercase hex SHA-256 digest.');
        }
        $stmt = $this->db->prepare(
            'SELECT r.content_hash, r.composite_score, r.identity_score, r.consistency_score,
                    r.presence_score, r.ai_score_raw, r.history_score, r.consensus_score,
                    r.content_type, r.gps_lat, r.gps_lng, r.gps_accuracy, r.captured_at,
                    r.ipfs_cid, r.eas_uid, r.blockchain_tx, r.anchored_at, r.flagged, r.created_at,
                    COALESCE(c.upvotes,0) AS upvotes, COALESCE(c.downvotes,0) AS downvotes,
                    COALESCE(c.verifications,0) AS verifications
               FROM legit_content_records r
               LEFT JOIN legit_content_consensus c ON c.content_hash = r.content_hash
              WHERE r.content_hash = :hash LIMIT 1'
        );
        $stmt->execute([':hash' => $hash]);
        $row = $stmt->fetch();
        if (!$row) HttpResponse::error(404, 'NOT_FOUND', 'No LEGIT record found for this content hash.');

        $responseMs = (int) (microtime(true) * 1000) - $startMs;
        $this->logger->log(null, null, '/api/v1/content/verify', 'GET', 200, $responseMs, $hash);

        HttpResponse::json(200, [
            'success'      => true,
            'content_hash' => $row['content_hash'],
            'score'        => [
                'composite'   => (float) $row['composite_score'],
                'identity'    => (float) $row['identity_score'],
                'consistency' => (float) $row['consistency_score'],
                'presence'    => (float) $row['presence_score'],
                'ai_inverse'  => round(1.0 - (float) $row['ai_score_raw'], 4),
                'history'     => (float) $row['history_score'],
                'consensus'   => (float) $row['consensus_score'],
            ],
            'location'     => [
                'latitude'  => $row['gps_lat']      !== null ? (float) $row['gps_lat']      : null,
                'longitude' => $row['gps_lng']      !== null ? (float) $row['gps_lng']      : null,
                'accuracy'  => $row['gps_accuracy'] !== null ? (float) $row['gps_accuracy'] : null,
            ],
            'blockchain'   => [
                'ipfs_cid'    => $row['ipfs_cid'],
                'eas_uid'     => $row['eas_uid'],
                'tx_hash'     => $row['blockchain_tx'],
                'anchored_at' => $row['anchored_at'],
            ],
            'consensus'    => [
                'upvotes'       => (int) $row['upvotes'],
                'downvotes'     => (int) $row['downvotes'],
                'verifications' => (int) $row['verifications'],
            ],
            'content_type' => $row['content_type'],
            'captured_at'  => $row['captured_at'],
            'flagged'       => (bool) $row['flagged'],
            'created_at'   => $row['created_at'],
        ]);
    }
}

// ============================================================
// Router / Bootstrap
// ============================================================

$jwtSecret     = $_ENV['LEGIT_JWT_SECRET']      ?? '';
$nodeBaseUrl   = $_ENV['LEGIT_NODE_URL']         ?? 'http://127.0.0.1:3001';
$internalToken = $_ENV['INTERNAL_SERVICE_TOKEN'] ?? '';

if (empty($jwtSecret)) {
    HttpResponse::error(500, 'MISCONFIGURATION', 'Server JWT secret is not configured.');
}

$db         = DatabaseFactory::create();
$logger     = new RequestLogger($db);
$nonceStore = new NonceStore($db, 300);
$validator  = new SubmitRequestValidator();
$dispatcher = new BlockchainQueueDispatcher($nodeBaseUrl, $internalToken);

$path = rtrim($_SERVER['PATH_INFO'] ?? parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), '/');

match ($path) {
    '/api/v1/content/submit' => (new ContentSubmitController(
        $db, $nonceStore, $validator, $dispatcher, $logger, $jwtSecret
    ))->handle(),
    '/api/v1/content/verify' => (new ContentVerifyController($db, $logger))->handle(),
    default => HttpResponse::error(404, 'NOT_FOUND', "No route matches {$path}")
};
