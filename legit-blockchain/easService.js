'use strict';

const { EAS, SchemaEncoder, NO_EXPIRATION } = require('@ethereum-attestation-service/eas-sdk');
const { ethers } = require('ethers');

const NETWORK_CONFIG = {
  sepolia: {
    chainId: 84532,
    easAddress:     '0x4200000000000000000000000000000000000021',
    schemaRegistry: '0x4200000000000000000000000000000000000020',
    label: 'Base Sepolia',
  },
  mainnet: {
    chainId: 8453,
    easAddress:     '0x4200000000000000000000000000000000000021',
    schemaRegistry: '0x4200000000000000000000000000000000000020',
    label: 'Base Mainnet',
  },
};

const LEGIT_SCHEMA_DEFINITION =
  'string contentHash,' +
  'string metadataCid,' +
  'string mediaCid,' +
  'uint16 compositeScore,' +
  'uint8 identityScore,' +
  'uint8 consistencyScore,' +
  'uint8 presenceScore,' +
  'uint8 aiInverseScore,' +
  'uint8 historyScore,' +
  'uint8 consensusScore,' +
  'string userUid,' +
  'uint64 capturedAt';

class EASService {
  #eas;
  #signer;
  #schemaUID;
  #encoder;
  #networkConfig;
  #provider;

  constructor () {
    const privateKey = process.env.EAS_PRIVATE_KEY;
    const rpcUrl     = process.env.EAS_RPC_URL;
    const network    = (process.env.EAS_NETWORK || 'sepolia').toLowerCase();

    if (!privateKey || privateKey.trim() === '')
      throw new Error('EASService: EAS_PRIVATE_KEY environment variable is not set.');
    if (!rpcUrl || rpcUrl.trim() === '')
      throw new Error('EASService: EAS_RPC_URL environment variable is not set.');

    this.#networkConfig = NETWORK_CONFIG[network];
    if (!this.#networkConfig)
      throw new Error(`EASService: Unknown network "${network}". Valid values: ${Object.keys(NETWORK_CONFIG).join(', ')}.`);

    const easAddress   = (process.env.EAS_CONTRACT_ADDRESS || this.#networkConfig.easAddress).trim();
    this.#schemaUID    = (process.env.EAS_SCHEMA_UID || '').trim();
    this.#provider     = new ethers.JsonRpcProvider(rpcUrl.trim());
    this.#signer       = new ethers.Wallet(privateKey.trim(), this.#provider);
    this.#eas          = new EAS(easAddress);
    this.#eas.connect(this.#signer);
    this.#encoder      = new SchemaEncoder(LEGIT_SCHEMA_DEFINITION);
  }

  async attest (input) {
    this.#validateAttestInput(input);
    if (!this.#schemaUID)
      throw new Error('EASService.attest: EAS_SCHEMA_UID is not configured. Deploy the schema first.');

    const encodedData = this.#encoder.encodeData([
      { name: 'contentHash',      type: 'string', value: input.contentHash                              },
      { name: 'metadataCid',      type: 'string', value: input.metadataCid                              },
      { name: 'mediaCid',         type: 'string', value: input.mediaCid                                 },
      { name: 'compositeScore',   type: 'uint16', value: this.#toUint16(input.score.composite)          },
      { name: 'identityScore',    type: 'uint8',  value: this.#toUint8(input.score.identity)            },
      { name: 'consistencyScore', type: 'uint8',  value: this.#toUint8(input.score.consistency)         },
      { name: 'presenceScore',    type: 'uint8',  value: this.#toUint8(input.score.presence)            },
      { name: 'aiInverseScore',   type: 'uint8',  value: this.#toUint8(input.score.aiInverse)           },
      { name: 'historyScore',     type: 'uint8',  value: this.#toUint8(input.score.history)             },
      { name: 'consensusScore',   type: 'uint8',  value: this.#toUint8(input.score.consensus)           },
      { name: 'userUid',          type: 'string', value: input.userUid                                  },
      { name: 'capturedAt',       type: 'uint64', value: BigInt(input.capturedAtUnix)                   },
    ]);

    const recipient = (input.recipientAddress || process.env.EAS_RECIPIENT || ethers.ZeroAddress).trim();

    let tx;
    try {
      tx = await this.#eas.attest({
        schema: this.#schemaUID,
        data:   { recipient, expirationTime: NO_EXPIRATION, revocable: true, data: encodedData },
      });
    } catch (err) { throw this.#wrapError('attest (send tx)', err, { contentHash: input.contentHash }); }

    let newAttestationUID;
    try { newAttestationUID = await tx.wait(1); }
    catch (err) { throw this.#wrapError('attest (wait for receipt)', err, { contentHash: input.contentHash, txHash: tx?.hash }); }

    if (!newAttestationUID)
      throw new Error(`EASService.attest: transaction confirmed but UID was not returned. tx=${tx?.hash}`);

    const receipt = await this.#provider.getTransactionReceipt(tx.hash);
    return {
      uid:         newAttestationUID,
      txHash:      tx.hash,
      blockNumber: receipt?.blockNumber ?? null,
      network:     this.#networkConfig.label,
      chainId:     this.#networkConfig.chainId,
      recipient,
      schemaUID:   this.#schemaUID,
      attestedAt:  new Date().toISOString(),
    };
  }

  async revoke (uid) {
    if (typeof uid !== 'string' || uid.trim() === '')
      throw new TypeError('EASService.revoke: uid must be a non-empty string.');
    if (!this.#schemaUID)
      throw new Error('EASService.revoke: EAS_SCHEMA_UID is not configured.');
    let tx;
    try {
      tx = await this.#eas.revoke({ schema: this.#schemaUID, data: { uid: uid.trim() } });
      await tx.wait(1);
    } catch (err) { throw this.#wrapError('revoke', err, { uid }); }
    return { txHash: tx.hash, revokedAt: new Date().toISOString() };
  }

  async getAttestation (uid) {
    if (typeof uid !== 'string' || uid.trim() === '')
      throw new TypeError('EASService.getAttestation: uid must be a non-empty string.');
    try { return await this.#eas.getAttestation(uid.trim()); }
    catch (err) { throw this.#wrapError('getAttestation', err, { uid }); }
  }

  async deploySchema (revocable = true) {
    const { SchemaRegistry } = require('@ethereum-attestation-service/eas-sdk');
    const registry = new SchemaRegistry(this.#networkConfig.schemaRegistry);
    registry.connect(this.#signer);
    let tx;
    try {
      tx = await registry.register({ schema: LEGIT_SCHEMA_DEFINITION, resolverAddress: ethers.ZeroAddress, revocable });
      await tx.wait(1);
    } catch (err) { throw this.#wrapError('deploySchema', err, {}); }
    const uid = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['string', 'address', 'bool'],
        [LEGIT_SCHEMA_DEFINITION, ethers.ZeroAddress, revocable]
      )
    );
    return { schemaUID: uid, txHash: tx.hash };
  }

  async getNetworkHealth () {
    try {
      const [feeData, balance] = await Promise.all([
        this.#provider.getFeeData(),
        this.#provider.getBalance(this.#signer.address),
      ]);
      const gasPriceGwei = feeData.gasPrice    ? Number(ethers.formatUnits(feeData.gasPrice, 'gwei'))       : null;
      const maxFeeGwei   = feeData.maxFeePerGas ? Number(ethers.formatUnits(feeData.maxFeePerGas, 'gwei')) : null;
      const balanceEth   = Number(ethers.formatEther(balance));
      return {
        healthy: balanceEth > 0.005,
        signerAddress: this.#signer.address,
        balanceEth, gasPriceGwei, maxFeeGwei,
        network:   this.#networkConfig.label,
        chainId:   this.#networkConfig.chainId,
        checkedAt: new Date().toISOString(),
      };
    } catch (err) {
      return { healthy: false, error: err.message, checkedAt: new Date().toISOString() };
    }
  }

  #toUint16 (score) { return Math.round(Math.max(0, Math.min(100, Number(score))) * 100); }
  #toUint8  (score) { return Math.round(Math.max(0, Math.min(1,   Number(score))) * 100); }

  #validateAttestInput (input) {
    if (!input || typeof input !== 'object')
      throw new TypeError('EASService.attest: input must be a non-null object.');
    for (const field of ['contentHash', 'metadataCid', 'mediaCid', 'score', 'userUid', 'capturedAtUnix']) {
      if (input[field] === undefined || input[field] === null || input[field] === '')
        throw new TypeError(`EASService.attest: missing required field "${field}".`);
    }
    if (!/^[a-f0-9]{64}$/i.test(input.contentHash))
      throw new TypeError('EASService.attest: contentHash must be a 64-character hex string.');
    for (const sf of ['composite', 'identity', 'consistency', 'presence', 'aiInverse', 'history', 'consensus']) {
      if (typeof input.score[sf] !== 'number')
        throw new TypeError(`EASService.attest: score.${sf} must be a number.`);
    }
    if (!Number.isInteger(input.capturedAtUnix) || input.capturedAtUnix < 0)
      throw new TypeError('EASService.attest: capturedAtUnix must be a non-negative integer.');
  }

  #wrapError (method, original, context = {}) {
    const err = new Error(`EASService.${method} failed: ${original?.message ?? String(original)}`);
    err.cause   = original;
    err.context = context;
    err.code    = original?.code ?? 'EAS_ERROR';
    return err;
  }
}

module.exports = { EASService, LEGIT_SCHEMA_DEFINITION };
