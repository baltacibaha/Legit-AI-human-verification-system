'use strict';

const { PinataSDK } = require('pinata');

/**
 * IPFSService — wraps Pinata SDK v2 for media and metadata uploads.
 * Environment variables:
 *   PINATA_JWT      – Pinata JWT (required)
 *   PINATA_GATEWAY  – Custom gateway hostname (optional)
 */
class IPFSService {
  #client;
  #gateway;

  constructor () {
    const jwt = process.env.PINATA_JWT;
    if (!jwt || jwt.trim() === '') {
      throw new Error('IPFSService: PINATA_JWT environment variable is not set.');
    }
    this.#gateway = (process.env.PINATA_GATEWAY || 'gateway.pinata.cloud').replace(/\/$/, '');
    this.#client  = new PinataSDK({ pinataJwt: jwt.trim(), pinataGateway: this.#gateway });
  }

  async uploadMedia (mediaBuffer, mimeType, contentHash, userUid) {
    this.#validateBuffer(mediaBuffer, 'mediaBuffer');
    this.#validateString(mimeType,    'mimeType');
    this.#validateHex64(contentHash,  'contentHash');
    this.#validateString(userUid,     'userUid');

    const extension = this.#extensionFor(mimeType);
    const filename  = `legit_media_${contentHash}${extension}`;
    const keyvalues = {
      legit_content_hash: contentHash,
      legit_user_uid:     userUid,
      legit_type:         'media',
      uploaded_at:        new Date().toISOString(),
    };

    try {
      const file   = new File([mediaBuffer], filename, { type: mimeType });
      const result = await this.#client.upload.file(file).addMetadata({ name: filename, keyvalues });
      if (!result || !result.IpfsHash) throw new Error('Pinata returned a response without IpfsHash.');
      return {
        cid:        result.IpfsHash,
        gatewayUrl: this.#buildGatewayUrl(result.IpfsHash),
        pinSize:    result.PinSize   ?? mediaBuffer.length,
        timestamp:  result.Timestamp ?? new Date().toISOString(),
        filename,
      };
    } catch (err) {
      throw this.#wrapError('uploadMedia', err, { contentHash, mimeType });
    }
  }

  async uploadMetadata (metadata) {
    if (!metadata || typeof metadata !== 'object') {
      throw new TypeError('IPFSService.uploadMetadata: metadata must be a non-null object.');
    }
    this.#validateHex64(metadata.contentHash, 'metadata.contentHash');

    const json     = JSON.stringify(this.#sortKeysDeep(metadata), null, 2);
    const buffer   = Buffer.from(json, 'utf8');
    const filename = `legit_metadata_${metadata.contentHash}.json`;
    const keyvalues = {
      legit_content_hash: metadata.contentHash,
      legit_type:         'metadata',
      legit_score:        String(metadata.score?.composite ?? ''),
      uploaded_at:        new Date().toISOString(),
    };

    try {
      const file   = new File([buffer], filename, { type: 'application/json' });
      const result = await this.#client.upload.file(file).addMetadata({ name: filename, keyvalues });
      if (!result || !result.IpfsHash) throw new Error('Pinata returned a response without IpfsHash.');
      return {
        cid:        result.IpfsHash,
        gatewayUrl: this.#buildGatewayUrl(result.IpfsHash),
        pinSize:    result.PinSize   ?? buffer.length,
        timestamp:  result.Timestamp ?? new Date().toISOString(),
        filename,
      };
    } catch (err) {
      throw this.#wrapError('uploadMetadata', err, { contentHash: metadata.contentHash });
    }
  }

  async unpin (cid) {
    if (!cid || typeof cid !== 'string') throw new TypeError('IPFSService.unpin: cid must be a non-empty string.');
    try { await this.#client.unpin([cid]); }
    catch (err) { throw this.#wrapError('unpin', err, { cid }); }
  }

  async isPinned (cid) {
    if (!cid || typeof cid !== 'string') throw new TypeError('IPFSService.isPinned: cid must be a non-empty string.');
    try {
      const result = await this.#client.pins.list().cid(cid);
      return Array.isArray(result?.rows) && result.rows.length > 0;
    } catch { return false; }
  }

  #buildGatewayUrl (cid) { return `https://${this.#gateway}/ipfs/${cid}`; }

  #extensionFor (mimeType) {
    const map = {
      'image/heic': '.heic', 'image/heif': '.heif', 'image/jpeg': '.jpg',
      'image/png': '.png', 'image/webp': '.webp',
      'video/mp4': '.mp4', 'video/quicktime': '.mov', 'application/json': '.json',
    };
    return map[mimeType] ?? '';
  }

  #sortKeysDeep (obj) {
    if (Array.isArray(obj))       return obj.map(v => this.#sortKeysDeep(v));
    if (obj === null)              return null;
    if (typeof obj !== 'object')  return obj;
    return Object.fromEntries(Object.keys(obj).sort().map(k => [k, this.#sortKeysDeep(obj[k])]));
  }

  #validateBuffer (val, name) {
    if (!Buffer.isBuffer(val) || val.length === 0)
      throw new TypeError(`IPFSService: ${name} must be a non-empty Buffer.`);
  }

  #validateString (val, name) {
    if (typeof val !== 'string' || val.trim() === '')
      throw new TypeError(`IPFSService: ${name} must be a non-empty string.`);
  }

  #validateHex64 (val, name) {
    if (typeof val !== 'string' || !/^[a-f0-9]{64}$/i.test(val))
      throw new TypeError(`IPFSService: ${name} must be a 64-character hex string.`);
  }

  #wrapError (method, original, context = {}) {
    const err = new Error(`IPFSService.${method} failed: ${original?.message ?? String(original)}`);
    err.cause   = original;
    err.context = context;
    err.code    = original?.code ?? 'IPFS_ERROR';
    return err;
  }
}

module.exports = { IPFSService };
