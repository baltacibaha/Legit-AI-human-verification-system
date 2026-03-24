-- legit_schema.sql
-- MySQL 8.0+ | utf8mb4 | InnoDB
-- Run as: mysql -u root -p legit_db < legit_schema.sql

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET SQL_MODE = 'STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

CREATE DATABASE IF NOT EXISTS legit_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE legit_db;

CREATE TABLE IF NOT EXISTS legit_users (
    id                      BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    uid                     CHAR(36)            NOT NULL COMMENT 'UUID v4',
    email_hash              CHAR(64)            NOT NULL COMMENT 'SHA-256 of lowercased email',
    phone_hash              CHAR(64)                NULL,
    identity_level          TINYINT UNSIGNED    NOT NULL DEFAULT 0 COMMENT '0=none,1=email,2=phone,3=govID+ZK',
    gov_id_confirmed        TINYINT(1)          NOT NULL DEFAULT 0,
    zk_proof_ref            VARCHAR(255)            NULL,
    last_biometric_auth_at  DATETIME                NULL,
    account_status          ENUM('active','suspended','deleted') NOT NULL DEFAULT 'active',
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_legit_users_uid        (uid),
    UNIQUE  KEY uq_legit_users_email_hash (email_hash),
    INDEX        idx_legit_users_status   (account_status),
    INDEX        idx_legit_users_id_level (identity_level)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Core user accounts – minimal PII, ZK-first design';

CREATE TABLE IF NOT EXISTS legit_device_keys (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid        CHAR(36)         NOT NULL,
    device_id       VARCHAR(64)      NOT NULL COMMENT 'UIDevice.identifierForVendor',
    device_name     VARCHAR(128)         NULL,
    public_key_b64  TEXT             NOT NULL COMMENT 'X9.63 uncompressed P-256 public key, base64',
    key_fingerprint CHAR(64)         NOT NULL COMMENT 'SHA-256 of raw public key bytes (hex)',
    platform        VARCHAR(32)      NOT NULL DEFAULT 'ios',
    os_version      VARCHAR(32)          NULL,
    app_version     VARCHAR(32)          NULL,
    revoked         TINYINT(1)       NOT NULL DEFAULT 0,
    revoked_at      DATETIME             NULL,
    revoke_reason   VARCHAR(255)         NULL,
    created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_device_key_fingerprint   (key_fingerprint),
    UNIQUE  KEY uq_device_user_device       (user_uid, device_id),
    INDEX        idx_device_keys_user_uid   (user_uid),
    INDEX        idx_device_keys_revoked    (revoked),
    CONSTRAINT fk_device_keys_user_uid
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='P-256 Secure Enclave public keys, one row per device';

CREATE TABLE IF NOT EXISTS legit_content_records (
    id                  BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid            CHAR(36)         NOT NULL,
    content_hash        CHAR(64)         NOT NULL COMMENT 'SHA-256 hex',
    signature           TEXT             NOT NULL COMMENT 'DER ECDSA signature, base64',
    device_id           VARCHAR(64)          NULL,
    composite_score     DECIMAL(7,4)     NOT NULL COMMENT '0-100',
    identity_score      DECIMAL(6,4)     NOT NULL DEFAULT 0.0000,
    consistency_score   DECIMAL(6,4)     NOT NULL DEFAULT 0.0000,
    presence_score      DECIMAL(6,4)     NOT NULL DEFAULT 0.0000,
    ai_score_raw        DECIMAL(6,4)     NOT NULL DEFAULT 0.5000 COMMENT '0=human,1=AI',
    history_score       DECIMAL(6,4)     NOT NULL DEFAULT 0.5000,
    consensus_score     DECIMAL(6,4)     NOT NULL DEFAULT 0.5000,
    gps_lat             DECIMAL(10,7)        NULL,
    gps_lng             DECIMAL(10,7)        NULL,
    gps_accuracy        DECIMAL(8,2)         NULL,
    gps_altitude        DECIMAL(9,2)         NULL,
    accel_x             DECIMAL(10,6)        NULL,
    accel_y             DECIMAL(10,6)        NULL,
    accel_z             DECIMAL(10,6)        NULL,
    gyro_x              DECIMAL(10,6)        NULL,
    gyro_y              DECIMAL(10,6)        NULL,
    gyro_z              DECIMAL(10,6)        NULL,
    ipfs_cid            VARCHAR(128)         NULL,
    eas_uid             VARCHAR(128)         NULL,
    blockchain_tx       VARCHAR(128)         NULL,
    anchored_at         DATETIME             NULL,
    content_type        ENUM('photo','video','text','audio','document') NOT NULL DEFAULT 'photo',
    ai_version          VARCHAR(32)          NULL,
    flagged             TINYINT(1)       NOT NULL DEFAULT 0,
    flag_reason         VARCHAR(255)         NULL,
    flagged_at          DATETIME             NULL,
    captured_at         DATETIME             NULL,
    created_at          DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_content_hash                    (content_hash),
    INDEX        idx_content_records_user_uid      (user_uid),
    INDEX        idx_content_records_composite     (composite_score),
    INDEX        idx_content_records_captured_at   (captured_at),
    INDEX        idx_content_records_flagged       (flagged),
    INDEX        idx_content_records_ipfs_cid      (ipfs_cid),
    INDEX        idx_content_records_eas_uid       (eas_uid),
    INDEX        idx_content_records_gps           (gps_lat, gps_lng),
    INDEX        idx_content_records_anchored      (anchored_at),
    CONSTRAINT fk_content_records_user_uid
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_content_records_device
        FOREIGN KEY (device_id) REFERENCES legit_device_keys (device_id)
        ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='One row per LEGIT-signed content submission';

CREATE TABLE IF NOT EXISTS legit_content_consensus (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    content_hash    CHAR(64)         NOT NULL,
    upvotes         INT UNSIGNED     NOT NULL DEFAULT 0,
    downvotes       INT UNSIGNED     NOT NULL DEFAULT 0,
    verifications   INT UNSIGNED     NOT NULL DEFAULT 0,
    reporter_count  INT UNSIGNED     NOT NULL DEFAULT 0,
    last_vote_at    DATETIME             NULL,
    updated_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_consensus_hash            (content_hash),
    INDEX        idx_consensus_verifications (verifications),
    CONSTRAINT fk_consensus_content_hash
        FOREIGN KEY (content_hash) REFERENCES legit_content_records (content_hash)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Aggregated community votes per content hash';

CREATE TABLE IF NOT EXISTS legit_consensus_votes (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid        CHAR(36)         NOT NULL,
    content_hash    CHAR(64)         NOT NULL,
    vote_type       ENUM('upvote','downvote','report') NOT NULL,
    report_reason   VARCHAR(255)         NULL,
    created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_vote_user_content     (user_uid, content_hash),
    INDEX        idx_vote_content_hash   (content_hash),
    INDEX        idx_vote_user_uid       (user_uid),
    CONSTRAINT fk_consensus_votes_user
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_consensus_votes_content
        FOREIGN KEY (content_hash) REFERENCES legit_content_records (content_hash)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Individual vote rows; one per user+content';

CREATE TABLE IF NOT EXISTS legit_zk_proofs (
    id                  BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid            CHAR(36)         NOT NULL,
    nullifier_hash      CHAR(64)         NOT NULL COMMENT 'SHA-256 of ZK nullifier',
    proof_type          ENUM('age','nationality','real_human','gov_id') NOT NULL,
    provider            VARCHAR(64)      NOT NULL DEFAULT 'self',
    circuit_version     VARCHAR(32)          NULL,
    verified_at         DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at          DATETIME             NULL,
    revoked             TINYINT(1)       NOT NULL DEFAULT 0,
    revoked_at          DATETIME             NULL,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_zk_nullifier          (nullifier_hash),
    INDEX        idx_zk_proofs_user_uid  (user_uid),
    INDEX        idx_zk_proofs_type      (proof_type),
    INDEX        idx_zk_proofs_expires   (expires_at),
    CONSTRAINT fk_zk_proofs_user_uid
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='ZK-proof audit log; nullifier-only storage for GDPR compliance';

CREATE TABLE IF NOT EXISTS legit_api_keys (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid        CHAR(36)         NOT NULL,
    key_hash        CHAR(60)         NOT NULL COMMENT 'bcrypt hash',
    key_prefix      CHAR(8)          NOT NULL COMMENT 'First 8 chars shown in dashboard',
    label           VARCHAR(128)         NULL,
    tier            ENUM('free','pro','enterprise') NOT NULL DEFAULT 'free',
    rate_limit_rpm  SMALLINT UNSIGNED NOT NULL DEFAULT 60,
    scopes          SET('verify','submit','export','admin') NOT NULL DEFAULT 'verify',
    last_used_at    DATETIME             NULL,
    expires_at      DATETIME             NULL,
    revoked         TINYINT(1)       NOT NULL DEFAULT 0,
    created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_api_key_hash       (key_hash),
    INDEX        idx_api_keys_user    (user_uid),
    INDEX        idx_api_keys_prefix  (key_prefix),
    INDEX        idx_api_keys_revoked (revoked),
    CONSTRAINT fk_api_keys_user_uid
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='API keys; raw key never stored';

CREATE TABLE IF NOT EXISTS legit_api_request_log (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    api_key_id      BIGINT UNSIGNED      NULL,
    user_uid        CHAR(36)             NULL,
    endpoint        VARCHAR(255)     NOT NULL,
    method          CHAR(7)          NOT NULL,
    ip_hash         CHAR(64)         NOT NULL COMMENT 'SHA-256 of client IP',
    http_status     SMALLINT UNSIGNED NOT NULL,
    response_ms     SMALLINT UNSIGNED    NULL,
    content_hash    CHAR(64)             NULL,
    requested_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX  idx_request_log_api_key      (api_key_id),
    INDEX  idx_request_log_user_uid     (user_uid),
    INDEX  idx_request_log_requested_at (requested_at),
    INDEX  idx_request_log_status       (http_status),
    CONSTRAINT fk_request_log_api_key
        FOREIGN KEY (api_key_id) REFERENCES legit_api_keys (id)
        ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='90-day rolling API audit log'
  ROW_FORMAT=COMPRESSED;

CREATE TABLE IF NOT EXISTS legit_blockchain_queue (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    content_hash    CHAR(64)         NOT NULL,
    status          ENUM('pending','processing','done','failed') NOT NULL DEFAULT 'pending',
    attempts        TINYINT UNSIGNED NOT NULL DEFAULT 0,
    last_error      TEXT                 NULL,
    ipfs_cid        VARCHAR(128)         NULL,
    eas_uid         VARCHAR(128)         NULL,
    blockchain_tx   VARCHAR(128)         NULL,
    queued_at       DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at    DATETIME             NULL,
    next_retry_at   DATETIME             NULL,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_queue_content_hash  (content_hash),
    INDEX        idx_queue_status      (status),
    INDEX        idx_queue_next_retry  (next_retry_at),
    CONSTRAINT fk_queue_content_hash
        FOREIGN KEY (content_hash) REFERENCES legit_content_records (content_hash)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Async job queue for IPFS + EAS anchoring';

CREATE TABLE IF NOT EXISTS legit_notifications (
    id              BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid        CHAR(36)         NOT NULL,
    type            ENUM('score_ready','anchored','flagged','consensus_update','identity_verified','api_key_created','device_revoked') NOT NULL,
    content_hash    CHAR(64)             NULL,
    title           VARCHAR(128)     NOT NULL,
    body            VARCHAR(512)     NOT NULL,
    read_at         DATETIME             NULL,
    created_at      DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX  idx_notifications_user_uid (user_uid),
    INDEX  idx_notifications_read     (read_at),
    INDEX  idx_notifications_type     (type),
    CONSTRAINT fk_notifications_user_uid
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='In-app notification feed';

CREATE TABLE IF NOT EXISTS legit_subscriptions (
    id                       BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    user_uid                 CHAR(36)         NOT NULL,
    plan                     ENUM('free','pro','enterprise') NOT NULL DEFAULT 'free',
    provider                 VARCHAR(32)      NOT NULL DEFAULT 'stripe',
    provider_subscription_id VARCHAR(128)         NULL,
    provider_customer_id     VARCHAR(128)         NULL,
    status                   ENUM('active','past_due','cancelled','trialing') NOT NULL DEFAULT 'active',
    current_period_start     DATETIME             NULL,
    current_period_end       DATETIME             NULL,
    cancelled_at             DATETIME             NULL,
    created_at               DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_subscription_user_uid      (user_uid),
    INDEX        idx_subscription_status      (status),
    INDEX        idx_subscription_period_end  (current_period_end),
    CONSTRAINT fk_subscriptions_user_uid
        FOREIGN KEY (user_uid) REFERENCES legit_users (uid)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Subscription plan state';

CREATE TABLE IF NOT EXISTS legit_nonces (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    nonce      VARCHAR(88)     NOT NULL,
    user_uid   CHAR(36)        NOT NULL,
    expires_at DATETIME        NOT NULL,
    created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE  KEY uq_nonce_user    (nonce, user_uid),
    INDEX        idx_nonce_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Consumed request nonces for replay-attack prevention; TTL 5 minutes';

-- ============================================================
-- VIEWS
-- ============================================================

CREATE OR REPLACE VIEW v_user_score_summary AS
SELECT
    u.uid,
    u.identity_level,
    u.gov_id_confirmed,
    COUNT(r.id)                              AS total_submissions_30d,
    ROUND(AVG(r.composite_score), 2)         AS avg_composite_30d,
    SUM(CASE WHEN r.flagged = 1 THEN 1 ELSE 0 END)              AS flagged_count_30d,
    SUM(CASE WHEN r.anchored_at IS NOT NULL THEN 1 ELSE 0 END)  AS anchored_count_30d,
    MAX(r.created_at)                        AS last_submission_at
FROM legit_users u
LEFT JOIN legit_content_records r
    ON r.user_uid = u.uid
    AND r.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
WHERE u.account_status = 'active'
GROUP BY u.id;

CREATE OR REPLACE VIEW v_content_full AS
SELECT
    r.id, r.user_uid, r.content_hash,
    r.composite_score, r.identity_score, r.consistency_score,
    r.presence_score, r.ai_score_raw, r.history_score, r.consensus_score,
    r.gps_lat, r.gps_lng, r.gps_accuracy,
    r.content_type, r.ipfs_cid, r.eas_uid, r.blockchain_tx,
    r.anchored_at, r.flagged, r.captured_at, r.created_at,
    COALESCE(c.upvotes,      0) AS upvotes,
    COALESCE(c.downvotes,    0) AS downvotes,
    COALESCE(c.verifications,0) AS verifications,
    COALESCE(c.reporter_count,0) AS reporter_count
FROM legit_content_records r
LEFT JOIN legit_content_consensus c ON c.content_hash = r.content_hash;

-- ============================================================
-- STORED PROCEDURES
-- ============================================================

DELIMITER $$

CREATE PROCEDURE sp_upsert_consensus(
    IN p_content_hash   CHAR(64),
    IN p_upvote_delta   TINYINT,
    IN p_downvote_delta TINYINT,
    IN p_verif_delta    TINYINT,
    IN p_report_delta   TINYINT
)
BEGIN
    INSERT INTO legit_content_consensus
        (content_hash, upvotes, downvotes, verifications, reporter_count, last_vote_at)
    VALUES
        (p_content_hash,
         GREATEST(0, p_upvote_delta),
         GREATEST(0, p_downvote_delta),
         GREATEST(0, p_verif_delta),
         GREATEST(0, p_report_delta),
         NOW())
    ON DUPLICATE KEY UPDATE
        upvotes        = GREATEST(0, upvotes       + p_upvote_delta),
        downvotes      = GREATEST(0, downvotes     + p_downvote_delta),
        verifications  = GREATEST(0, verifications + p_verif_delta),
        reporter_count = GREATEST(0, reporter_count + p_report_delta),
        last_vote_at   = NOW();
END$$

CREATE PROCEDURE sp_queue_blockchain(IN p_content_hash CHAR(64))
BEGIN
    INSERT IGNORE INTO legit_blockchain_queue (content_hash, status, queued_at)
    VALUES (p_content_hash, 'pending', NOW());
END$$

CREATE PROCEDURE sp_complete_blockchain(
    IN p_content_hash  CHAR(64),
    IN p_ipfs_cid      VARCHAR(128),
    IN p_eas_uid       VARCHAR(128),
    IN p_blockchain_tx VARCHAR(128)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
    START TRANSACTION;
    UPDATE legit_content_records
       SET ipfs_cid = p_ipfs_cid, eas_uid = p_eas_uid,
           blockchain_tx = p_blockchain_tx, anchored_at = NOW()
     WHERE content_hash = p_content_hash;
    UPDATE legit_blockchain_queue
       SET status = 'done', ipfs_cid = p_ipfs_cid, eas_uid = p_eas_uid,
           blockchain_tx = p_blockchain_tx, processed_at = NOW()
     WHERE content_hash = p_content_hash;
    COMMIT;
END$$

CREATE PROCEDURE sp_purge_request_log()
BEGIN
    DELETE FROM legit_api_request_log
     WHERE requested_at < DATE_SUB(NOW(), INTERVAL 90 DAY);
END$$

DELIMITER ;

CREATE EVENT IF NOT EXISTS evt_purge_request_log
    ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP
    DO CALL sp_purge_request_log();

INSERT IGNORE INTO legit_users (uid, email_hash, identity_level, account_status)
VALUES ('00000000-0000-0000-0000-000000000001', SHA2('system@legit.internal', 256), 3, 'active');

SET FOREIGN_KEY_CHECKS = 1;
