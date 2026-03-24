'use strict';

require('dotenv').config();

const http    = require('http');
const https   = require('https');
const crypto  = require('crypto');
const { URL } = require('url');
const mysql   = require('mysql2/promise');
const { IPFSService } = require('./ipfsService');
const { EASService  } = require('./easService');

// ── Environment validation ────────────────────────────────────
const REQUIRED_ENV = [
  'PINATA_JWT', 'EAS_PRIVATE_KEY', 'EAS_RPC_URL', 'EAS_SCHEMA_UID',
  'DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASS',
  'INTERNAL_SERVICE_TOKEN', 'PHP_WEBHOOK_URL',
];
for (const key of REQUIRED_ENV) {
  if (!process.env[key] || process.env[key].trim() === '') {
    process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), level: 'ERROR', msg: `Required env var "${key}" is not set.` }) + '\n');
    process.exit(1);
  }
}

const CONFIG = {
  port:              parseInt(process.env.PORT                  || '3001', 10),
  internalToken:     process.env.INTERNAL_SERVICE_TOKEN.trim(),
  phpWebhookUrl:     process.env.PHP_WEBHOOK_URL.trim(),
  webhookSecret:     process.env.WEBHOOK_SECRET?.trim() || '',
  pollIntervalMs:    parseInt(process.env.POLL_INTERVAL_MS      || '5000',   10),
  maxConcurrent:     parseInt(process.env.MAX_CONCURRENT_JOBS   || '3',      10),
  maxAttempts:       parseInt(process.env.MAX_RETRY_ATTEMPTS    || '7',      10),
  backoffBaseMs:     parseInt(process.env.BACKOFF_BASE_MS       || '2000',   10),
  backoffMaxMs:      parseInt(process.env.BACKOFF_MAX_MS        || '300000', 10),
  gasPriceLimitGwei: parseFloat(process.env.GAS_PRICE_LIMIT_GWEI || '50'),
  db: {
    host: process.env.DB_HOST, port: parseInt(process.env.DB_PORT || '3306', 10),
    database: process.env.DB_NAME, user: process.env.DB_USER, password: process.env.DB_PASS,
    waitForConnections: true, connectionLimit: 10, queueLimit: 0, charset: 'utf8mb4',
  },
};

// ── Logger ────────────────────────────────────────────────────
const LOG_LEVEL = { debug: 0, info: 1, warn: 2, error: 3 }[process.env.LOG_LEVEL?.toLowerCase() || 'info'] ?? 1;
const log = (level, msg, ctx) => {
  if ((LOG_LEVEL <= { DEBUG:0, INFO:1, WARN:2, ERROR:3 }[level])) {
    const line = JSON.stringify({ ts: new Date().toISOString(), level, msg, ...(ctx ? { ctx } : {}) });
    (level === 'ERROR' || level === 'WARN') ? process.stderr.write(line + '\n') : process.stdout.write(line + '\n');
  }
};
const logger = {
  debug: (m, c) => log('DEBUG', m, c),
  info:  (m, c) => log('INFO',  m, c),
  warn:  (m, c) => log('WARN',  m, c),
  error: (m, c) => log('ERROR', m, c),
};

// ── Helpers ───────────────────────────────────────────────────
const sleep = ms => new Promise(r => setTimeout(r, ms));

function calcBackoffMs (attempt) {
  const expo   = CONFIG.backoffBaseMs * Math.pow(2, attempt);
  const jitter = Math.random() * CONFIG.backoffBaseMs;
  return Math.min(expo + jitter, CONFIG.backoffMaxMs);
}

// ── Webhook sender ────────────────────────────────────────────
async function sendWebhook (payload) {
  const bodyJson  = JSON.stringify(payload);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const hmacHex   = CONFIG.webhookSecret
    ? crypto.createHmac('sha256', CONFIG.webhookSecret).update(`${timestamp}.${bodyJson}`).digest('hex')
    : '';

  const parsedUrl = new URL(CONFIG.phpWebhookUrl);
  const transport = parsedUrl.protocol === 'https:' ? https : http;
  const opts = {
    hostname: parsedUrl.hostname,
    port:     parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
    path:     parsedUrl.pathname + parsedUrl.search,
    method:   'POST',
    headers:  {
      'Content-Type':          'application/json',
      'Content-Length':        Buffer.byteLength(bodyJson),
      'X-LEGIT-Webhook-TS':    timestamp,
      'X-LEGIT-Webhook-Sig':   hmacHex,
      'X-LEGIT-Source':        'blockchain-microservice',
      'X-Internal-Token':      CONFIG.internalToken,
    },
    timeout: 10_000,
  };

  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await new Promise((resolve, reject) => {
        const req = transport.request(opts, res => {
          res.resume();
          res.on('end', () => {
            res.statusCode >= 200 && res.statusCode < 300 ? resolve() : reject(new Error(`Webhook HTTP ${res.statusCode}`));
          });
        });
        req.on('error',   reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('Webhook timed out.')); });
        req.write(bodyJson);
        req.end();
      });
      return;
    } catch (err) {
      if (attempt < 2) await sleep(1000 * (attempt + 1));
      else logger.error('sendWebhook: all 3 attempts failed.', { url: CONFIG.phpWebhookUrl, error: err.message });
    }
  }
}

// ── DB helpers ────────────────────────────────────────────────
async function fetchPendingJobs (pool, limit) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [rows] = await conn.execute(
      `SELECT id, content_hash, attempts, last_error
         FROM legit_blockchain_queue
        WHERE status IN ('pending','failed')
          AND (next_retry_at IS NULL OR next_retry_at <= NOW())
          AND attempts < ?
        ORDER BY queued_at ASC LIMIT ?
        FOR UPDATE SKIP LOCKED`,
      [CONFIG.maxAttempts, limit]
    );
    if (rows.length > 0) {
      const ids = rows.map(r => r.id);
      await conn.execute(
        `UPDATE legit_blockchain_queue SET status='processing', attempts=attempts+1 WHERE id IN (${ids.map(() => '?').join(',')})`,
        ids
      );
    }
    await conn.commit();
    return rows;
  } catch (err) { await conn.rollback(); throw err; }
  finally { conn.release(); }
}

async function markJobDone (pool, jobId, contentHash, ipfsCid, easUid, blockchainTx) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    await conn.execute(
      `UPDATE legit_blockchain_queue SET status='done', ipfs_cid=?, eas_uid=?, blockchain_tx=?, processed_at=NOW(), last_error=NULL WHERE id=?`,
      [ipfsCid, easUid, blockchainTx, jobId]
    );
    await conn.execute(
      `UPDATE legit_content_records SET ipfs_cid=?, eas_uid=?, blockchain_tx=?, anchored_at=NOW() WHERE content_hash=?`,
      [ipfsCid, easUid, blockchainTx, contentHash]
    );
    await conn.commit();
  } catch (err) { await conn.rollback(); throw err; }
  finally { conn.release(); }
}

async function markJobFailed (pool, jobId, attempts, errorMsg) {
  const delaySec   = Math.round(calcBackoffMs(attempts) / 1000);
  const newStatus  = attempts >= CONFIG.maxAttempts ? 'failed' : 'pending';
  await pool.execute(
    `UPDATE legit_blockchain_queue SET status=?, last_error=?, next_retry_at=DATE_ADD(NOW(), INTERVAL ? SECOND) WHERE id=?`,
    [newStatus, errorMsg.slice(0, 1000), delaySec, jobId]
  );
}

async function fetchContentRecord (pool, contentHash) {
  const [rows] = await pool.execute(
    `SELECT content_hash, user_uid, composite_score, identity_score, consistency_score,
            presence_score, ai_score_raw, history_score, consensus_score,
            gps_lat, gps_lng, gps_accuracy, captured_at, content_type
       FROM legit_content_records WHERE content_hash=? LIMIT 1`,
    [contentHash]
  );
  return rows[0] ?? null;
}

// ── Job processor ─────────────────────────────────────────────
async function processJob (pool, ipfs, eas, job) {
  const { id: jobId, content_hash: contentHash, attempts } = job;
  logger.info('Processing job', { jobId, contentHash, attempts });

  let record;
  try { record = await fetchContentRecord(pool, contentHash); }
  catch (err) {
    logger.error('fetchContentRecord failed', { jobId, error: err.message });
    await markJobFailed(pool, jobId, attempts, `DB fetch error: ${err.message}`);
    return;
  }

  if (!record) {
    logger.error('Content record not found', { jobId, contentHash });
    await pool.execute(
      `UPDATE legit_blockchain_queue SET status='failed', attempts=?, last_error=? WHERE id=?`,
      [CONFIG.maxAttempts, 'Content record not found.', jobId]
    );
    return;
  }

  let health;
  try { health = await eas.getNetworkHealth(); }
  catch (err) { health = { healthy: false, error: err.message }; }

  if (!health.healthy) {
    const reason = `Network unhealthy: ${health.error ?? `balance=${health.balanceEth} ETH`}`;
    logger.warn('Deferring job', { jobId, reason });
    await markJobFailed(pool, jobId, attempts, reason);
    return;
  }

  if (health.gasPriceGwei && health.gasPriceGwei > CONFIG.gasPriceLimitGwei) {
    const reason = `Gas price too high: ${health.gasPriceGwei.toFixed(2)} gwei`;
    logger.warn('Deferring job', { jobId, reason });
    await markJobFailed(pool, jobId, attempts, reason);
    return;
  }

  const capturedAtDate = record.captured_at ? new Date(record.captured_at) : new Date();
  const capturedAtUnix = Math.floor(capturedAtDate.getTime() / 1000);

  const metadataPackage = {
    schemaVersion: '1.0',
    contentHash:   record.content_hash,
    userUid:       record.user_uid,
    capturedAt:    capturedAtDate.toISOString(),
    contentType:   record.content_type,
    score: {
      composite:   parseFloat(record.composite_score),
      identity:    parseFloat(record.identity_score),
      consistency: parseFloat(record.consistency_score),
      presence:    parseFloat(record.presence_score),
      aiInverse:   parseFloat((1 - parseFloat(record.ai_score_raw)).toFixed(4)),
      history:     parseFloat(record.history_score),
      consensus:   parseFloat(record.consensus_score),
    },
    location: {
      latitude:  record.gps_lat      ? parseFloat(record.gps_lat)      : null,
      longitude: record.gps_lng      ? parseFloat(record.gps_lng)      : null,
      accuracy:  record.gps_accuracy ? parseFloat(record.gps_accuracy) : null,
    },
    mediaCid:   '',
    appVersion: process.env.APP_VERSION || '1.0.0',
  };

  let metadataResult;
  try {
    metadataResult = await ipfs.uploadMetadata(metadataPackage);
    logger.info('Metadata uploaded to IPFS', { jobId, cid: metadataResult.cid });
  } catch (err) {
    logger.error('IPFS metadata upload failed', { jobId, error: err.message });
    await markJobFailed(pool, jobId, attempts, `IPFS metadata error: ${err.message}`);
    await sendWebhook({ status: 'failed', content_hash: contentHash, error: err.message, stage: 'ipfs_metadata', attempts });
    return;
  }

  let attestResult;
  try {
    attestResult = await eas.attest({
      contentHash:    record.content_hash,
      metadataCid:    metadataResult.cid,
      mediaCid:       '',
      score:          metadataPackage.score,
      userUid:        record.user_uid,
      capturedAtUnix,
    });
    logger.info('EAS attestation created', { jobId, uid: attestResult.uid, txHash: attestResult.txHash });
  } catch (err) {
    logger.error('EAS attestation failed', { jobId, error: err.message });
    await markJobFailed(pool, jobId, attempts, `EAS error: ${err.message}`);
    await sendWebhook({ status: 'failed', content_hash: contentHash, error: err.message, stage: 'eas_attestation', attempts });
    return;
  }

  try {
    await markJobDone(pool, jobId, contentHash, metadataResult.cid, attestResult.uid, attestResult.txHash);
    logger.info('Job marked done', { jobId, contentHash });
  } catch (err) {
    logger.error('markJobDone DB write failed — manual reconciliation needed!', {
      jobId, contentHash, ipfsCid: metadataResult.cid, easUid: attestResult.uid, txHash: attestResult.txHash, error: err.message,
    });
  }

  await sendWebhook({
    status: 'success', content_hash: contentHash,
    ipfs_cid: metadataResult.cid, ipfs_url: metadataResult.gatewayUrl,
    eas_uid: attestResult.uid, blockchain_tx: attestResult.txHash,
    block_number: attestResult.blockNumber, network: attestResult.network,
    chain_id: attestResult.chainId, anchored_at: attestResult.attestedAt,
  });

  logger.info('Job complete', { jobId, contentHash, easUid: attestResult.uid });
}

// ── HTTP server ───────────────────────────────────────────────
const metrics = { jobsProcessed: 0, jobsSucceeded: 0, jobsFailed: 0, startedAt: new Date().toISOString() };

function createHttpServer (pool) {
  return http.createServer(async (req, res) => {
    const { method, url } = req;
    const token = req.headers['x-internal-token'] ?? '';

    if (url.startsWith('/internal/') && token !== CONFIG.internalToken) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Unauthorized' }));
      return;
    }

    if (method === 'POST' && url === '/internal/queue-anchoring') {
      let body = '';
      req.on('data', c => { body += c.toString(); });
      req.on('end', async () => {
        let parsed;
        try { parsed = JSON.parse(body); }
        catch { res.writeHead(400, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: 'Invalid JSON.' })); return; }

        const { content_hash, user_uid } = parsed;
        if (!content_hash || !/^[a-f0-9]{64}$/i.test(content_hash)) {
          res.writeHead(422, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'content_hash must be 64-char hex.' }));
          return;
        }
        try {
          await pool.execute(`INSERT IGNORE INTO legit_blockchain_queue (content_hash, status, queued_at) VALUES (?, 'pending', NOW())`, [content_hash]);
          logger.info('Job enqueued via HTTP', { content_hash, user_uid });
          res.writeHead(202, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ queued: true, content_hash }));
        } catch (err) {
          logger.error('Queue insert failed', { content_hash, error: err.message });
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Database error.' }));
        }
      });
      return;
    }

    if (method === 'GET' && url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', uptime: process.uptime(), startedAt: metrics.startedAt, pid: process.pid }));
      return;
    }

    if (method === 'GET' && url === '/metrics') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ...metrics, uptimeSec: Math.round(process.uptime()) }));
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: `No route: ${method} ${url}` }));
  });
}

// ── Poll loop ─────────────────────────────────────────────────
async function startPollLoop (pool, ipfs, eas) {
  logger.info('Poll loop started', { intervalMs: CONFIG.pollIntervalMs, maxConcurrent: CONFIG.maxConcurrent });
  let activeJobs = 0;
  let running    = true;

  process.once('SIGTERM', () => { running = false; });
  process.once('SIGINT',  () => { running = false; });

  while (running) {
    const slots = CONFIG.maxConcurrent - activeJobs;
    if (slots > 0) {
      let jobs = [];
      try { jobs = await fetchPendingJobs(pool, slots); }
      catch (err) { logger.error('fetchPendingJobs failed', { error: err.message }); }

      for (const job of jobs) {
        activeJobs++;
        metrics.jobsProcessed++;
        processJob(pool, ipfs, eas, job)
          .then(() => { metrics.jobsSucceeded++; })
          .catch(err => { metrics.jobsFailed++; logger.error('Unhandled processJob error', { jobId: job.id, error: err.message }); })
          .finally(() => { activeJobs--; });
      }
    }
    await sleep(CONFIG.pollIntervalMs);
  }

  logger.info('Draining active jobs…', { activeJobs });
  const deadline = Date.now() + 60_000;
  while (activeJobs > 0 && Date.now() < deadline) await sleep(500);
  logger.info('Poll loop exited.');
}

// ── Main ──────────────────────────────────────────────────────
async function main () {
  logger.info('LEGIT Blockchain Microservice starting…', { nodeVersion: process.version, pid: process.pid });

  let pool;
  try {
    pool = mysql.createPool(CONFIG.db);
    const conn = await pool.getConnection(); conn.release();
    logger.info('MySQL pool established.');
  } catch (err) { logger.error('MySQL connection failed.', { error: err.message }); process.exit(1); }

  let ipfs, eas;
  try { ipfs = new IPFSService(); logger.info('IPFSService initialised.'); }
  catch (err) { logger.error('IPFSService init failed.', { error: err.message }); process.exit(1); }

  try { eas = new EASService(); logger.info('EASService initialised.'); }
  catch (err) { logger.error('EASService init failed.', { error: err.message }); process.exit(1); }

  try {
    const health = await eas.getNetworkHealth();
    health.healthy
      ? logger.info('Network health OK', { signer: health.signerAddress, balanceEth: health.balanceEth, gasPriceGwei: health.gasPriceGwei })
      : logger.warn('Network health check failed at startup.', { health });
  } catch (err) { logger.warn('Could not complete preflight health check.', { error: err.message }); }

  const server = createHttpServer(pool);
  server.listen(CONFIG.port, '0.0.0.0', () => { logger.info(`HTTP server listening on port ${CONFIG.port}`); });

  const shutdown = async signal => {
    logger.info(`Received ${signal} — shutting down gracefully…`);
    server.close(() => logger.info('HTTP server closed.'));
    try { await pool.end(); logger.info('MySQL pool closed.'); }
    catch (err) { logger.warn('MySQL pool close error.', { error: err.message }); }
    process.exit(0);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT',  () => shutdown('SIGINT'));
  process.on('unhandledRejection', reason => { logger.error('Unhandled rejection', { reason: String(reason) }); });
  process.on('uncaughtException',  err    => { logger.error('Uncaught exception', { error: err.message }); process.exit(1); });

  await startPollLoop(pool, ipfs, eas);
  await shutdown('natural exit');
}

main().catch(err => {
  process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), level: 'ERROR', msg: 'main() threw', error: err.message }) + '\n');
  process.exit(1);
});
